# Finding 17: _cmd_aws_bootstrap bucket/dynamodb_table parsing only strips double quotes and caches first match

| Field | Value |
|-------|-------|
| Severity | Low |
| Category | Correctness bug |
| Affected function(s) | _cmd_aws_bootstrap |
| Empirically verified | Yes (bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

When the `aws_bootstrap` subcommand discovers the backend S3 bucket and DynamoDB
lock table by grepping the `-b` backend var files, it (1) only strips a leading
and trailing *double* quote, so single-quoted values and values with a trailing
`# comment` keep stray characters; and (2) caches the result with
`${VAR:-...}`, so the first backend file that contains a non-empty `bucket =` /
`dynamodb_table =` wins and a value in a later file can never override it.
The net effect is that the wrong (or syntactically corrupted) bucket/table name
can be passed to `aws s3api`, `aws dynamodb`, and `terraform import`, causing the
bootstrap to operate on the wrong resource or fail outright.

## Affected code

```bash
# _cmd_aws_bootstrap() — approx lines 358-367 (commit d0a01c3)
_cmd_aws_bootstrap () {
    _final_vars
    local bucket_region
    _cmd_clean_modules

    # Look though the backend var files for the backend bucket and dynamodb_table
    for varfile in "${BACKENDVARFILES[@]}" ; do
        TF_BACKEND_BUCKET="${TF_BACKEND_BUCKET:-$( grep -e "^[[:space:]]*bucket[[:space:]]\+=" < "$varfile" | sed -E 's/^[[:space:]]*bucket[[:space:]]+=[[:space:]]*//; s/^"//g; s/"$//g' )}"
        TF_BACKEND_TABLE="${TF_BACKEND_TABLE:-$( grep -e "^[[:space:]]*dynamodb_table[[:space:]]\+=" < "$varfile" | sed -E 's/^[[:space:]]*dynamodb_table[[:space:]]+=[[:space:]]*//; s/^"//g; s/"$//g' )}"
    done

    if [ -z "${TF_BACKEND_BUCKET:-}" ] || [ -z "${TF_BACKEND_TABLE:-}" ] ; then
        _errexit "Make sure 'bucket' and 'dynamodb_table' are set in your backend var files"
    fi
    ...
```

These extracted values are later used verbatim:

```bash
# _cmd_aws_bootstrap() — approx lines 382-397 (commit d0a01c3)
    bucket_region="$(aws s3api get-bucket-location \
        --bucket "${TF_BACKEND_BUCKET}" --query LocationConstraint --output text \
        || true )"
    ...
        _runcmd "$TERRAFORM" import "${IMPORT_ARGS[@]}" "${VARFILE_ARG[@]}" aws_s3_bucket.terraform_state "$TF_BACKEND_BUCKET"
    ...
    DYNAMODB_TABLE="$( aws dynamodb list-tables | jq -re "select(.TableNames | index(\"$TF_BACKEND_TABLE\")) | .TableNames[]" || true )"
    ...
        _runcmd "$TERRAFORM" import "${IMPORT_ARGS[@]}" "${VARFILE_ARG[@]}" aws_dynamodb_table.terraform_lock "$TF_BACKEND_TABLE" || true
```

## Why this is a bug

There are three independent defects in the extraction loop.

**1. Quote/comment stripping is incomplete.** The `sed` pipeline only removes a
leading `"` (`s/^"//g`) and a trailing `"` (`s/"$//g`). Terraform/HCL var files
permit single quotes, no quotes, and inline `# comments`:

- `dynamodb_table = 'my-locks'` → the single quotes are *not* stripped, leaving
  the literal value `'my-locks'`.
- `bucket = "intended-bucket" # production` → the trailing `"` is no longer at
  end-of-line, so `s/"$//g` does not fire; the value becomes
  `intended-bucket" # production`.

These corrupted strings are passed straight to `aws s3api --bucket ...`,
`aws dynamodb`, the `jq` query, and `terraform import`, which will either target
a non-existent resource or fail.

**2. `${VAR:-...}` freezes the first non-empty match.** `TF_BACKEND_BUCKET` and
`TF_BACKEND_TABLE` are **not** declared `local` and have no other default in the
script, so they are ordinary (potentially environment-inherited) variables. On
each loop iteration `TF_BACKEND_BUCKET="${TF_BACKEND_BUCKET:-$(...)}"` only
evaluates the `grep|sed` substitution while the variable is empty. As soon as one
backend file yields a non-empty `bucket =`, the value is locked in and every
later `-b` file is ignored for that key. This contradicts terraform's own
"last `-backend-config` wins" override semantics that the rest of the script
relies on (note `BACKENDVARFILE_ARG` is built in file order and passed to
`init`). Consequently, if a user passes a base backend file followed by an
environment-specific override file, `aws_bootstrap` bootstraps the *base*
bucket/table, not the override.

(Note: an *empty* match in an earlier file does **not** block a later file,
because `:-` only substitutes on empty — so the masking is specifically
"first file with a non-empty value wins", and a pre-set `TF_BACKEND_BUCKET`/
`TF_BACKEND_TABLE` environment variable also wins over all files.)

**3. The `grep` is unguarded, so a `-b` file that lacks the key aborts the
whole script.** The script runs under `set -e -u -o pipefail`. When a key is
still unset, `${VAR:-$( grep ... | sed ... )}` actually evaluates the command
substitution. Under `pipefail` the pipeline's exit status is the rightmost
*non-zero* status, so a no-match `grep` (exit 1) followed by a successful
`sed` (exit 0) makes the whole pipeline exit 1; that becomes the exit status
of the command substitution, hence of the assignment, and `set -e` aborts.
Verified on bash 5.2.21: a single `-b` file that contains `dynamodb_table =`
but **no** `bucket =` line causes the loop's first assignment to abort with
exit status 1 before the `dynamodb_table` line is even reached. So a backend
file that defines only one of the two keys (or any `-b` var file that defines
neither) makes `aws_bootstrap` die mid-loop rather than reaching the friendly
`_errexit` message at the emptiness check below. (The `${VAR:-...}` form does
**not** discard the failing exit status; it only skips running the substitution
when the variable is already non-empty — e.g. set from an earlier file or the
environment.)

## How to reproduce / trigger

terraformsh invocation that triggers it:

```sh
# backend-base.tfvars contains:   bucket = "base-bucket"
#                                 dynamodb_table = 'base-locks'
# backend-prod.tfvars contains:   bucket = "prod-bucket" # primary
#                                 dynamodb_table = "prod-locks"
terraformsh -b backend-base.tfvars -b backend-prod.tfvars aws_bootstrap
# EXPECTED: bootstraps bucket "prod-bucket" / table "prod-locks"
# ACTUAL:   bootstraps bucket "base-bucket" / table "'base-locks'" (note stray quotes)
```

Minimal standalone reproduction of the extraction logic (run on bash 5.2.21,
output shown):

```bash
bash -c '
set -e -u -o pipefail
printf "bucket = \"first-bucket\"\ndynamodb_table = '\''my-locks'\''\n" > bf1.tfvars
printf "bucket = \"intended-bucket\"\ndynamodb_table = \"intended-table\" # production\n" > bf2.tfvars
BACKENDVARFILES=(bf1.tfvars bf2.tfvars)
for varfile in "${BACKENDVARFILES[@]}" ; do
    TF_BACKEND_BUCKET="${TF_BACKEND_BUCKET:-$( grep -e "^[[:space:]]*bucket[[:space:]]\+=" < "$varfile" | sed -E '\''s/^[[:space:]]*bucket[[:space:]]+=[[:space:]]*//; s/^"//g; s/"$//g'\'' )}"
    TF_BACKEND_TABLE="${TF_BACKEND_TABLE:-$( grep -e "^[[:space:]]*dynamodb_table[[:space:]]\+=" < "$varfile" | sed -E '\''s/^[[:space:]]*dynamodb_table[[:space:]]+=[[:space:]]*//; s/^"//g; s/"$//g'\'' )}"
done
printf "BUCKET=[%s]\nTABLE=[%s]\n" "${TF_BACKEND_BUCKET:-}" "${TF_BACKEND_TABLE:-}"
'
```

Actual output (verified):

```
BUCKET=[first-bucket]
TABLE=['my-locks']
```

EXPECTED would be `BUCKET=[intended-bucket]` and `TABLE=[intended-table]`.
The result shows **both** defects at once: `first-bucket` masks the intended
later value (caching), and `'my-locks'` keeps its single quotes (parsing).

Single-defect isolation (also verified on bash 5.2.21):

```
$ printf "dynamodb_table = 'my-locks'\n"            | sed -E 's/.../; s/^"//g; s/"$//g'  ->  'my-locks'
$ printf 'bucket = "intended-bucket" # production\n' | sed -E 's/.../; s/^"//g; s/"$//g'  ->  intended-bucket" # production
```

## Suggested fix

Strip single OR double quotes and any trailing inline comment, and stop caching
across the loop: scope the extraction per file and let the **last** matching file
win (matching terraform's `-backend-config` override order), while still
honouring an explicitly pre-set `TF_BACKEND_BUCKET`/`TF_BACKEND_TABLE`.

```bash
# Replace the extraction loop in _cmd_aws_bootstrap()
_parse_backend_value () {
    # $1 = HCL key, $2 = file. Prints the last matching value with
    # surrounding single/double quotes and trailing # comment removed.
    # NOTE: the `|| true` is REQUIRED under `set -e -o pipefail`: a no-match
    # grep exits non-zero, and with pipefail that propagates through the
    # `| sed | tail` pipeline (pipefail reports the rightmost non-zero status),
    # which would otherwise abort the script. `2>/dev/null` alone is NOT enough
    # — it only suppresses stderr, not the exit code.
    { grep -E "^[[:space:]]*$1[[:space:]]*=" "$2" || true; } \
      | sed -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^[\"']//; s/[\"']\$//" \
      | tail -n 1
}

# Look through the backend var files for the backend bucket and dynamodb_table.
# Honour any pre-set TF_BACKEND_BUCKET/TF_BACKEND_TABLE, otherwise let the
# last backend file that defines the key win (matching -backend-config order).
for varfile in "${BACKENDVARFILES[@]}" ; do
    _b="$(_parse_backend_value bucket "$varfile")"
    _t="$(_parse_backend_value dynamodb_table "$varfile")"
    [ -n "${TF_BACKEND_BUCKET:-}" ] || { [ -n "$_b" ] && TF_BACKEND_BUCKET_F="$_b"; }
    [ -n "${TF_BACKEND_TABLE:-}"  ] || { [ -n "$_t" ] && TF_BACKEND_TABLE_F="$_t"; }
done
TF_BACKEND_BUCKET="${TF_BACKEND_BUCKET:-${TF_BACKEND_BUCKET_F:-}}"
TF_BACKEND_TABLE="${TF_BACKEND_TABLE:-${TF_BACKEND_TABLE_F:-}}"
```

A simpler in-place version that keeps the original variable shape but fixes both
bugs (last-file-wins, robust stripping) is:

```diff
-    for varfile in "${BACKENDVARFILES[@]}" ; do
-        TF_BACKEND_BUCKET="${TF_BACKEND_BUCKET:-$( grep -e "^[[:space:]]*bucket[[:space:]]\+=" < "$varfile" | sed -E 's/^[[:space:]]*bucket[[:space:]]+=[[:space:]]*//; s/^"//g; s/"$//g' )}"
-        TF_BACKEND_TABLE="${TF_BACKEND_TABLE:-$( grep -e "^[[:space:]]*dynamodb_table[[:space:]]\+=" < "$varfile" | sed -E 's/^[[:space:]]*dynamodb_table[[:space:]]+=[[:space:]]*//; s/^"//g; s/"$//g' )}"
-    done
+    for varfile in "${BACKENDVARFILES[@]}" ; do
+        # `|| true` is REQUIRED under set -e -o pipefail so a no-match grep
+        # (file lacks the key) does not propagate a non-zero status and abort.
+        _b="$( { grep -E "^[[:space:]]*bucket[[:space:]]*=" "$varfile" || true; } | sed -E 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//' | tail -n 1 )"
+        _t="$( { grep -E "^[[:space:]]*dynamodb_table[[:space:]]*=" "$varfile" || true; } | sed -E 's/^[[:space:]]*dynamodb_table[[:space:]]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'"'"']//; s/["'"'"']$//' | tail -n 1 )"
+        [ -n "$_b" ] && TF_BACKEND_BUCKET="$_b"
+        [ -n "$_t" ] && TF_BACKEND_TABLE="$_t"
+    done
```

Verified on bash 5.2.21 that the new parser returns `intended-bucket`,
`my-locks`, `intended-bucket` (comment case), `plainbucket` (unquoted) and `b`
(two matches, last wins) for the respective inputs, and that a file with **no**
matching key returns an empty string *without aborting* the script (the
`{ grep ... || true; }` guard is what makes the no-match case safe under
`set -e -o pipefail`).

Notes for the reviewer:
- `TF_BACKEND_BUCKET` / `TF_BACKEND_TABLE` are only read inside
  `_cmd_aws_bootstrap`; they are not consumed by any other function, so changing
  the assignment logic has no other call sites to update.
- Under `set -e -u -o pipefail`, the `grep | sed | tail` pipeline is **not**
  automatically safe: with `pipefail` the pipeline's exit status is the
  rightmost *non-zero* status, so a no-match `grep` (exit 1) makes the whole
  pipeline exit 1 even though `tail` succeeds, and `set -e` then aborts the
  assignment. That is why both fixes above wrap the grep as
  `{ grep ... || true; }` — confirmed on bash 5.2.21 that without the `|| true`
  a backend file lacking the key aborts the loop, and with it the loop
  completes and leaves the value empty.
- Keep the existing emptiness check (`if [ -z ... ]`) — it still correctly errors
  when neither files nor environment supplied a value.

## Risk / impact

Only users of the `aws_bootstrap` subcommand who (a) write single-quoted or
trailing-comment backend values, or (b) pass multiple `-b` backend files where
more than one defines `bucket`/`dynamodb_table`, are affected. `aws_bootstrap`
is a one-shot setup action, so exposure is occasional, but the consequence is
meaningful: the script may try to import/create the **wrong** S3 bucket and
DynamoDB table, or pass a syntactically invalid name to the AWS CLI / terraform
import and fail. Because it manipulates remote state infrastructure, a silently
wrong bucket/table is worse than an outright error. Severity is Low because the
common single-file, double-quoted layout works fine and nothing is destroyed —
the failure mode is a misdirected or aborted bootstrap.

## Related findings

- [10](10-aws-bootstrap-double-backend-config.md) — related backend-file handling.
- [22](22-aws-bootstrap-altitude.md) — related backend-file handling.

This finding is self-contained but touches the same backend-var-file parsing
area as findings 10 and 22; if those are addressed together, consider bundling
the fixes into one PR.
