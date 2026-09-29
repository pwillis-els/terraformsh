# Finding 04: Startup version parse aborts with no message when the --version banner does not match the grep

| Field | Value |
|-------|-------|
| Severity | Medium-High |
| Category | Correctness bug |
| Affected function(s) | `_tf_ver`, `_default_vars` |
| Empirically verified | Yes (bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

Both `_tf_ver` and `_default_vars` parse the tool version out of `$TERRAFORM --version`
with a pipeline `... | grep -E '^Terraform v|^OpenTofu v' | cut ...` captured in a
command substitution and assigned to a variable. The script runs under `set -e -o pipefail`.
If the first line of the version banner does not match that anchored grep, `grep`
exits non-zero, `pipefail` propagates that failure to the whole pipeline, and `set -e`
aborts at the assignment. The very next line — `if [ $? -ne 0 ] || [ -z "$X" ]` with its
`_stderrlog "Error: '$TERRAFORM --version' failed?"` message — is therefore **dead code**
that can never run. The user gets a silent non-zero exit (in `_default_vars`) or silently
wrong behavior (in `_tf_ver`) instead of the intended error message.

## Affected code

```bash
# _tf_ver() — approx lines 429-438
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

```bash
# _default_vars() — TERRAFORM_NICE_NAME detection, approx lines 555-565
    # Detect the name of the Terraform/OpenTofu binary
    if [ -z "${TERRAFORM_NICE_NAME:-}" ] || [ -z "${TERRAFORM_SHORT_NAME:-}" ] ; then
        TERRAFORM_NICE_NAME="$($TERRAFORM --version | grep -E '^Terraform v|^OpenTofu v' | cut -d ' ' -f 1)"
        if [ $? -ne 0 ] || [ -z "$TERRAFORM_NICE_NAME" ] ; then
            _stderrlog "Error: '$TERRAFORM --version' failed?"
            return 1
        fi
        case "$TERRAFORM_NICE_NAME" in
            Terraform) TERRAFORM_SHORT_NAME="terraform" ;;
            OpenTofu) TERRAFORM_SHORT_NAME="tofu" ;;
        esac
    fi
```

The relevant call sites:

```bash
# top of script, approx line 6
set -e -u -o pipefail

# _cmd_validate() — approx line 178 (the only caller of _tf_ver)
    declare -a tfver_a=($(_tf_ver))

