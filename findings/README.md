# terraformsh — code-review findings

Detailed, PR-ready write-ups of issues found by a multi-angle review of the
`terraformsh` script. **One file per finding.** Each doc is self-contained:
summary, the affected code (verbatim), why it's a bug, how to reproduce, and a
concrete suggested fix.

- **Reference commit:** `d0a01c3` (line numbers in the docs refer to this commit).
- **Locate code by function name + quoted snippets, not line numbers** — line
  numbers will drift as fixes land PR-by-PR.
- Each finding was drafted against the live source and then **adversarially
  re-verified** against the code; several were corrected in that pass.

## All findings

| # | Severity | Function(s) | Finding | Doc |
|---|----------|-------------|---------|-----|
| 01 | High | `_mktemp` | _mktemp does not reset OPTIND, so `state rm` writes its state backup to /tmp instead of the module dir | [open](01-mktemp-optind-not-reset.md) |
| 02 | High | `_cmd_apply` | _cmd_apply errored.tfstate recovery is unreachable (set -e abort + impossible condition + inverted guard) | [open](02-apply-errored-tfstate-recovery-dead-code.md) |
| 03 | High | `_cmd_init` | _already_ran_cmd_init is never reset, so an explicit `init` after a dependency init is silently skipped | [open](03-already-ran-cmd-init-never-reset.md) |
| 04 | Medium-High | `_tf_ver / _default_vars` | Startup version parse aborts with no message when the --version banner does not match the grep | [open](04-version-banner-parse-aborts-silently.md) |
| 05 | Medium-High | `_process_cmds` | _process_cmds splits one invocation in two when a token collides with a command name | [open](05-process-cmds-subcommand-split.md) |
| 06 | Medium | `_cmd_validate` | validate version gate swallows _tf_ver failure and emits a spurious error on a non-numeric minor version | [open](06-validate-version-gate-swallows-and-crashes.md) |
| 07 | Medium-Low | `_cmd_approve` | _cmd_approve aborts before the YES/NO check on non-interactive (EOF) stdin | [open](07-approve-read-aborts-on-eof.md) |
| 08 | Medium-Low | `_cmd_shell` | _cmd_shell captures ret=$? after `! _cmd_get`, which is always 0, masking the real failure | [open](08-shell-negated-ret-mask.md) |
| 09 | Medium | `_rfindfiles` | _rfindfiles uses an unquoted `for p in $cwd/$f`, breaking auto-discovery in paths with spaces | [open](09-rfindfiles-unquoted-glob-wordsplit.md) |
| 10 | Medium-Low | `_cmd_aws_bootstrap` | _cmd_aws_bootstrap passes -backend-config twice to the final init | [open](10-aws-bootstrap-double-backend-config.md) |
| 11 | Low-Medium | `_mktemp` | _mktemp can loop forever when the target directory is unwritable (errors hidden by 2>&-) | [open](11-mktemp-infinite-loop-unwritable-dir.md) |
| 12 | Portability | `(pervasive)` | Empty `"${arr[@]}"` under set -u aborts on bash <= 4.3 (e.g. macOS stock bash 3.2) | [open](12-empty-array-set-u-old-bash.md) |
| 13 | Low | `_rfindfiles` | _rfindfiles never searches direct children of / (root off-by-one) | [open](13-rfindfiles-skips-first-level-dirs.md) |
| 14 | Low | `_readlinkf` | _readlinkf leaks globals (t, link, m_s) and clears CDPATH process-wide | [open](14-readlinkf-global-variable-leak.md) |
| 15 | Low | `_cmd_destroy / _default_vars` | USE_PLANFILE default is read as :-0 in destroy but initialized as :-1 elsewhere | [open](15-use-planfile-default-mismatch.md) |
| 16 | Security | `_load_conf / -E` | terraformsh sources ./.terraformshrc and ./terraformsh.conf from the CWD with no trust check | [open](16-implicit-code-execution-from-cwd.md) |
| 17 | Low | `_cmd_aws_bootstrap` | _cmd_aws_bootstrap bucket/dynamodb_table parsing only strips double quotes and caches first match | [open](17-aws-bootstrap-value-parsing-fragile.md) |
| 18 | Maintainability | `most _cmd_*` | ~20 near-identical _cmd_* wrappers are copy-paste with drift | [open](18-duplicated-cmd-functions.md) |
| 19 | Maintainability | `_default_vars` | The both/terraform/tofu selection cascade is open-coded four times | [open](19-tool-cascade-duplicated.md) |
| 20 | Maintainability | `_tf_ver / _default_vars` | `$TERRAFORM --version` is parsed with a duplicated regex and spawned repeatedly instead of cached | [open](20-version-spawned-repeatedly.md) |
| 21 | Maintainability | `_process_cmds` | _process_cmds builds `array=(...)` source strings that are later eval'd to pass arrays | [open](21-eval-constructed-array.md) |
| 22 | Maintainability | `_cmd_aws_bootstrap` | aws_bootstrap hardcodes AWS S3/DynamoDB/jq into an otherwise cloud-agnostic wrapper | [open](22-aws-bootstrap-altitude.md) |

