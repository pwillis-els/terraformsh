# Finding 02: _cmd_apply errored.tfstate recovery is unreachable (set -e abort + impossible condition + inverted guard)

| Field | Value |
|-------|-------|
| Severity | High |
| Category | Correctness bug |
| Affected function(s) | _cmd_apply |
| Empirically verified | Yes (bash 5.2 / reproduced here on this host) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_cmd_apply` advertises a `PUSH_ERRORED_TFSTATE` recovery feature: when an apply
fails and leaves an `errored.tfstate`, terraformsh is supposed to push that
unapplied state and delete the file. That recovery block can **never** execute,
for three compounding reasons. (1) The script runs under `set -e`, and the
`terraform apply` is invoked as a bare command (`_runcmd ... apply`) on its own
line; when apply fails, `set -e` aborts the whole script *before* the next line
(`ret=$?`) and the recovery block are ever reached. (2) Even if that abort were
avoided, the recovery's inner condition `[ $errored -eq 0 ]` is nested inside
`if [ $errored -ne 0 ]`, requiring `errored` to be simultaneously zero and
nonzero — logically impossible. (3) Separately, the pre-existing-file guard
`[ ! -e errored.tfstate ] || errored=1` does the opposite of its comment
("Ignore pre-existing errored.tfstate"): it sets `errored=1` *when the file
already exists*, which makes a **successful** apply report failure
(`return 1`) whenever a stale `errored.tfstate` is lying around — and that bug
*is* reachable.

## Affected code

```bash
# _cmd_apply() — approx lines 113-153 (commit d0a01c3)
_cmd_apply () {
    _final_vars
    local errored=0 ret arg _use_varfiles=1
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    local varfile_arg=()
    # Detect if non-option file arguments were passed. If they were,
    # disable the passing of -var-file arguments as apply can't accept them
    # if it's accepting a plan file too.
    if [ ${#args[@]} -gt 0 ] ; then
        for arg in "${args[@]}" ; do
            if [ ! "${arg[0]:0:1}" = "-" ] && [ -f "$arg" ] ; then
                _log "Warning: detected a plan-file passed as an option; not passing varfiles"
                _use_varfiles=0
                break
            fi
        done
    fi
    if [ $USE_PLANFILE -eq 1 ]; then
      args+=("$TF_PLANFILE") # Pass plan file after '$@'
    elif [ ${#VARFILE_ARG[@]} -gt 0 ] && [ $_use_varfiles -eq 1 ] ; then
      varfile_arg=("${VARFILE_ARG[@]}") # only if planfile disabled
    fi
    [ ! -e errored.tfstate ] || errored=1 # Ignore pre-existing errored.tfstate
    _runcmd "$TERRAFORM" apply "${varfile_arg[@]}" "${APPLY_ARGS[@]}" "${args[@]}"
    ret=$?
    [ $ret -eq 0 ] || errored=$ret
    if [ $errored -ne 0 ] ; then
        if [ "${PUSH_ERRORED_TFSTATE:-1}" -eq 1 ] && [ $errored -eq 0 ] && [ -e errored.tfstate ] ; then
            _log "Warning: found 'errored.tfstate' after running 'apply'; attempting to push unapplied state file..."
            if _cmd_state push errored.tfstate ; then
                rm -f errored.tfstate
            else
                _errexit "could not push errored.tfstate!"
            fi
        fi
        return $errored
    else
        rm -f "$TF_PLANFILE"
    fi
}
```

Supporting context — the global mode and the dispatch site that calls
`_cmd_apply`:

```bash
# top of script — approx line 6
set -e -u -o pipefail

# _runcmd() — approx lines 821-824
_runcmd () {
    [ $QUIET_MODE -eq 1 ] || echo "+ $*" 1>&2
    if [ ! "${DRYRUN:-0}" = "1" ] ; then "$@"; fi
}

# command dispatch loop — approx lines 879-887
for pair in "${CMD_PAIRS[@]}" ; do
    eval "$pair"
    name="${array[0]}" # 'array' is defined in 'eval $pair'
    if command -v _cmd_"$name" >/dev/null ; then
        _cmd_"$name" "${array[@]:1}"
    else
        _cmd_catchall "$name" "${array[@]:1}"
    fi
done
```

## Why this is a bug

There are three independent defects. Any one of them alone breaks the recovery;
together they make it doubly dead and add a separate reachable failure.

**(a) `set -e` aborts at the bare apply before `ret=$?`.**
The whole script runs under `set -e` (line 6). Under `set -e`, a command that
fails aborts the shell *unless* it is the condition of `if`/`while`/`until`,
part of a `&&`/`||` list (in a non-final position), or negated with `!`. The
apply is run as a standalone command:

```bash
_runcmd "$TERRAFORM" apply ...     # standalone command — NOT exempt from set -e
ret=$?                             # separate command on the next line
```

`ret=$?` on the *following* line does not exempt the previous command from
`set -e` (that exemption only applies when the command is itself in a tested
position). So a failing apply makes `_runcmd` return nonzero, and `set -e`
aborts the script *immediately* — before `ret=$?`, before
`[ $ret -eq 0 ] || errored=$ret`, before the `if [ $errored -ne 0 ]` block, and
therefore before any recovery. `_runcmd` does not swallow the failure either: it
ends with `"$@"`, whose exit status becomes `_runcmd`'s exit status.

Note on location: the abort happens *inside* `_cmd_apply` at the `_runcmd ...
apply` line — not at the dispatch site (line 883). The dispatch site is *also*
a bare call under `set -e`, so even the `return $errored` path would abort the
script; but that is the intended end state (a failed apply should fail the
script). The decisive problem is that the in-function abort happens first, so
nothing between the apply line and the `return` ever runs.

**(b) The recovery's inner condition is logically impossible.**
Even if (a) were fixed, the recovery guard is:

```bash
if [ $errored -ne 0 ] ; then                                  # require errored != 0
    if ... && [ $errored -eq 0 ] && [ -e errored.tfstate ] ;  # AND require errored == 0
```

`errored` cannot be both nonzero and zero, so the inner `if` is never true and
the push/`rm` body is unreachable. The inner test should *not* require
`errored == 0`; it is redundant/contradictory with the outer guard.

**(c) The pre-existing-file guard is inverted vs. its own comment, and is
reachable.**

```bash
[ ! -e errored.tfstate ] || errored=1 # Ignore pre-existing errored.tfstate
```

If `errored.tfstate` already exists, `[ ! -e errored.tfstate ]` is false, so the
`|| errored=1` runs and sets `errored=1`. That is the *opposite* of "ignore a
pre-existing file." Because `errored` is then returned verbatim
(`return $errored`), a **successful** apply (`ret=0`) reports failure (`return
1`) whenever a stale `errored.tfstate` happens to be present from an earlier run.
This branch is reachable: on a *successful* apply the `_runcmd` line does not
fail, so `set -e` does not abort, and control reaches `if [ $errored -ne 0 ]`
with `errored=1`. The variable `errored` is also overloaded here — it doubles as
"pre-existing-file marker" and as "apply exit code" — which is the root of the
confusion.

## How to reproduce / trigger

terraformsh invocation that exercises the (dead) recovery path:

```sh
# Run an apply that fails and leaves an errored.tfstate (e.g. a backend write
# failure during apply). PUSH_ERRORED_TFSTATE defaults to 1.
terraformsh apply
# EXPECTED: terraformsh logs "found 'errored.tfstate' ...", runs
#           'terraform state push errored.tfstate', and removes the file.
# ACTUAL:   the script aborts at the apply line (set -e); the recovery never
#           runs and errored.tfstate is left behind.
```

terraformsh invocation that exercises the reachable inverted-guard bug (c):

```sh
# Leave a stale errored.tfstate in the working dir from a previous run, then run
# a NORMAL, SUCCESSFUL apply:
: > errored.tfstate
terraformsh apply
# EXPECTED: successful apply exits 0.
# ACTUAL:   _cmd_apply returns 1 even though apply succeeded, so terraformsh
#           exits nonzero.
```

Minimal standalone `bash -c` reproductions (run on this host; all three printed
the results below):

```bash
# (a) set -e aborts at a bare failing command, before the next line runs:
bash -c '
set -e -u -o pipefail
_runcmd () { "$@"; }
fail () { return 7; }
echo before
_runcmd fail
ret=$?
echo "after (ret=$ret) -- should NOT print"
'
# Output:  before
# exit status: 7   ("after ..." never printed)
```

```bash
# (b) the nested condition is impossible even when errored is forced nonzero:
bash -c '
errored=7; PUSH_ERRORED_TFSTATE=1; : > errored.tfstate
if [ $errored -ne 0 ] ; then
  if [ "${PUSH_ERRORED_TFSTATE:-1}" -eq 1 ] && [ $errored -eq 0 ] && [ -e errored.tfstate ] ; then
    echo "RECOVERY RAN (never happens)"
  else
    echo "recovery skipped: inner condition false"
  fi
fi
rm -f errored.tfstate
'
# Output:  recovery skipped: inner condition false
```

```bash
# (c) inverted guard + return makes a SUCCESSFUL apply report failure:
bash -c '
errored=0; : > errored.tfstate
[ ! -e errored.tfstate ] || errored=1   # line 136
ret=0                                   # apply SUCCEEDED
[ $ret -eq 0 ] || errored=$ret
echo "errored=$errored -> _cmd_apply would return $errored on a successful apply"
rm -f errored.tfstate
'
# Output:  errored=1 -> _cmd_apply would return 1 on a successful apply
```

I ran all three snippets; the outputs above are the actual results.

## Suggested fix

Three changes, all inside `_cmd_apply`:

1. Capture the apply exit status without tripping `set -e` by putting the call
   in a tested position (`|| ret=$?`). Initialize `ret=0` first.
2. Stop overloading `errored` for the pre-existing-file check. Record the
   pre-existing state separately so a stale file is genuinely ignored (matching
   the comment), and only treat the file as "newly created by apply" if it was
   absent before.
3. Fix the inner recovery condition so it no longer requires `errored == 0`.

```bash
_cmd_apply () {
    _final_vars
    local ret=0 arg _use_varfiles=1 preexisting_errored=0
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    local varfile_arg=()
    if [ ${#args[@]} -gt 0 ] ; then
        for arg in "${args[@]}" ; do
            if [ ! "${arg[0]:0:1}" = "-" ] && [ -f "$arg" ] ; then
                _log "Warning: detected a plan-file passed as an option; not passing varfiles"
                _use_varfiles=0
                break
            fi
        done
    fi
    if [ $USE_PLANFILE -eq 1 ]; then
      args+=("$TF_PLANFILE")
    elif [ ${#VARFILE_ARG[@]} -gt 0 ] && [ $_use_varfiles -eq 1 ] ; then
      varfile_arg=("${VARFILE_ARG[@]}")
    fi

    # Remember whether errored.tfstate already existed; if so, ignore it.
    [ -e errored.tfstate ] && preexisting_errored=1

    # Run apply WITHOUT letting set -e abort us, so the recovery below can run.
    _runcmd "$TERRAFORM" apply "${varfile_arg[@]}" "${APPLY_ARGS[@]}" "${args[@]}" || ret=$?

    if [ $ret -ne 0 ] ; then
        # Only push an errored.tfstate that this apply created (not a stale one).
        if [ "${PUSH_ERRORED_TFSTATE:-1}" -eq 1 ] \
           && [ $preexisting_errored -eq 0 ] \
           && [ -e errored.tfstate ] ; then
            _log "Warning: found 'errored.tfstate' after running 'apply'; attempting to push unapplied state file..."
            if _cmd_state push errored.tfstate ; then
                rm -f errored.tfstate
            else
                _errexit "could not push errored.tfstate!"
            fi
        fi
        return $ret
    else
        rm -f "$TF_PLANFILE"
    fi
}
```

Notes for the reviewer:

- The recovery's `if _cmd_state push errored.tfstate ; then` is in a condition
  position, so `set -e` is correctly suppressed for the duration of
  `_cmd_state` (verified: when a function runs as an `if` condition, `set -e`
  is disabled throughout its body, including its internal bare `_runcmd`
  calls). So this push is safe; no extra `|| true` is needed here.
- The `return $ret` (nonzero) then propagates to the bare dispatch call
  (`_cmd_"$name" ...`, approx line 883), which under `set -e` aborts the
  script — that is the desired behavior: a failed apply should still fail
  terraformsh, but only *after* the recovery has run.
- **Other call sites:** `_cmd_apply` is invoked **only** from the dispatch loop;
  it is not a dependency of any other `_cmd_*` (unlike `_cmd_init`/`_cmd_get`).
  So this change affects only the apply command path. `_cmd_aws_bootstrap` runs
  its own `terraform apply` via `_runcmd` and does not call `_cmd_apply`, so it
  is unaffected.

## Risk / impact

The `PUSH_ERRORED_TFSTATE` recovery is on by default
(`${PUSH_ERRORED_TFSTATE:-1}`) and is precisely the safety net users rely on
when an apply fails mid-way (e.g. a transient backend/state write failure):
terraform writes the partially-applied state to `errored.tfstate` and tells the
user to push it back, or state will be lost. Because the block is dead, that
automatic recovery never happens, and the local `errored.tfstate` is left
behind for manual handling — exactly the failure mode the feature was meant to
remove. Separately, the inverted guard (c) is reachable today and causes
*successful* applies to exit nonzero whenever a stale `errored.tfstate` is
present, which can break CI pipelines and `&&`-chained workflows. Severity High:
a silently-disabled data-safety feature plus a reachable false-failure on the
happy path.

## Related findings

None currently filed. If a finding is later opened for the bare-`_runcmd`
pattern more broadly (e.g. `_cmd_state` / `_cmd_init` also run `terraform` via a
bare `_runcmd` under `set -e`), this fix should be coordinated with it, since
the root cause class is the same `set -e` interaction.
