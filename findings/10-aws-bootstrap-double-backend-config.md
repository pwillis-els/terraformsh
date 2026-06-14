# Finding 10: _cmd_aws_bootstrap passes -backend-config twice to the final init

| Field | Value |
|-------|-------|
| Severity | Medium-Low |
| Category | Correctness bug |
| Affected function(s) | `_cmd_aws_bootstrap` (with `_final_vars`) |
| Empirically verified | Yes — mechanism reproduced in isolation on bash 5.x |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

When `aws_bootstrap` reaches its final `init` (the re-init against the freshly
created S3 backend), it runs `init "${INIT_ARGS[@]}" "${BACKENDVARFILE_ARG[@]}"`.
But `INIT_ARGS` already contains `BACKENDVARFILE_ARG`: `_final_vars` appended it
exactly once at the start of the bootstrap (guarded by `_final_vars_set`). The
explicit second `${BACKENDVARFILE_ARG[@]}` therefore duplicates every
`-backend-config <file>` flag on that final init invocation. The regular
`_cmd_init` does **not** do this — it relies on `INIT_ARGS` alone — so the
duplication is unique to this one line in `_cmd_aws_bootstrap`.

## Affected code

```bash
# _cmd_aws_bootstrap() — approx lines 358-416 (only the relevant head + final init shown)
_cmd_aws_bootstrap () {
    _final_vars
    local bucket_region
    _cmd_clean_modules
    ...
    _stderrlog "Sleeping 60 seconds before querying bucket again ..."
    sleep 60

    _runcmd "$TERRAFORM" init "${INIT_ARGS[@]}" "${BACKENDVARFILE_ARG[@]}"
}
```

```bash
# _final_vars_set / _final_vars() — approx lines 616-637
_final_vars_set=0
_final_vars () {
    _dirchange
    _tf_set_datadir
    ...
    if [ "${_final_vars_set}" = "0" ] ; then
        if [ ${#BACKENDVARFILE_ARG[@]} -lt 1 ] ; then
            _stderrlog "Warning: No -b option passed! Potentially using only local state."
            [ $QUIET_MODE -eq 1 ] || echo "" 1>&2
            sleep 1
        else
            INIT_ARGS+=("${BACKENDVARFILE_ARG[@]}")
        fi
    fi
    _final_vars_set=1
}
```

```bash
# _cmd_init() — approx lines 229-235 (for contrast: it does NOT re-add BACKENDVARFILE_ARG)
_cmd_init () {
    [ "${_already_ran_cmd_init:-0}" = "1" ] && return 0
    _already_ran_cmd_init=1
    _final_vars
    declare -a args=("$@")
    _runcmd "$TERRAFORM" init "${INIT_ARGS[@]}" "${args[@]}"
}
```

```bash
# _pre_dirchange_vars() — approx lines 604-615 (where BACKENDVARFILE_ARG is built)
    if [ ${#BACKENDVARFILES[@]} -gt 0 ] ; then
        for arg in "${BACKENDVARFILES[@]}" ; do
            BACKENDVARFILE_ARG+=("-backend-config" "$(_readlinkf "$arg")")
        done
    fi
```

## Why this is a bug

`BACKENDVARFILE_ARG` is built once in `_pre_dirchange_vars` as a flat array of
`-backend-config <path>` pairs (one pair per `-b` file). `_final_vars` folds that
array into `INIT_ARGS` exactly once for the whole program run: the body that does
`INIT_ARGS+=("${BACKENDVARFILE_ARG[@]}")` is gated by `[ "${_final_vars_set}" = "0" ]`,
and `_final_vars` sets `_final_vars_set=1` on its first call. Every subsequent
`_final_vars` call (there are many — each `_cmd_*` calls it) skips that block.

`_cmd_aws_bootstrap` calls `_final_vars` as its very first statement, so by the
time control reaches the final line:

```bash
_runcmd "$TERRAFORM" init "${INIT_ARGS[@]}" "${BACKENDVARFILE_ARG[@]}"
```

`INIT_ARGS` already ends with the full `BACKENDVARFILE_ARG` contents, and the
explicit `"${BACKENDVARFILE_ARG[@]}"` appends them a second time. Bash array
expansion (`"${arr[@]}"`) splices each element as a separate word, so the result
is literally `... -backend-config <path> ... -backend-config <path>` — the same
flag/value pair appears twice (or N times twice, for N `-b` files).

This is purely a duplication on the bootstrap path. The ordinary `_cmd_init`
shows the intended pattern: it passes only `"${INIT_ARGS[@]}"` (plus any caller
`args`), trusting that `_final_vars` already merged the backend config. The
bootstrap line is the outlier that double-counts.

Note on severity: Terraform/OpenTofu generally tolerate a repeated identical
`-backend-config=key=value` / `-backend-config <file>` (later wins / merge
semantics), so this is unlikely to hard-fail in the common case where every `-b`
file resolves to the same path. It is still incorrect, noisy in the `+ ...` trace
emitted by `_runcmd`, and could behave surprisingly if backend files were ever
expected to be order-sensitive or if a future tool version rejected duplicates.
Hence Medium-Low rather than High.

