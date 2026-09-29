# Finding 20: `$TERRAFORM --version` is parsed with a duplicated regex and spawned repeatedly instead of cached

| Field | Value |
|-------|-------|
| Severity | Maintainability |
| Category | Cleanup / efficiency |
| Affected function(s) | `_tf_ver`, `_default_vars` (consumer: `_cmd_validate`) |
| Empirically verified | Yes (bash 5.x, mock `terraform`) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

The script extracts information from `$TERRAFORM --version` in two separate
places (`_default_vars` for the tool's "nice name" / "short name", and `_tf_ver`
for the numeric version). Both places hard-code the *same* selector regex
`grep -E '^Terraform v|^OpenTofu v'`, and each fork a fresh
`terraform`/`tofu --version` subprocess for a value that is immutable for the
entire lifetime of the run. As a result the binary is spawned at least twice per
invocation (and `_tf_ver` is re-spawned every time `_cmd_validate` runs), and the
parsing regex must be kept in sync by hand in two locations. A secondary
observation: the `if [ $? -ne 0 ]` error guard immediately after each assignment
behaves inconsistently under `set -e -o pipefail` depending on the call context
of the enclosing function (see "Why this is a bug").

## Affected code

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

```bash
# _default_vars() — TERRAFORM_NICE_NAME / TERRAFORM_SHORT_NAME block — approx lines 554-565 (commit d0a01c3)
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

```bash
# _cmd_validate() — the sole consumer of _tf_ver — approx lines 174-184 (commit d0a01c3)
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

## Why this is a bug

This is a maintainability / efficiency defect, not a correctness bug in the happy
path. Three distinct issues:

1. **Duplicated regex.** The selector `^Terraform v|^OpenTofu v` is written
   verbatim in `_tf_ver` (with double quotes) and again in `_default_vars` (with
   single quotes). When OpenTofu/Terraform change their `--version` banner, or a
   third tool is added, both copies must be edited in lockstep. The only
   difference between the two sites is the post-`grep` extraction
   (`cut -d 'v' -f 2` for the numeric version vs. `cut -d ' ' -f 1` for the name)
   — the source line and the selector are identical.

2. **Repeated subprocess spawns for an immutable value.** The tool name/short
   name is derived once at startup (`_default_vars`), but `_tf_ver` forks
   `$TERRAFORM --version` *again* every time `_cmd_validate` runs. For commands
   such as `plan`/`apply`/`plan_destroy`/`destroy` that depend on
   `_cmd_validate`, that is at least two `--version` forks per run, and more if
   multiple commands are chained on one command line. The version string never
   changes within a single process, so it should be computed once and cached in a
   global.

3. **The `[ $? -ne 0 ]` guard behaves inconsistently and is fragile under
   `set -e -o pipefail`.** The whole script runs under `set -e -u -o pipefail`
   (line 6). In both sites, `$?` is read on the line *after* the assignment, so it
   reflects the **assignment command** as a whole, not specifically the `grep`
   stage. With `pipefail` enabled, if `grep` matches nothing the pipeline exits
   non-zero and the assignment command itself fails. What happens next depends
   entirely on the *call context* of the enclosing function — verified empirically
   on bash 5.2:

   - **`_default_vars` (called bare at top level, line 840):** `set -e` fires at
     the failing assignment line and aborts the **whole script** (exit 1) *before*
     the `if [ $? -ne 0 ]` check runs. The `return 1` and the custom message
     `"Error: '$TERRAFORM --version' failed?"` are **never reached** — here the
     guard really is dead code.

   - **`_tf_ver` (invoked as `declare -a tfver_a=($(_tf_ver))` in `_cmd_validate`):**
     because the function runs inside a command substitution whose value is being
     consumed, `set -e` is *suspended* for the failing assignment, so execution
     **does** fall through to the `if [ $? -ne 0 ]` guard, the custom error message
     **does** print, and the function returns 1. However, that `return 1` is then
     swallowed: the surrounding `declare -a tfver_a=(...)` succeeds (rc 0), `set -e`
     does not abort, and `_cmd_validate` continues with an **empty** `tfver_a`
     array. So the guard is *not* dead here, but it is also ineffective at stopping
     the run.

   The `[ -z "$tf_ver" ]` fallback only meaningfully fires in the command-subst
   context (where `set -e` was suspended); on the anchored pattern it would only
   match an empty capture after a *successful* grep, which cannot happen. The net
   result is an error-handling path whose effect depends on how each function is
   called rather than on a single explicit check. Folding this into one explicit
   pipeline-failure check makes the failure handling behave consistently in both
   sites.

