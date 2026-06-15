# Finding 06: validate version gate swallows _tf_ver failure and emits a spurious error on a non-numeric minor version

| Field | Value |
|-------|-------|
| Severity | Medium |
| Category | Correctness bug |
| Affected function(s) | _cmd_validate, _tf_ver |
| Empirically verified | Yes (bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_cmd_validate` builds the version array with `declare -a tfver_a=($(_tf_ver))`.
Because `declare` always exits 0, a failing `_tf_ver` (e.g. the terraform/tofu
binary errored) is swallowed instead of aborting under `set -e`; `tfver_a` is
silently left empty. Then `[ ${tfver_a[1]:-} -lt 12 ]` performs an *unquoted*
numeric comparison on the minor-version token. If that token is empty or
non-numeric (an unexpected version string such as `0.12-dev`), `[` prints a
diagnostic like `[: integer expression expected` / `[: -lt: unary operator
expected` to stderr. Contrary to the original review note, this does **not**
crash the script: the test sits inside an `if A && B` condition, where `set -e`
is suspended, so the error is non-fatal — the gate is just silently skipped and
spurious noise is printed.

## Affected code

```bash
# _cmd_validate() — approx lines 174-184 (commit d0a01c3)
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
# _tf_ver() — approx lines 429-438 (commit d0a01c3)
_tf_ver () {
    local tf_ver
    tf_ver="$($TERRAFORM --version | grep -E "^Terraform v|^OpenTofu v" | cut -d 'v' -f 2)"
    if [ $? -ne 0 ] || [ -z "$tf_ver" ] ; then
        _stderrlog "Error: '$TERRAFORM --version' failed?"
        return 1
    fi
    IFS=. read -r -a tfver_a <<< "${tf_ver}"
    printf "%s\n" "${tfver_a[@]}"
}
```

`_tf_ver` is called from exactly one place — line 178 inside `_cmd_validate`.
`_cmd_validate` is itself invoked directly and as a dependency of `_cmd_plan`
(line 108) and `_cmd_plan_destroy` (line 156).

## Why this is a bug

There are two distinct defects on the one `declare`/`if` pair.

1. **`declare` masks the inner exit status, defeating `set -e`.**
   In `declare -a tfver_a=($(_tf_ver))`, the command substitution `$(_tf_ver)`
   runs, but its exit status is discarded: the status of the whole line is the
   exit status of `declare` itself, which is `0` whenever the assignment syntax
   is valid. This is the same class of footgun as `local x=$(cmd)`. So when
   `_tf_ver` returns 1 (the terraform/tofu binary is missing or `--version`
   failed), `set -e` does **not** abort; instead `tfver_a` becomes an empty
   array and execution continues as if probing succeeded. The script proceeds
   to run `terraform validate` against a tool it already knows is broken,
   hiding the real root-cause error from the user.

2. **The numeric `-lt` test is unguarded against empty / non-numeric tokens.**
   `[ ${tfver_a[1]:-} -lt 12 ]` is unquoted. With bash's `[`:
   * If the minor token is empty (the masked-failure case, or any version with
     no second `.`-separated field), the expansion word-splits to nothing and
     the test becomes `[ -lt 12 ]`, which bash reads as a malformed unary
     test → `[: -lt: unary operator expected`.
   * If the minor token is non-numeric — e.g. a tool that prints `0.12-dev`,
     so the field is `12-dev` — the test is `[ 12-dev -lt 12 ]` →
     `[: 12-dev: integer expression expected`.

   **Correction to the original note:** these errors do *not* crash the
   script. The test is the second operand of an `if A && B` condition. Per
   POSIX/bash semantics, `set -e` is suspended while evaluating the condition
   list of `if`/`while`/`until` and the left side of `&&`/`||`. A non-zero
   (rc=2) result from `[` there is treated as a plain "condition false": the
   `then` branch is skipped and execution continues. The only user-visible
   effects are (a) the spurious `[: ...` line on stderr and (b) the version
   gate being silently bypassed. The first defect (the swallowed `_tf_ver`
   failure) is the more serious one.

(For completeness: `_tf_ver` itself contains a separate `if [ $? -ne 0 ]`
after an assignment, which always inspects the assignment's status rather than
the pipeline's — that is the subject of finding 04 and is not re-fixed here.)

## How to reproduce / trigger

Trigger via terraformsh whenever `validate` runs (directly, or as a dependency
of `plan` / `plan_destroy`):

```sh
terraformsh -b backend.tfvars validate
terraformsh -b backend.tfvars plan          # runs _cmd_validate as a dependency
```

with a `terraform`/`tofu` whose `--version` output is unusual (e.g. a dev build
printing `Terraform v0.12-dev`), or whose invocation fails.

Minimal standalone reproductions (run on bash 5.2.21, output shown):

**(a) `declare` swallows the `_tf_ver` failure under `set -e`:**

```sh
bash -c '
set -e -u -o pipefail
_tf_ver() { echo "version probe failed" >&2; return 1; }
declare -a tfver_a=($(_tf_ver))
echo "REACHED after declare; status=$?  set -e did NOT abort; len=${#tfver_a[@]}"
'
```
EXPECTED (intuitively): script aborts on the failed probe.
ACTUAL:
```
version probe failed
REACHED after declare; status=0  set -e did NOT abort; len=0
```

**(b) non-numeric / empty minor token: spurious diagnostic, gate skipped, NO crash:**

```sh
bash -c '
set -e -u -o pipefail
tfver_a=("0" "12-dev")
echo before
if [ "${tfver_a[0]:-}" = "0" ] && [ ${tfver_a[1]:-} -lt 12 ] ; then echo THEN; fi
echo "after if  (rc=$?) -- script survived"
'
```
ACTUAL:
```
before
bash: line 5: [: 12-dev: integer expression expected
after if  (rc=0) -- script survived
```
The empty-token variant (`tfver_a=("0")`) prints
`[: -lt: unary operator expected` instead, and likewise does not crash.

I ran all of the above; outputs are reproduced verbatim.

## Suggested fix

Two changes: (1) split the assignment off `declare` so the probe's exit status
propagates and `set -e` (or an explicit `|| return 1`) can act on it; (2) guard
the numeric comparison with a digits-only regex so an unexpected version string
never reaches `[ ... -lt ... ]`.

```diff
 _cmd_validate () {
     _final_vars
     [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_get
     declare -a args=("$@")
-    declare -a tfver_a=($(_tf_ver))
+    local _tfver_out
+    _tfver_out="$(_tf_ver)" || _errexit "could not determine $TERRAFORM version"
+    declare -a tfver_a=($_tfver_out)
     # If terraform version < 0.12, pass VARFILE_ARG to validate. Otherwise it's deprecated
-    if [ "${tfver_a[0]:-}" = "0" ] && [ ${tfver_a[1]:-} -lt 12 ] ; then
+    if [ "${tfver_a[0]:-}" = "0" ] \
+       && [[ "${tfver_a[1]:-}" =~ ^[0-9]+$ ]] \
+       && [ "${tfver_a[1]}" -lt 12 ] ; then
         args+=("${VARFILE_ARG[@]}")
     fi
     _runcmd "$TERRAFORM" validate "${VALIDATE_ARGS[@]}" "${args[@]}"
 }
```

Notes:
* `declare -a tfver_a=($_tfver_out)` intentionally leaves `$_tfver_out`
  unquoted so it word-splits on the newlines `_tf_ver` emits — this matches the
  original intent. Default `IFS` splits on newline, so each version field lands
  in its own element.
* `_errexit` already exits the process (`echo ...; exit 1`); using it preserves
  the previous "validate aborts on a broken tool" expectation while surfacing
  the real reason. A `return 1` would actually halt the run too:
  `_cmd_plan`/`_cmd_plan_destroy` invoke `_cmd_validate` via
  `[ ... ] && _cmd_validate`, where `_cmd_validate` is the *last* (right-hand)
  command of the `&&` list. `set -e` is only suspended for the commands
  *preceding* the final one in a `&&`/`||` chain, so a non-zero status from the
  right-hand `_cmd_validate` is NOT exempted and does abort the script
  (verified empirically). `_errexit` is still preferred here because it exits
  unconditionally from any context and prints an explicit, user-facing reason
  rather than relying on `set -e` being active at the call site.
* The `[[ ... =~ ^[0-9]+$ ]]` guard removes the spurious `[:` diagnostics for
  any non-numeric minor field and makes the `-lt` test reachable only with a
  pure integer.

Call-site check: `_tf_ver` has a single caller (this function), so changing how
its output is consumed affects nothing else. `_cmd_validate`'s two
dependency-callers (`_cmd_plan`, `_cmd_plan_destroy`) only gain stricter,
correct behavior on a broken/odd toolchain. Verified the rewritten logic
against `0.11.0`, `0.12.0`, `0.12-dev`, `1.6.0`, and a failing probe: the gate
is taken only for genuine `< 0.12`, and no spurious `[:` errors are produced.

## Risk / impact

Hits anyone running `validate`, `plan`, or `plan_destroy` (the common path)
with a terraform/tofu whose `--version` either fails or prints a non-standard
string (dev builds, pre-release tags, future formats, a wrapper that emits
extra lines). Consequences are moderate, not catastrophic:

* A failed version probe is silently swallowed, so a genuinely broken toolchain
  is not reported at the point of detection; the user instead sees a more
  confusing downstream failure from `terraform validate`.
* On an unusual version string, a confusing `[: integer expression expected`
  line is printed to stderr (looks like a terraformsh bug to users), and the
  pre-0.12 `-var-file` compatibility shim is silently mis-gated. For all
  modern (>= 0.12) versions the gate *should* be skipped anyway, so the
  practical mis-behavior is limited; the main cost is the swallowed error and
  the misleading noise.

## Related findings

[04](04-version-banner-parse-aborts-silently.md) — `_tf_ver` (and other functions) use `if [ $? -ne 0 ]` after an
assignment, which inspects the assignment's status rather than the intended
pipeline's. That is the same family of "lost exit status" defect on the very
function consumed here. This finding (06) and 04 touch overlapping code
(`_tf_ver` and its caller) and would sensibly be bundled into the same PR.