## How to reproduce / trigger

terraformsh command line:

```bash
terraformsh -b backend.tfvars aws_bootstrap
```

EXPECTED: the final S3 re-init runs with one `-backend-config backend.tfvars`
pair (matching what plain `terraformsh -b backend.tfvars init` would emit).

ACTUAL: the final init runs with `-backend-config backend.tfvars` **twice**.

Minimal standalone `bash -c` reproduction of the mechanism (run; output shown):

```bash
bash -c '
set -e -u -o pipefail
declare -a BACKENDVARFILE_ARG=("-backend-config" "/tmp/backend.tfvars")
declare -a INIT_ARGS=("-input=false" "-reconfigure" "-force-copy")
_final_vars_set=0
# _final_vars folds BACKENDVARFILE_ARG into INIT_ARGS exactly once:
if [ "${_final_vars_set}" = "0" ] ; then
    if [ ${#BACKENDVARFILE_ARG[@]} -ge 1 ] ; then
        INIT_ARGS+=("${BACKENDVARFILE_ARG[@]}")
    fi
fi
_final_vars_set=1
# Final init line in _cmd_aws_bootstrap:
final=( "init" "${INIT_ARGS[@]}" "${BACKENDVARFILE_ARG[@]}" )
count=0; for a in "${final[@]}"; do [ "$a" = "-backend-config" ] && count=$((count+1)); done
echo "final init: ${final[*]}"
echo "-backend-config count: $count"
'
```

Observed output:

```
final init: init -input=false -reconfigure -force-copy -backend-config /tmp/backend.tfvars -backend-config /tmp/backend.tfvars
-backend-config count: 2
```

The same construction with the regular `_cmd_init` line (`init "${INIT_ARGS[@]}"`
only) yields a `-backend-config count` of 1, confirming the bootstrap line is the
sole source of the duplication.

## Suggested fix

Drop the explicit trailing `"${BACKENDVARFILE_ARG[@]}"` on the final init and rely
on `INIT_ARGS`, exactly as `_cmd_init` does. This keeps the bootstrap consistent
with every other init path.

```diff
-    _runcmd "$TERRAFORM" init "${INIT_ARGS[@]}" "${BACKENDVARFILE_ARG[@]}"
+    _runcmd "$TERRAFORM" init "${INIT_ARGS[@]}"
```

Why this is safe:

- `INIT_ARGS` already contains the merged `BACKENDVARFILE_ARG` (folded in by
  `_final_vars` on the bootstrap's first `_final_vars` call), so the S3 re-init
  still receives the `-backend-config` flags exactly once.
- The `-b`-absent case still works: if no `-b` was passed, `_final_vars` skips the
  `INIT_ARGS+=` and the init runs without any `-backend-config`, which is the same
  behavior the explicit-array form produced (an empty `"${BACKENDVARFILE_ARG[@]}"`
  expansion).

Things to check together with this change (do not need to be in the same diff,
but verify they still behave):

- **The local→S3 backend switch.** Earlier in `_cmd_aws_bootstrap`, the first
  `_cmd_init` (line ~379) initializes the *local* backend written to
  `terraformsh-backend.tf` (`backend local {}`). Because `_final_vars` already
  folded `BACKENDVARFILE_ARG` into `INIT_ARGS` before that first init, the local
  init also receives `-backend-config` flags today. That is a pre-existing
  behavior independent of this duplication bug; this fix does not change it. If
  you want the local init to be backend-config-free, that is a separate change
  (handle it as its own finding/PR rather than bundling).
- **`_cmd_init`'s own line** already uses `"${INIT_ARGS[@]}"` with no extra
  `BACKENDVARFILE_ARG`, so no change is needed there — the fix simply makes
  `_cmd_aws_bootstrap` match it.

Alternative (more invasive) approach if you prefer not to depend on the
`INIT_ARGS` mutation: build a local init-args array in `_cmd_aws_bootstrap` that
explicitly does not double-count, e.g. start from the base init flags plus
`BACKENDVARFILE_ARG` once. The one-line removal above is simpler and lower-risk.

## Risk / impact

Hit by anyone running `aws_bootstrap` with one or more `-b` backend files (i.e.
essentially everyone who uses the bootstrap feature, since the command errors out
unless `bucket`/`dynamodb_table` are found in a `-b` file). It happens every time
the bootstrap reaches the final S3 re-init. Consequence is usually benign because
Terraform/OpenTofu accept the repeated identical `-backend-config`, but it
produces a misleading command trace and is fragile: with multiple distinct `-b`
files the duplicated, re-ordered flag stream is harder to reason about, and a
stricter future tool version could reject duplicate backend-config flags. Low
likelihood of a hard failure, moderate likelihood of confusion — hence Medium-Low.

## Related findings

- [17](17-aws-bootstrap-value-parsing-fragile.md) — related handling of `BACKENDVARFILE_ARG` / `INIT_ARGS`.
- [22](22-aws-bootstrap-altitude.md) — related backend-config / init-args concern.

Consider bundling this fix with finding 17 if both touch the
`INIT_ARGS` / `BACKENDVARFILE_ARG` merge, since they share the same data flow.