## Correctness — High

### [01 — _mktemp does not reset OPTIND, so `state rm` writes its state backup to /tmp instead of the module dir](01-mktemp-optind-not-reset.md)
*Severity: High · Function(s): `_mktemp`*  
_mktemp never resets OPTIND, so a stale cursor from the main parser (or a prior call) skips its `-p DIR`, dumping the `state rm` backup tfstate into /tmp.
  
*Related / consider bundling with: 11.*

### [02 — _cmd_apply errored.tfstate recovery is unreachable (set -e abort + impossible condition + inverted guard)](02-apply-errored-tfstate-recovery-dead-code.md)
*Severity: High · Function(s): `_cmd_apply`*  
The default-on PUSH_ERRORED_TFSTATE apply recovery is triple-dead code, and the inverted pre-existing-file guard makes a successful apply report failure when a stale errored.tfstate exists.

### [03 — _already_ran_cmd_init is never reset, so an explicit `init` after a dependency init is silently skipped](03-already-ran-cmd-init-never-reset.md)
*Severity: High · Function(s): `_cmd_init`*  
A process-global init guard is never reset, so an explicit init or a dependency init after `clean` is silently skipped and terraform runs against a wiped/uninitialized directory.

## Correctness — Medium

### [04 — Startup version parse aborts with no message when the --version banner does not match the grep](04-version-banner-parse-aborts-silently.md)
*Severity: Medium-High · Function(s): `_tf_ver / _default_vars`*  
Under set -e + pipefail, an unrecognized `terraform/tofu --version` banner makes the version-parse assignment fail and abort before the error-message guard, which is dead code.
  
*Related / consider bundling with: 06, 20.*

### [05 — _process_cmds splits one invocation in two when a token collides with a command name](05-process-cmds-subcommand-split.md)
*Severity: Medium-High · Function(s): `_process_cmds`*  
A positional argument (workspace name, resource address, output name) that spells a Terraform command word is misread as a new command, silently splitting one intended run into two wrong terraform invocations.
  
*Related / consider bundling with: 21.*

### [06 — validate version gate swallows _tf_ver failure and emits a spurious error on a non-numeric minor version](06-validate-version-gate-swallows-and-crashes.md)
*Severity: Medium · Function(s): `_cmd_validate`*  
declare masks a failing _tf_ver under set -e, and the unquoted -lt test prints a spurious diagnostic (it does NOT crash) on an empty or non-numeric minor version.
  
*Related / consider bundling with: 04.*

### [09 — _rfindfiles uses an unquoted `for p in $cwd/$f`, breaking auto-discovery in paths with spaces](09-rfindfiles-unquoted-glob-wordsplit.md)
*Severity: Medium · Function(s): `_rfindfiles`*  
Unquoted `for p in $cwd/$f` in `_rfindfiles` word-splits any space-containing ancestor path, so parent terraform.sh.tfvars / backend.sh.tfvars files are silently never inherited.
  