## How to reproduce / trigger

Any command that runs `_cmd_validate` (e.g. `plan`, `apply`, `plan_destroy`,
`destroy`, or `validate` itself) will fork `$TERRAFORM --version` once at startup
in `_default_vars` and again inside `_tf_ver`:

```sh
# Each of these spawns `$TERRAFORM --version` at least twice:
terraformsh -b backend.tfvars plan
terraformsh validate
```

Minimal standalone reproduction of the two parse sites and the spawn count
(ran on bash 5.x — output shown):

```bash
#!/usr/bin/env bash
set -e -u -o pipefail

# Mock `terraform` that logs every --version invocation
cat > /tmp/tfmock.sh <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && echo "INVOKED" >> /tmp/tfver_count.log
cat <<'VER'
Terraform v1.7.5
on linux_amd64
+ provider registry.terraform.io/hashicorp/aws v5.0.0
VER
EOF
chmod +x /tmp/tfmock.sh
rm -f /tmp/tfver_count.log
export TERRAFORM=/tmp/tfmock.sh

# Site 1: _default_vars (startup) — same regex
TERRAFORM_NICE_NAME="$($TERRAFORM --version | grep -E '^Terraform v|^OpenTofu v' | cut -d ' ' -f 1)"

# Site 2: _tf_ver (called by _cmd_validate) — same regex, different cut
_tf_ver () {
    local tf_ver
    tf_ver="$($TERRAFORM --version | grep -E "^Terraform v|^OpenTofu v" | cut -d 'v' -f 2)"
    if [ $? -ne 0 ] || [ -z "$tf_ver" ] ; then return 1 ; fi
    IFS=. read -r -a tfver_a <<< "${tf_ver}"
    printf "%s\n" "${tfver_a[@]}"
}
declare -a tfver_a=($(_tf_ver))

echo "spawns for one validate run: $(wc -l < /tmp/tfver_count.log)"
# EXPECTED (ideal): 1
# ACTUAL:           2
```

Observed output: `spawns for one validate run: 2`.

To exercise the `[ $? -ne 0 ]` guard, point `TERRAFORM` at a mock that prints a
banner the regex does not match (e.g. `echo "SomethingElse v9.9.9"`). The
behavior differs by call context, and both cases were reproduced on bash 5.2:

- Calling the function **bare at top level** (as `_default_vars` is invoked):
  under `set -e -o pipefail` the failing assignment line aborts the whole script
  with the bare pipeline status, the post-assignment `if` is skipped, and the
  custom `"... --version failed?"` message never prints.
- Calling it via **command substitution** (as `_cmd_validate` does with
  `declare -a tfver_a=($(_tf_ver))`): `set -e` is suspended for the assignment,
  so the `if` *does* run, the custom message *does* print, and the function
  returns 1 — but that return code is swallowed by the surrounding `declare`,
  so the script continues with an empty `tfver_a` array instead of stopping.

## Suggested fix

Compute the version line **once** in `_default_vars` using the selector regex in a
single place, derive the nice name, short name, and numeric-version array from
that one capture, and store them in globals. Reduce `_tf_ver` to echoing the
cached array (no subprocess). Replace the fragile `[ $? -ne 0 ]` guards with a
single explicit pipeline-failure check that behaves the same regardless of call
context.

