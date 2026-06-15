# Finding 12: Empty `"${arr[@]}"` under set -u aborts on bash <= 4.3 (e.g. macOS stock bash 3.2)

| Field | Value |
|-------|-------|
| Severity | Portability |
| Category | Portability bug |
| Affected function(s) | pervasive — every `_cmd_*` wrapper and the `*_ARGS` / `VARFILE_ARG` / `args` expansions |
| Empirically verified | Yes (modern bash 5.2 passes; old bash <= 4.3 known to fail) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

The whole script runs under `set -u` (line 6: `set -e -u -o pipefail`). Dozens of
call sites expand arrays that are routinely empty — `VALIDATE_ARGS`, `STATE_ARGS`,
`WORKSPACE_ARGS`, `CONSOLE_ARGS`, `OUTPUT_ARGS`, `TAINT_ARGS`, `UNTAINT_ARGS`,
`SHOW_ARGS`, `VARFILE_ARG`, and the per-command `args=("$@")` — using the bare form
`"${arr[@]}"`. On bash 4.3 and earlier, expanding an empty array with `@`/`*` under
`set -u` is treated as an *unbound variable* and the script aborts immediately. That
bug was fixed in bash 4.4. macOS ships stock `/bin/bash` 3.2 to this day, and the
script already carries macOS-specific workarounds (`_mktemp`, `_readlinkf`), which
signals macOS is an intended target — so on stock macOS bash nearly every command
would die before running Terraform.

## Affected code

```bash
# line 6 — the option set that makes empty @-expansion fatal on old bash
set -e -u -o pipefail
```

```bash
# _cmd_validate() — approx lines 174-184
_cmd_validate () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_get
    declare -a args=("$@")
    declare -a tfver_a=($(_tf_ver))
    # If terraform version < 0.12, pass VARFILE_ARG to validate. Otherwise it's deprecated
    if [ "${tfver_a[0]:-}" = "0" ] && [ ${tfver_a[1]:-} -lt 12 ] ; then
        args+=("${VARFILE_ARG[@]}")
    fi
    _runcmd "$TERRAFORM" validate "${VALIDATE_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_show() — approx lines 290-295
_cmd_show () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init 1>&2 # Send all previous command output to STDERR
    declare -a args=("$@")
    _runcmd "$TERRAFORM" show "${SHOW_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_plan() — approx lines 106-112
_cmd_plan () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_validate
    declare -a args=("$@")
    [ $USE_PLANFILE -eq 1 ] && args+=("-out=$TF_PLANFILE")
    _runcmd "$TERRAFORM" plan "${VARFILE_ARG[@]}" "${PLAN_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_state() — approx lines 254-275 (args+=("${STATE_ARGS[@]}") and args+=("$@"))
    args+=("${STATE_ARGS[@]}")
    args+=("$@")
    _runcmd "$TERRAFORM" state "${args[@]}"
```

```bash
# _cmd_workspace() — approx lines 276-289
    args+=("${WORKSPACE_ARGS[@]}")
    args+=("$@")
    _runcmd "$TERRAFORM" workspace "${args[@]}"
```

The arrays in question are initialized empty in `_default_vars()` (approx lines
544-552) and again at the top-level declarations (approx lines 833-838):

```bash
# _default_vars() — approx lines 544-552 (the ones that default to empty)
    VALIDATE_ARGS=()
    STATE_ARGS=()
    WORKSPACE_ARGS=()
    CONSOLE_ARGS=()
    OUTPUT_ARGS=()
    TAINT_ARGS=()
    UNTAINT_ARGS=()
    SHOW_ARGS=()
```

The same bare-expansion pattern appears in `_cmd_plan_destroy`, `_cmd_destroy`,
`_cmd_get`, `_cmd_refresh`, `_cmd_output`, `_cmd_force-unlock`, `_cmd_0.12upgrade`,
`_cmd_0.13upgrade`, `_cmd_console`, `_cmd_init`, `_cmd_import`, `_cmd_taint`,
`_cmd_untaint`, `_cmd_catchall`, and `_cmd_aws_bootstrap` — every one of which
expands at least one `*_ARGS`, `VARFILE_ARG`, or `args=("$@")` array that can be
empty.

## Why this is a bug

`set -u` (nounset) makes the shell abort when it expands an unset variable. The
subtle part is how bash classifies `"${arr[@]}"` and `"${arr[*]}"` for an array
that has *zero* elements:

