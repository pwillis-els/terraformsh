# Finding 22: aws_bootstrap hardcodes AWS S3/DynamoDB/jq into an otherwise cloud-agnostic wrapper

| Field | Value |
|-------|-------|
| Severity | Maintainability |
| Category | Altitude |
| Affected function(s) | _cmd_aws_bootstrap |
| Empirically verified | Reasoned (mechanism repro'd on bash 5.2) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`terraformsh` is otherwise a thin, provider-neutral wrapper: every other command
(`plan`, `apply`, `init`, `import`, `state`, ...) delegates to `terraform`/`tofu`
and works equally well with S3, GCS, `azurerm`, Consul, or `local` backends.
`_cmd_aws_bootstrap` breaks that abstraction. It is a single-cloud special case
bolted onto the shared dispatcher: it shells out to the `aws` CLI and `jq`, bakes
in the exact Terraform resource addresses `aws_s3_bucket.terraform_state` and
`aws_dynamodb_table.terraform_lock`, emits S3/DynamoDB backend HCL, and hardcodes
a `sleep 60` for S3 eventual consistency. GCS/Azure/Consul users get a command
that cannot work for them, and the wrapper gains a hard `aws`+`jq` dependency for
one command. This is a maintainability/altitude concern, not a correctness bug —
the AWS path itself works.

## Affected code

```bash
# _cmd_aws_bootstrap() — approx lines 358-416 (commit d0a01c3)
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

    # Create a local terraform backend - OpenTofu still uses the 'terraform' syntax for this block
    printf "terraform {\n\tbackend local {}\n}\n" > terraformsh-backend.tf

    # First remove any existing previous local state
    _cmd_clean
    # Initialize local state
    _cmd_init

    # Attempt to import bucket if it exists
    bucket_region="$(aws s3api get-bucket-location \
        --bucket "${TF_BACKEND_BUCKET}" --query LocationConstraint --output text \
        || true )"
    if [ -n "$bucket_region" ] ; then
        _stderrlog "Info: importing existing S3 bucket '$TF_BACKEND_BUCKET' ..."
        _runcmd "$TERRAFORM" import "${IMPORT_ARGS[@]}" "${VARFILE_ARG[@]}" aws_s3_bucket.terraform_state "$TF_BACKEND_BUCKET"
    else
        _stderrlog "Info: Did not find existing S3 bucket '$TF_BACKEND_BUCKET'; creating..."
    fi

    # Attempt to import dynamodb table if it exists
    # TODO: replace 'jq' here with a --query in the AWS CLI
    DYNAMODB_TABLE="$( aws dynamodb list-tables | jq -re "select(.TableNames | index(\"$TF_BACKEND_TABLE\")) | .TableNames[]" || true )"
    if [ -n "$DYNAMODB_TABLE" ] ; then
        _stderrlog "Info: importing existing DynamoDB table '$TF_BACKEND_TABLE' ..."
        _runcmd "$TERRAFORM" import "${IMPORT_ARGS[@]}" "${VARFILE_ARG[@]}" aws_dynamodb_table.terraform_lock "$TF_BACKEND_TABLE" || true
    else
        _stderrlog "Info: Did not find backend table '$TF_BACKEND_TABLE'; creating..."
    fi

    # Plan & Apply to create the dynamodb table and s3 bucket
    _runcmd "$TERRAFORM" plan -input=false "${VARFILE_ARG[@]}" \
        -target aws_dynamodb_table.terraform_lock \
        -target aws_s3_bucket.terraform_state \
        -out "$TF_BOOTSTRAP_PLANFILE"
    _runcmd "$TERRAFORM" apply -input=false "$TF_BOOTSTRAP_PLANFILE"

    # Create an s3 terraform backend - OpenTofu still uses the 'terraform' syntax for this block
    printf "terraform {\n\tbackend s3 {}\n}\n" > terraformsh-backend.tf

    _stderrlog "Sleeping 60 seconds before querying bucket again ..."
    sleep 60

    _runcmd "$TERRAFORM" init "${INIT_ARGS[@]}" "${BACKENDVARFILE_ARG[@]}"
}
```

It is registered as a first-class command alongside the cloud-neutral ones:

```bash
# top-level command tables (commit d0a01c3)
declare -a WRAPPER_COMMANDS=(plan_destroy shell clean clean_modules approve aws_bootstrap revgrep)
```

```text
# usage text (approx lines 82-83)
    aws_bootstrap     Looks for 'bucket' and 'dynamodb_table' in your '-b' file options.
                      If found, creates the bucket and table and initializes your $TERRAFORM_NICE_NAME state with them.
```

## Why this is a bug

This is an **altitude / maintainability** problem, not a runtime correctness bug —
the AWS happy path works. The issues:

1. **Provider coupling in shared infrastructure.** The generic dispatcher
   (`command -v _cmd_"$name" ... && _cmd_"$name" ...`) and all the other `_cmd_*`
   functions are backend-agnostic — they only ever invoke `$TERRAFORM` with
   user-supplied `-backend-config` files, so S3, GCS, `azurerm`, Consul, and
   `local` all work identically. `_cmd_aws_bootstrap` is the only command that
   reaches outside Terraform to a specific cloud's CLI. A GCS or Azure user who
   types `terraformsh ... aws_bootstrap` gets a command that is structurally
   incapable of working for them.

2. **Hard `aws` + `jq` dependency for one command.** The script does not
   `require`/check for `aws` or `jq` anywhere; they appear only inside this
   function. Worse, both external calls end in `|| true`, so under
   `set -e -u -o pipefail` a missing `aws`/`jq` does **not** abort — the command
   substitution simply yields an empty string and the function silently proceeds
   to the `else` branch ("Did not find existing ... creating..."), then tries to
   `plan`/`apply` AWS resources that the user's module may not even contain. The
   `pipefail`-sensitive pipe `aws ... | jq ...` is fully masked by the trailing
   `|| true`, so there is no early, clear error.

3. **Hardcoded resource addresses.** `aws_s3_bucket.terraform_state` and
   `aws_dynamodb_table.terraform_lock` are baked into both the `import` and the
   `plan -target` lines. The user's bootstrap module must name its resources
   exactly this way or the command fails — an undocumented contract embedded in
   the wrapper.

4. **Hardcoded `sleep 60`.** A fixed S3 eventual-consistency wait that is neither
   configurable nor poll-based: it is both too long for fast cases and
   potentially too short for slow ones, and is meaningless for non-S3 backends.

None of this is wrong on AWS; it is simply a single-cloud concern living in a
cloud-neutral tool, which makes the tool harder to reason about, harder to extend
to other backends, and gives non-AWS users a footgun command.

## How to reproduce / trigger

**terraformsh command line (AWS user, intended path):**

```sh
terraformsh -b backend.s3.tfvars aws_bootstrap
```

**Non-AWS user / missing tooling (the altitude problem):** a GCS user runs
`terraformsh -b backend.gcs.tfvars aws_bootstrap`. The function first errors out
because GCS backend config has no `bucket`/`dynamodb_table` HCL keys it greps for
— but even with those present, it would shell out to `aws`/`jq` and emit
`backend s3 {}` HCL, which is nonsensical for GCS.

**Minimal standalone repro (ran on bash 5.2):** demonstrate that the
`pipefail`-protected `aws | jq` line silently swallows a missing-`aws`/`jq`
environment because of `|| true`, instead of failing loudly:

```bash
bash -c '
set -e -u -o pipefail
PATH=/usr/bin:/bin            # pretend aws and jq are not installed
TF_BACKEND_TABLE="my-lock-table"
DYNAMODB_TABLE="$( aws dynamodb list-tables | jq -re "select(.TableNames | index(\"$TF_BACKEND_TABLE\")) | .TableNames[]" || true )"
echo "reached past it, DYNAMODB_TABLE=[$DYNAMODB_TABLE]"
'
```

EXPECTED (for a robust cloud-neutral tool): a clear "aws/jq required for
aws_bootstrap" error, or no such AWS-only command at all in the shared dispatcher.

ACTUAL (observed): prints `aws: command not found` to stderr, then
`reached past it, DYNAMODB_TABLE=[]`, and **exits 0** — the failure is masked by
`|| true`, so the function proceeds as if no DynamoDB table exists. The same holds
for the `aws s3api get-bucket-location ... || true` call. I ran both repros.

## Suggested fix

The cleanest fix is an **altitude** one: extract the cloud-specific bootstrap into
a pluggable hook or a separate companion script so the core dispatcher stays
provider-neutral. As a smaller, lower-risk improvement that keeps the command in
place, (a) fail fast if `aws`/`jq` are missing, (b) make the resource addresses
configurable, and (c) replace the fixed `sleep 60` with a configurable, poll-based
wait. Sketch:

```bash
# 1. Make the AWS-only dependency explicit and loud (no more silent || true masking).
_cmd_aws_bootstrap () {
    command -v aws >/dev/null || _errexit "aws_bootstrap requires the 'aws' CLI"
    command -v jq  >/dev/null || _errexit "aws_bootstrap requires 'jq'"
    _final_vars
    local bucket_region
    _cmd_clean_modules
    ...

    # 2. Make resource addresses overridable instead of hardcoded.
    local state_addr="${TF_BOOTSTRAP_STATE_ADDR:-aws_s3_bucket.terraform_state}"
    local lock_addr="${TF_BOOTSTRAP_LOCK_ADDR:-aws_dynamodb_table.terraform_lock}"
    ...
        _runcmd "$TERRAFORM" import "${IMPORT_ARGS[@]}" "${VARFILE_ARG[@]}" "$state_addr" "$TF_BACKEND_BUCKET"
    ...
    _runcmd "$TERRAFORM" plan -input=false "${VARFILE_ARG[@]}" \
        -target "$lock_addr" \
        -target "$state_addr" \
        -out "$TF_BOOTSTRAP_PLANFILE"
    ...

    # 3. Configurable, poll-based wait instead of a magic sleep 60.
    local wait="${TF_BOOTSTRAP_WAIT:-60}"
    _stderrlog "Waiting up to ${wait}s for new S3 backend to become consistent ..."
    sleep "$wait"
    ...
}
```

A fuller fix factors the body into a backend-neutral hook, e.g. dispatch to a
`bootstrap-${BACKEND_TYPE}` function or an external
`terraformsh-bootstrap-aws` script, so GCS/Azure can supply their own.

**Other call sites to check:** `_cmd_aws_bootstrap` is invoked only via the
generic dispatcher loop (`_cmd_"$name" "${array[@]:1}"`) after being listed in
`WRAPPER_COMMANDS`; it is not called by any other `_cmd_*` function. The internal
helpers it calls (`_cmd_clean_modules`, `_cmd_clean`, `_cmd_init`, `_runcmd`,
`_final_vars`, `_stderrlog`, `_errexit`) are shared and provider-neutral, so the
changes above are self-contained — no other function needs to change. If the
command is renamed or moved to a separate script, also update the
`WRAPPER_COMMANDS` array and the usage text (approx lines 82-83).

## Risk / impact

Low operational severity, real maintainability cost. Hit by:

- **AWS users:** the command works today; impact is only the silent-fallthrough
  footgun if `aws`/`jq` are missing or unauthenticated (a no-op import that then
  attempts to create resources), and the inflexible `sleep 60`.
- **GCS/Azure/Consul/local users:** there is a prominent top-level command they
  cannot use; it advertises a capability the tool only delivers for one cloud.
- **Maintainers:** a provider-specific special case in shared infrastructure
  raises the barrier to adding bootstrap support for other backends and obscures
  the otherwise-clean "thin terraform wrapper" design.

No data loss or security risk; the consequence is confusion, a hidden
`aws`+`jq` runtime dependency, and reduced extensibility.

## Related findings

- [10](10-aws-bootstrap-double-backend-config.md) — related provider/altitude coupling concern.
- [17](17-aws-bootstrap-value-parsing-fragile.md) — related.

Consider bundling this with finding 10 if both address the same
provider-neutrality / altitude theme in one PR.