# main body — approx line 840 (the only caller of _default_vars)
_default_vars
```

## Why this is a bug

Two shell semantics combine here:

1. **`pipefail`** makes a pipeline's exit status the status of the **last command that
   exited non-zero**, not just the last command in the pipe. The pipeline is
   `$TERRAFORM --version | grep ... | cut ...`. `cut` is the last stage, and `cut` reads
   empty input happily and exits `0`. So *without* `pipefail` the pipeline would return
   `0` even when `grep` matched nothing — and the `[ -z "$tf_ver" ]` half of the check
   would actually catch the empty result. **It is `pipefail` specifically that breaks
   this.** With `pipefail` on, `grep`'s non-zero exit (no match) becomes the pipeline's
   exit status.

2. **`set -e`** aborts the shell when a command substitution used in an assignment fails.
   `tf_ver="$( ... pipeline ... )"` is exactly such an assignment, so when the pipeline
   returns non-zero the shell exits immediately — *before* reaching the `if [ $? -ne 0 ]`
   line. That guard, and the `_stderrlog` message it was meant to print, are unreachable.

Additionally, even in a hypothetical world without `set -e`, the `[ $? -ne 0 ]` check is
partly redundant: `$?` after `X="$(...)"` does reflect the substitution's exit status
(verified: `x="$(exit 7)"; echo $?` prints `7`), so the check is well-intentioned, but
`set -e` never lets control reach it under the current options.

The two call sites then diverge in how the failure surfaces:

- **`_default_vars`** is called as a bare top-level statement (`_default_vars` at approx
  line 840). When the abort fires inside it, `set -e` propagates up and the **entire
  script dies with exit status 1 and no message at all** — before any command runs.

- **`_tf_ver`** is called as `declare -a tfver_a=($(_tf_ver))` in `_cmd_validate`.
  The abort happens inside the `$(...)` subshell, so `_tf_ver` produces no output and
  exits non-zero. But because the result is consumed by the `declare` **builtin**,
  `set -e` does **not** abort the caller (set -e ignores the failure of the builtin that
  receives the substitution), so `tfver_a` is silently left **empty**. The following
  `[ "${tfver_a[0]:-}" = "0" ]` test (which uses `:-` defaults, so `set -u` is not
  tripped) then evaluates false, and validate proceeds as if the version were `>= 0.12` —
  quietly skipping the legacy varfile-passing branch. So here the bug is "silently wrong
  behavior" rather than "silent exit", and the error message is still never printed.

## How to reproduce / trigger

Point `TERRAFORM` at any tool whose `--version` first line is **not** `Terraform v...`
or `OpenTofu v...` — a fork, a localized/translated build, a dev build, or a wrapper that
prints a banner first:

```bash
# Make a fake tool whose --version banner doesn't match the grep
printf '#!/bin/sh\necho "MyTerraformFork v9.9.9"\n' > /tmp/fakeforktf
chmod +x /tmp/fakeforktf
TERRAFORM=/tmp/fakeforktf ./terraformsh -b backend.tfvars validate
# EXPECTED: a clear "Error: '<tool> --version' failed?" message.
# ACTUAL:   _default_vars aborts; the script exits 1 with no output whatsoever.
```

Minimal standalone reproduction of the mechanism (run and confirmed on
**GNU bash 5.2.21**):

```bash
# Reproduces the _default_vars path: bare assignment aborts before the guard.
bash -c 'set -e -u -o pipefail
echo before
NN="$(printf "MyFork v9\n" | grep -E "^Terraform v|^OpenTofu v" | cut -d " " -f 1)"
echo "after assignment reached, NN=[$NN]"   # never prints
if [ $? -ne 0 ] || [ -z "$NN" ] ; then echo "error branch"; fi   # dead code
'
# Output: only "before" is printed; the shell exits 1 immediately. (Verified.)
```

```bash
# Shows that pipefail is the culprit: cut is last and exits 0, so WITHOUT
# pipefail the assignment succeeds and the [ -z ] guard would actually work.
bash -c 'set -e -u
x="$(printf "foo\n" | grep -E "^Terraform v" | cut -d "v" -f 2)"
echo "reached, x=[$x]"; [ -n "$x" ] || echo "guard would catch empty"'
# Output: "reached, x=[]" then "guard would catch empty". (Verified.)
```

```bash
# Shows the _tf_ver call-site path: declare swallows the failure, leaving an empty array.
bash -c 'set -e -u -o pipefail
_tf_ver() { printf "MyFork v9\n" | grep -E "^Terraform v|^OpenTofu v" | cut -d "v" -f 2; }
echo before
declare -a tfver_a=($(_tf_ver))
echo "after declare reached, count=${#tfver_a[@]}"'   # prints "...count=0", script does NOT abort
# Output: "before" then "after declare reached, count=0", exit 0. (Verified.)
```

## Suggested fix

Separate the pipeline from the success check so the failure is detected explicitly
instead of being swallowed by `set -e`, and validate emptiness in the same `if`.
This also makes the intended error message reachable. Apply the same pattern to **both**
functions.

```diff
 _tf_ver () {
     local tf_ver
-    tf_ver="$($TERRAFORM --version | grep -E "^Terraform v|^OpenTofu v" | cut -d 'v' -f 2)"
-    if [ $? -ne 0 ] || [ -z "$tf_ver" ] ; then
+    if ! tf_ver="$($TERRAFORM --version | grep -E "^Terraform v|^OpenTofu v" | cut -d 'v' -f 2)" \
+         || [ -z "$tf_ver" ] ; then
         _stderrlog "Error: '$TERRAFORM --version' failed or returned an unrecognized version banner"
         return 1
     fi
     IFS=. read -r -a tfver_a <<< "${tf_ver}"
     printf "%s\n" "${tfver_a[@]}"
 }