- **bash <= 4.3**: an empty array has no element `0`, so `${arr[@]}` is treated the
  same as referencing an unset variable. Under `set -u` this prints
  `arr[@]: unbound variable` and exits with status 1. This is a runtime
  word-expansion error: when a non-interactive shell hits a `nounset` violation
  while expanding a word, the shell itself exits immediately (this does not depend
  on `set -e` — `nounset` aborts on its own). Earlier statements on prior lines run
  normally; the script dies the moment it reaches the offending expansion.
- **bash >= 4.4**: the maintainers explicitly fixed this so that `"${arr[@]}"` /
  `"${arr[*]}"` on an empty array expands to nothing and does **not** trip
  `set -u`. (See the bash 4.4 CHANGES: "expanding `@` or `*` ... when there are no
  positional parameters or array elements no longer ... an error under `set -u`".)

This matters here because:

- Most `_cmd_*` wrappers build `declare -a args=("$@")` (the exceptions
  `_cmd_state` and `_cmd_workspace` use `declare -a args=()` and then append
  `"$@"`, which hits the same problem via `args+=("${STATE_ARGS[@]}")` etc.). When
  the user runs a command with no trailing options (e.g. `terraformsh ... show`,
  `terraformsh ... validate`), `args` is empty.
- Most of the `*_ARGS` arrays (`VALIDATE_ARGS`, `STATE_ARGS`, `WORKSPACE_ARGS`,
  `CONSOLE_ARGS`, `OUTPUT_ARGS`, `TAINT_ARGS`, `UNTAINT_ARGS`, `SHOW_ARGS`) default
  to empty in `_default_vars()`.
- `VARFILE_ARG` is empty whenever the user passes no `-f` var-files and no
  auto-discovered tfvars exist.

A common misreading is that a non-empty literal earlier on the line "saves" the
expansion — e.g. `validate "${VALIDATE_ARGS[@]}" "${args[@]}"` looks safe because
`validate` is a literal. It is not: each `"${arr[@]}"` is evaluated *independently*,
so an empty `VALIDATE_ARGS` aborts regardless of what precedes it.

Note this is purely a *portability* issue, not a logic bug: on bash 4.4+ (which
includes essentially every Linux distro and Homebrew's bash) the code is correct.
The script's shebang is `#!/usr/bin/env bash`, so a macOS user with a newer
Homebrew bash earlier in `PATH` is unaffected; a user on stock `/bin/bash` 3.2, or
who invokes `bash terraformsh`, hits the abort.

## How to reproduce / trigger

Minimal standalone demonstration of the mechanism (the abort cannot be shown on a
4.4+ box, but the no-error behavior of 4.4+ and the equivalence of the fix can):

```bash
# On bash <= 4.3 (e.g. macOS /bin/bash 3.2, CentOS 7 /bin/bash 4.2):
bash -c 'set -u; a=(); echo "${a[@]}"'
# EXPECTED by author: prints an empty line
# ACTUAL on old bash:  a[@]: unbound variable   (exit 1)

# On bash >= 4.4 (verified here on 5.2.21):
bash -c 'set -e -u -o pipefail; a=(); echo "before"; echo "${a[@]}"; echo "after"'
# Prints: before / (blank) / after   — no error. (Ran this; exit 0.)
```

Reproduction at the terraformsh level — any command whose `*_ARGS` array and trailing
`args` are both empty triggers it on old bash, for example:

```bash
# SHOW_ARGS defaults to empty; no trailing options => args empty too:
terraformsh -C ./module show
# On bash 3.2/4.2: aborts with "SHOW_ARGS[@]: unbound variable" before terraform runs.
# On bash 4.4+:    runs `terraform show` normally.

terraformsh -C ./module validate     # VALIDATE_ARGS + args both empty
terraformsh -C ./module workspace list   # WORKSPACE_ARGS empty
```

I verified on this machine (bash 5.2.21) that:
- the unguarded empty expansion is a no-op (exit 0), confirming the 4.4+ fix; and
- the guarded idiom proposed below produces *identical* output, preserving element
  count and per-element quoting (tested with elements containing spaces and an empty
  string: `("x" "y z" "")` expands to exactly 3 arguments both ways).

## Suggested fix

There are three viable approaches; pick one per project policy.

**Option A (recommended — make the code portable):** wrap every possibly-empty
`@`-expansion in the guarded idiom `${arr[@]+"${arr[@]}"}`. This is a no-op on bash
4.4+ and fixes bash <= 4.3. It preserves word-splitting and per-element quoting
exactly (verified above).

```diff
-    _runcmd "$TERRAFORM" validate "${VALIDATE_ARGS[@]}" "${args[@]}"
+    _runcmd "$TERRAFORM" validate ${VALIDATE_ARGS[@]+"${VALIDATE_ARGS[@]}"} ${args[@]+"${args[@]}"}
```

```diff
-    _runcmd "$TERRAFORM" show "${SHOW_ARGS[@]}" "${args[@]}"
+    _runcmd "$TERRAFORM" show ${SHOW_ARGS[@]+"${SHOW_ARGS[@]}"} ${args[@]+"${args[@]}"}
```

```diff
-    _runcmd "$TERRAFORM" plan "${VARFILE_ARG[@]}" "${PLAN_ARGS[@]}" "${args[@]}"
+    _runcmd "$TERRAFORM" plan ${VARFILE_ARG[@]+"${VARFILE_ARG[@]}"} ${PLAN_ARGS[@]+"${PLAN_ARGS[@]}"} ${args[@]+"${args[@]}"}
```

The same transform must be applied to **every** `"${...[@]}"` expansion of an array
that can be empty, including the in-place appends in `_cmd_state` and
`_cmd_workspace`:

```diff
-    args+=("${STATE_ARGS[@]}")
+    args+=(${STATE_ARGS[@]+"${STATE_ARGS[@]}"})
```

```diff
-    args+=("${WORKSPACE_ARGS[@]}")
+    args+=(${WORKSPACE_ARGS[@]+"${WORKSPACE_ARGS[@]}"})
```

and the `args+=("${VARFILE_ARG[@]}")` in `_cmd_validate`, plus the
`INIT_ARGS+=("${BACKENDVARFILE_ARG[@]}")` path and the `_cmd_aws_bootstrap`
import/plan/init lines. Arrays that are *always* non-empty (`PLAN_ARGS`,
`APPLY_ARGS`, `INIT_ARGS`, `GET_ARGS`, `REFRESH_ARGS`, `FORCEUNLOCK_ARGS`, etc.,
which are seeded with at least one flag in `_default_vars()`) are technically safe,
but applying the guard to them too costs nothing and avoids the trap of a user
overriding them to empty via a `.terraformshrc`. The guard does **not** break any
non-empty call site: when the array has elements, `${arr[@]+"${arr[@]}"}` expands to
exactly `"${arr[@]}"`.

**Option B (simplest — drop the requirement):** if macOS stock bash 3.2 does not
need to be supported, document a minimum bash version and assert it near the top of
the script, e.g.:

```bash
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    echo "$0: requires bash >= 4.4 (found ${BASH_VERSION})" >&2; exit 1
fi
```

This turns a confusing mid-run `unbound variable` abort into a clear, immediate
error message.

**Option C:** drop `-u` (not recommended — it is load-bearing elsewhere and removing
it would mask other bugs).

Whichever is chosen, the decision to make is explicit: **does terraformsh support
macOS stock `/bin/bash` 3.2?** The presence of `_mktemp` and `_readlinkf` macOS
workarounds suggests yes, which argues for Option A.

## Risk / impact

- **Who hits it:** anyone running terraformsh under bash <= 4.3. The realistic
  population is macOS users on stock `/bin/bash` (3.2.57) and older enterprise Linux
  (RHEL/CentOS 7 ships bash 4.2). Users on modern Linux or Homebrew bash are
  unaffected.
- **How often:** on an affected bash, *almost every* invocation — any command with
  an empty `*_ARGS` default and no extra trailing options. `show`, `validate`,
  `workspace`, `output`, `taint`, `console`, `state`, and a plain `plan`/`apply`
  with no `-f` var-files all qualify.
- **Consequence:** the script aborts with `<NAME>[@]: unbound variable` *before*
  invoking Terraform. No state is touched, so it is fail-safe rather than dangerous,
  but the tool is effectively unusable on those platforms and the error message
  points at an internal variable, not at anything the user can act on.

## Related findings

- [06](06-validate-version-gate-swallows-and-crashes.md) — also lives in
  `_cmd_validate` and touches the same `VARFILE_ARG` / `tfver_a` lines; a fix PR for
  that function should apply the Option A guard at the same time.
- This is a cross-cutting change. It can be bundled into a single "old-bash
  portability" PR rather than split per-function, since the transform is mechanical
  and touches nearly every `_cmd_*` wrapper.