```bash
# --- in _default_vars(), replace the TERRAFORM_NICE_NAME block ---
    # Detect the name + version of the Terraform/OpenTofu binary ONCE and cache it.
    if [ -z "${TERRAFORM_NICE_NAME:-}" ] || [ -z "${TERRAFORM_SHORT_NAME:-}" ] ; then
        # Single source of truth for the version-banner selector.
        if ! TF_VERSION_LINE="$($TERRAFORM --version | grep -E '^Terraform v|^OpenTofu v')" \
           || [ -z "$TF_VERSION_LINE" ] ; then
            _stderrlog "Error: '$TERRAFORM --version' failed or produced unexpected output?"
            return 1
        fi
        TERRAFORM_NICE_NAME="${TF_VERSION_LINE%% *}"   # 'Terraform' / 'OpenTofu'
        TF_VERSION="${TF_VERSION_LINE#* v}"            # 'X.Y.Z' (everything after ' v')
        IFS=. read -r -a TF_VERSION_ARRAY <<< "$TF_VERSION"
        case "$TERRAFORM_NICE_NAME" in
            Terraform) TERRAFORM_SHORT_NAME="terraform" ;;
            OpenTofu)  TERRAFORM_SHORT_NAME="tofu" ;;
        esac
    fi
```

```bash
# --- _tf_ver() becomes a pure cache reader (no fork, no regex) ---
_tf_ver () {
    printf "%s\n" "${TF_VERSION_ARRAY[@]}"
}
```

Notes / call sites to check together:

- `_cmd_validate` is the **only** caller of `_tf_ver`; it consumes
  `tfver_a[0]` / `tfver_a[1]` (major/minor) and is unchanged by this fix — the
  cached `TF_VERSION_ARRAY` carries the same `IFS=.`-split fields. Verified with a
  mock returning both `Terraform v1.7.5` and `OpenTofu v1.6.2`: the cached path
  yields the identical array and the `< 0.12` branch logic still behaves
  correctly.
- `${TF_VERSION_LINE#* v}` (strip up to the first " v") is equivalent to the old
  `cut -d 'v' -f 2` for every real banner, including `0.11.14` and `1.10.0-rc1`,
  and is safer than `cut -d 'v'` if a future tool name ever contained a `v`
  (verified against representative version strings).
- `_default_vars` declares these as globals already by virtue of being run at top
  level; add `TF_VERSION`, `TF_VERSION_ARRAY`, and `TF_VERSION_LINE` to the
  top-of-script `declare -a` / variable initialization area if you want them
  documented alongside the other state (`TF_VERSION_ARRAY` should be declared
  with `declare -a`).
- Because the new check uses `if ! ... ; then`, the assignment runs in a context
  where `set -e` does not abort it (the `!` / `if` makes the failure handled), so
  the custom error message becomes reliably reachable and the `return 1` actually
  stops the function in both call contexts — addressing the inconsistency in
  defect (3).

## Risk / impact

Low. This is invisible to correct runs (output is unchanged), but it (a) doubles
the `--version` forks on the most common code paths, which matters slightly for
slow-spawning binaries or heavily-scripted/CI loops, (b) creates a two-copy regex
that can silently diverge when banners change, and (c) leaves a failure-handling
path whose effect (abort vs. print-and-continue-with-empty-array) depends on the
call context rather than on one explicit check. Fixing it removes a maintenance
footgun and the redundant subprocess at no behavioral cost.

## Related findings

- [04](04-version-banner-parse-aborts-silently.md) — related `$?`-after-assignment / error-handling-under-`set -e`
  pattern; the dead-guard portion of this finding is the same class of issue and
  could be reviewed alongside it.
- [19](19-tool-cascade-duplicated.md) — related cleanup/efficiency item.

This finding can reasonably be bundled into the same PR as finding 04 if that PR
is sweeping the `[ $? -ne 0 ]`-after-assignment anti-pattern, since the cleanest
fix here removes two more instances of it.
