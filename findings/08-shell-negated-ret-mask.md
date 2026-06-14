# Finding 08: _cmd_shell captures ret=$? after `! _cmd_get`, which is always 0, masking the real failure

| Field | Value |
|-------|-------|
| Severity | Medium-Low |
| Category | Correctness bug |
| Affected function(s) | _cmd_shell |
| Empirically verified | Yes (bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_cmd_shell` runs its dependency command inside the guard
`if [ ... ] && ! _cmd_get ; then ret=$?`. By the time `ret=$?` runs, `$?` is the
exit status of the *negated compound condition* that was just evaluated to
decide whether to enter the `then` block. To enter the block at all, that
condition had to be true (status 0), so `ret` is captured as `0` even when
`_cmd_get` actually failed. The function dutifully logs `"Previous command
failed!"` but never propagates a non-zero status from the dependency.
Two secondary defects compound this: `ret` is never declared `local` (it leaks
into / clobbers global scope), and even if `ret` were captured correctly it is
*dead* — the function ends with `return $?`, which reflects the exit of the
interactive `bash -i -l`, not `ret`.

## Affected code

```bash
# _cmd_shell() — approx lines 303-313 (commit d0a01c3)
_cmd_shell () {
    _final_vars
    ret=0
    if [ "${NO_DEP_CMDS:-0}" = "0" ] && ! _cmd_get ; then
        ret=$?
        _log "Previous command failed!"
    fi
    _log "Dropping into shell; see TF_DATA_DIR variable for temp files"
    _runcmd bash -i -l
    return $?
}
```

For reference, `_cmd_get` (the dependency) and `_runcmd` behave as ordinary
functions that return the underlying command's exit status:

```bash
# _cmd_get() — approx lines 185-190 (commit d0a01c3)
_cmd_get () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init # 'terraform get' does nothing if we have not initialized terraform
    declare -a args=("$@")
    _runcmd "$TERRAFORM" get "${GET_ARGS[@]}" "${args[@]}"
}

# _runcmd() — approx lines 821-824 (commit d0a01c3)
_runcmd () {
    [ $QUIET_MODE -eq 1 ] || echo "+ $*" 1>&2
    if [ ! "${DRYRUN:-0}" = "1" ] ; then "$@"; fi
}
```

## Why this is a bug

In `if cond ; then BODY`, the body executes only when `cond` evaluates to a
zero (true) exit status, and inside the body `$?` initially holds that very
status — `0`.

Here `cond` is `[ "${NO_DEP_CMDS:-0}" = "0" ] && ! _cmd_get`. Walk the `&&`
chain when `_cmd_get` fails (returns, say, `7`):

1. `[ "${NO_DEP_CMDS:-0}" = "0" ]` → status `0` (true), so `&&` proceeds.
2. `_cmd_get` → status `7` (fail).
3. `! _cmd_get` → logical negation → status `0` (true).
4. The whole `&&` chain → status `0`, so the `then` block is entered.

The first statement in the block, `ret=$?`, therefore captures `0`, not `7`.
The real exit status of `_cmd_get` was consumed by `!` and is gone. This is
standard POSIX/bash behavior, not version-specific.

The `! _cmd_get` construct *is* doing one useful thing: it shields `_cmd_get`
from `set -e`. Under `set -e -u -o pipefail` (set at the top of the script),
a bare failing `_cmd_get` would abort the script; placing it as the right
operand of `&&` inside an `if` condition (and negating it) makes its failure
non-fatal so the function can react. The flaw is purely in *reading `$?`* after
the negation, where the status has already been normalised to `0`.

Secondary issues, both confirmed empirically:

- **`ret` is global.** There is no `local ret`. The assignment `ret=0` and the
  later `ret=$?` write to (and clobber) any caller-scoped `ret`. Compare
  `_cmd_apply`, which uses `ret` the same way but correctly declares
  `local errored=0 ret arg _use_varfiles=1`.
- **`ret` is dead.** The function returns with `return $?` on its last line,
  which reflects the exit status of `_runcmd bash -i -l` (the interactive
  shell the user just exited), not `ret`. So even a correctly-captured failure
  status would never be returned to the dispatcher. The dependency failure is
  effectively swallowed except for the log line.

## How to reproduce / trigger

Real command line — run the `shell` wrapper where the `get`/`init` dependency
fails (e.g. invalid backend config, missing provider, network failure during
`init`):

```
terraformsh -b broken.backend.tfvars shell
```

Expected: terraformsh notices the dependency failed and exits non-zero (or at
least surfaces the failure) instead of dropping you into a shell with an
uninitialised `TF_DATA_DIR`. Actual: it prints `Previous command failed!`,
captures `ret=0`, drops into the shell anyway, and ultimately returns the
exit status of that shell — the dependency failure is lost.

Minimal standalone repro of the `$?` mechanism (ran on bash 5.2.21, **output
shown is real**):

```bash
bash -c '
set -e -u -o pipefail
failing_fn() { return 7; }
ret=0
if true && ! failing_fn ; then
    ret=$?
    echo "Inside then-block: ret=$ret"   # prints 0, NOT 7
fi
echo "Final ret=$ret"                     # prints 0
'
# Output:
#   Inside then-block: ret=0
#   Final ret=0
```

Full `_cmd_shell` mirror with a failing dependency (ran on bash 5.2.21):

```bash
bash -c '
set -e -u -o pipefail
_log() { echo "log: $*"; }
_runcmd() { echo "+ $*"; "$@"; }
_cmd_get() { return 7; }   # simulate dependency failure
NO_DEP_CMDS=0
_cmd_shell () {
    ret=0
    if [ "${NO_DEP_CMDS:-0}" = "0" ] && ! _cmd_get ; then
        ret=$?
        _log "Previous command failed!"
    fi
    _log "Dropping into shell"
    _runcmd true            # stand-in for: bash -i -l
    return $?
}
_cmd_shell
echo "_cmd_shell returned: $?"
'
# Output:
#   log: Previous command failed!     <- it KNOWS get failed...
#   log: Dropping into shell
#   + true
#   _cmd_shell returned: 0            <- ...but returns success
```

EXPECTED: `_cmd_shell returned: 7` (or any non-zero), reflecting the failed
dependency. ACTUAL: `_cmd_shell returned: 0`.

The global-leak of `ret` was also confirmed: an outer `ret=GLOBAL` becomes `0`
after calling a `_cmd_shell`-shaped function with no `local ret`.

## Suggested fix

Run the dependency on its own line, capture its status directly with the
`set -e`-safe `cmd || ret=$?` idiom, declare `ret` local, and decide what to
do with a failure. The cleanest behaviour is to abort before dropping into a
shell when the dependency failed; if dropping into the shell anyway is
intentional, at least propagate the status. Below propagates it and still
drops into the shell (matching the current "log and continue" intent), while
fixing the captured status, the `local`, and the dead `return`:

```bash
_cmd_shell () {
    _final_vars
    local ret=0
    if [ "${NO_DEP_CMDS:-0}" = "0" ] ; then
        _cmd_get || ret=$?
        [ $ret -eq 0 ] || _log "Previous command failed!"
    fi
    _log "Dropping into shell; see TF_DATA_DIR variable for temp files"
    _runcmd bash -i -l || ret=$?
    return $ret
}
```

Diff form:

```diff
 _cmd_shell () {
     _final_vars
-    ret=0
-    if [ "${NO_DEP_CMDS:-0}" = "0" ] && ! _cmd_get ; then
-        ret=$?
-        _log "Previous command failed!"
-    fi
+    local ret=0
+    if [ "${NO_DEP_CMDS:-0}" = "0" ] ; then
+        _cmd_get || ret=$?
+        [ $ret -eq 0 ] || _log "Previous command failed!"
+    fi
     _log "Dropping into shell; see TF_DATA_DIR variable for temp files"
-    _runcmd bash -i -l
-    return $?
+    _runcmd bash -i -l || ret=$?
+    return $ret
 }
```

Notes on the `|| ret=$?` idiom under `set -e`: a command on the left of `||`
is not subject to `set -e` abort, so `_cmd_get || ret=$?` records the failure
without killing the script — same protection the original `! _cmd_get` guard
provided, but it preserves the real status. Tested on bash 5.2.21: with a
failing `_cmd_get` the function returns `7`; with a succeeding one it returns
`0`.

If the maintainers prefer to *stop* rather than drop into a broken shell, replace
the body of the `if` with `_cmd_get || _errexit "init/get failed; not dropping
into shell"` — but note `_errexit` calls `exit 1` (loses the real status) and
runs `echo` to stdout, so the propagating variant above is generally safer.

Call-site check: `_cmd_shell` is only ever invoked dynamically by the command
dispatcher (`_cmd_"$name" "${array[@]:1}"`, approx line 883) when the user
passes the `shell` wrapper command; there are no other callers, and it takes no
arguments. Adding `local ret` and changing the return value affects nothing
else. The sibling `_cmd_apply` uses a near-identical `ret=$?` pattern but
already declares `ret` local and captures `$?` immediately after the command
(not after a negation), so it is correct and needs no change.

## Risk / impact

Hit by anyone running `terraformsh shell` (or `tofush shell`) when the implied
`get`/`init` dependency fails — broken backend config, missing/locked state,
network errors during provider download, etc. Consequence is moderate: instead
of failing fast, terraformsh drops the user into an interactive shell whose
`TF_DATA_DIR` was never successfully initialised, and the wrapper's own exit
status reflects only the interactive shell, not the failed setup. In automation
or scripted use this can hide a real initialisation failure (CI sees success),
though `shell` is primarily an interactive convenience command, which is why
this is rated Medium-Low rather than higher. No data loss or state corruption.

## Related findings

None. This can stand as its own small PR; if other `$?`-after-control-flow or
missing-`local` findings are batched together, it fits naturally there.