*Related / consider bundling with: 13.*

### [10 — _cmd_aws_bootstrap passes -backend-config twice to the final init](10-aws-bootstrap-double-backend-config.md)
*Severity: Medium-Low · Function(s): `_cmd_aws_bootstrap`*  
The final S3 re-init in aws_bootstrap duplicates every -backend-config flag because INIT_ARGS already contains BACKENDVARFILE_ARG and the line passes it again explicitly.
  
*Related / consider bundling with: 17, 22.*

## Correctness — Low

### [07 — _cmd_approve aborts before the YES/NO check on non-interactive (EOF) stdin](07-approve-read-aborts-on-eof.md)
*Severity: Medium-Low · Function(s): `_cmd_approve`*  
Under set -e, `read` at EOF (CI/pipe/`< /dev/null`) aborts _cmd_approve before the YES check, so the "Approval not given; exiting!" message never prints and the script exits 1 silently.

### [08 — _cmd_shell captures ret=$? after `! _cmd_get`, which is always 0, masking the real failure](08-shell-negated-ret-mask.md)
*Severity: Medium-Low · Function(s): `_cmd_shell`*  
In `_cmd_shell`, `ret=$?` runs after `! _cmd_get` inside an `if`, so it always captures 0 and the dependency failure is logged but never propagated.

### [11 — _mktemp can loop forever when the target directory is unwritable (errors hidden by 2>&-)](11-mktemp-infinite-loop-unwritable-dir.md)
*Severity: Low-Medium · Function(s): `_mktemp`*  
_mktemp's unbounded collision loop spins forever (silent CPU-burning hang) when -p points at a read-only or nonexistent dir, because every touch/mkdir fails with stderr closed by 2>&- and there is no attempt cap — triggered by `terraformsh state rm` from an unwritable launch dir.
  
*Related / consider bundling with: 01.*

### [13 — _rfindfiles never searches direct children of / (root off-by-one)](13-rfindfiles-skips-first-level-dirs.md)
*Severity: Low · Function(s): `_rfindfiles`*  
_rfindfiles' loop guard tests dirname(cwd)=="/" at the top, so it exits before ever searching any first-level directory (e.g. /tmp, /opt), silently dropping auto-config files placed there.
  
*Related / consider bundling with: 09.*

### [17 — _cmd_aws_bootstrap bucket/dynamodb_table parsing only strips double quotes and caches first match](17-aws-bootstrap-value-parsing-fragile.md)
*Severity: Low · Function(s): `_cmd_aws_bootstrap`*  
aws_bootstrap's backend-file scraping keeps single quotes/inline comments and caches the first non-empty bucket/table, so a later -b file can never override and corrupted names reach the AWS CLI.
  
*Related / consider bundling with: 10, 22.*

## Portability

### [12 — Empty `"${arr[@]}"` under set -u aborts on bash <= 4.3 (e.g. macOS stock bash 3.2)](12-empty-array-set-u-old-bash.md)
*Severity: Portability · Function(s): `(pervasive)`*  
Bare `"${arr[@]}"` expansion of empty default arrays under `set -u` aborts with "unbound variable" on bash <= 4.3 (incl. macOS stock /bin/bash 3.2), breaking nearly every command on those platforms.

## Security

### [16 — terraformsh sources ./.terraformshrc and ./terraformsh.conf from the CWD with no trust check](16-implicit-code-execution-from-cwd.md)
*Severity: Security · Function(s): `_load_conf / -E`*  
Running any terraformsh command in an untrusted directory sources ./terraformsh.conf (plain bash) with no ownership or opt-in check, giving local arbitrary code execution before terraform ever runs.

## Hygiene