```

```diff
     if [ -z "${TERRAFORM_NICE_NAME:-}" ] || [ -z "${TERRAFORM_SHORT_NAME:-}" ] ; then
-        TERRAFORM_NICE_NAME="$($TERRAFORM --version | grep -E '^Terraform v|^OpenTofu v' | cut -d ' ' -f 1)"
-        if [ $? -ne 0 ] || [ -z "$TERRAFORM_NICE_NAME" ] ; then
+        if ! TERRAFORM_NICE_NAME="$($TERRAFORM --version | grep -E '^Terraform v|^OpenTofu v' | cut -d ' ' -f 1)" \
+             || [ -z "$TERRAFORM_NICE_NAME" ] ; then
             _stderrlog "Error: '$TERRAFORM --version' failed or returned an unrecognized version banner"
             return 1
         fi
```

Note on `set -e` and `if`: a command (or pipeline) used as the **condition** of an `if`
is exempt from `set -e`, so `if ! X="$(pipeline)"` captures the failure and lets the
`_stderrlog`/`return 1` branch run instead of aborting. Verified that the corrected form
(a) errors cleanly on an unrecognized banner and (b) still works on a normal
`Terraform v1.5.7` banner.

Call-site impact to check (both fine, no further changes required):

- `_default_vars` is called once, bare, at approx line 840. With the fix it `return 1`s
  with a message; because that bare call is under `set -e`, the script still exits
  non-zero — but now *after* printing a useful error, which is the intended behavior.
- `_tf_ver` is called once, as `declare -a tfver_a=($(_tf_ver))` in `_cmd_validate`
  (approx line 178). With the fix, `_tf_ver` prints the error to stderr and returns 1;
  the `declare` still swallows the non-zero status, so validate continues with an empty
  `tfver_a` exactly as it does today — but at least the operator now sees an explanatory
  message. If stricter behavior is desired, the validate call site should be changed to
  capture and check `_tf_ver`'s status separately (e.g.
  `tfver_str="$(_tf_ver)" || _errexit "..."` then split into the array), but that is a
  larger behavioral change and out of scope for this minimal fix.

Optional hardening: broaden the grep (e.g. case-insensitive, or accept any
`^[A-Za-z]+ v[0-9]`) so legitimate forks/localized builds are not rejected in the first
place. That is a separate decision from making the error path reachable.

## Risk / impact

Anyone whose `terraform`/`tofu` binary (or a `TERRAFORM`-pointed wrapper/fork) emits a
first `--version` line that does not start with exactly `Terraform v` or `OpenTofu v`
is affected: localized output, forks, custom wrappers, future format changes, or a
binary that prints a deprecation/notice banner ahead of the version line. For such users
the script either dies at startup with **zero diagnostic output** (`_default_vars` path —
hits on essentially every command, because `_default_vars` runs before option parsing),
or silently mis-detects the version during `validate` and skips legacy-version handling
(`_tf_ver` path). The consequence is moderate: no data loss, but a confusing,
hard-to-debug "it just exits 1 and says nothing" failure that defeats the explicit
error message the author intended to provide. Frequency is low for stock binaries (whose
banners do match) but 100% reproducible for the affected configurations.

## Related findings

[06](06-validate-version-gate-swallows-and-crashes.md) — the analogous version/banner-parsing concern; this should likely be
bundled into the same PR as finding 06 since both touch the `$TERRAFORM --version`
parsing and the same `set -e`/`pipefail` interaction.