### [14 — _readlinkf leaks globals (t, link, m_s) and clears CDPATH process-wide](14-readlinkf-global-variable-leak.md)
*Severity: Low · Function(s): `_readlinkf`*  
_readlinkf uses unscoped t/link/m_s and clears CDPATH without `local`, but is safe today only because every call site wraps it in `$(...)` — a latent hygiene hazard, not a live bug.

### [15 — USE_PLANFILE default is read as :-0 in destroy but initialized as :-1 elsewhere](15-use-planfile-default-mismatch.md)
*Severity: Low · Function(s): `_cmd_destroy / _default_vars`*  
USE_PLANFILE is initialized as :-1 in _default_vars but read as :-0 in _cmd_destroy and bare (no fallback) in plan/apply — three inconsistent representations of one flag, harmless today only because _default_vars always sets it first.

## Maintainability (cleanup / altitude)

### [18 — ~20 near-identical _cmd_* wrappers are copy-paste with drift](18-duplicated-cmd-functions.md)
*Severity: Maintainability · Function(s): `most _cmd_*`*  
~16 _cmd_* wrappers repeat the same 4-line skeleton and have already drifted: DESTROY_ARGS and VARFILE_ARG land in different argument slots than the plan/refresh/import family.
  
*Related / consider bundling with: 19.*

### [19 — The both/terraform/tofu selection cascade is open-coded four times](19-tool-cascade-duplicated.md)
*Severity: Maintainability · Function(s): `_default_vars`*  
Four `$TERRAFORM_TOOLS_EXIST` dispatches in `_default_vars` are copy-pasted, and the two file-list cascades already disagree: a terraform-only host lists `terraform.sh.tfvars` first for var-files but `tofush.conf` first for conf-files.
  
*Related / consider bundling with: 18, 20.*

### [20 — `$TERRAFORM --version` is parsed with a duplicated regex and spawned repeatedly instead of cached](20-version-spawned-repeatedly.md)
*Severity: Maintainability · Function(s): `_tf_ver / _default_vars`*  
The Terraform/OpenTofu version banner is parsed with the same hard-coded regex in two places and the binary is re-forked at least twice per run for an immutable value, while the post-assignment `[ $? -ne 0 ]` error guards are dead code under `set -e -o pipefail`.
  
*Related / consider bundling with: 04, 19.*

### [21 — _process_cmds builds `array=(...)` source strings that are later eval'd to pass arrays](21-eval-constructed-array.md)
*Severity: Maintainability · Function(s): `_process_cmds`*  
_process_cmds serializes parsed commands into literal `array=(...)` bash source in CMD_PAIRS, which the dispatch loop eval's back into an array — a fragile, eval-of-generated-code idiom that's trivially replaceable with namerefs.
  
*Related / consider bundling with: 05.*

### [22 — aws_bootstrap hardcodes AWS S3/DynamoDB/jq into an otherwise cloud-agnostic wrapper](22-aws-bootstrap-altitude.md)
*Severity: Maintainability · Function(s): `_cmd_aws_bootstrap`*  
The single-cloud aws_bootstrap command bakes AWS resource addresses, the aws/jq CLIs, S3/DynamoDB HCL, and a magic sleep 60 into an otherwise backend-neutral terraform wrapper.
  
*Related / consider bundling with: 10, 17.*

## Suggested PR bundling

Some findings touch the same function and are cleanest to fix together:

- **`_mktemp`** — 01 (OPTIND) + 11 (infinite loop)
- **`_rfindfiles`** — 09 (unquoted glob) + 13 (root off-by-one)
- **`_cmd_aws_bootstrap`** — 10 (double backend-config) + 17 (value parsing); 22 (altitude) is a larger refactor, keep separate
- **version handling** — 04 (silent abort) + 06 (validate gate) + 20 (caching), all in `_tf_ver`/`_default_vars`
- **cleanup/altitude** (18–22) are refactors; land them after the correctness fixes so diffs stay reviewable

> Tip: fix in roughly the table order (High → Low). After each merged PR, the
> remaining docs' line numbers shift — use the function names to relocate code.
