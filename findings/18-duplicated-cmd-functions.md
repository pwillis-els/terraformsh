# Finding 18: ~20 near-identical _cmd_* wrappers are copy-paste with drift

| Field | Value |
|-------|-------|
| Severity | Maintainability |
| Category | Cleanup / reuse |
| Affected function(s) | _cmd_plan, _cmd_plan_destroy, _cmd_destroy, _cmd_validate, _cmd_get, _cmd_refresh, _cmd_output, _cmd_force-unlock, _cmd_0.12upgrade, _cmd_0.13upgrade, _cmd_console, _cmd_init, _cmd_import, _cmd_taint, _cmd_untaint, _cmd_show (plus the special-cased _cmd_apply, _cmd_state, _cmd_workspace) |
| Empirically verified | Reasoned + reproduced (drift shown on bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

Roughly sixteen `_cmd_*` functions are mechanical copies of the same four-line
skeleton: call `_final_vars`, optionally run a dependency command, capture `"$@"`
into a local `args` array, then call `_runcmd "$TERRAFORM" <name> <pieces>`. The
only thing that varies per function is the command name, the per-command
`*_ARGS` array, and whether `VARFILE_ARG` is included. Because every variant was
written by hand, the *order* of those pieces has already drifted: in
`_cmd_destroy` the per-command `DESTROY_ARGS` array is appended **after** the
user's arguments, whereas in `_cmd_plan`/`_cmd_refresh`/`_cmd_import`/`_cmd_console`
the per-command array comes **before** the user's arguments, and in
`_cmd_aws_bootstrap` `VARFILE_ARG` comes **after** `IMPORT_ARGS` instead of
before it as in `_cmd_import`. This is not a crash bug, but it is a maintenance
hazard: every change to the shared contract has to be edited in ~16 places, and
the existing divergence shows that this already fails to happen in practice. A
small data-driven table plus one generic runner would eliminate the duplication
and the drift.

## Affected code

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
# _cmd_refresh() — approx lines 191-196
_cmd_refresh () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    _runcmd "$TERRAFORM" refresh "${VARFILE_ARG[@]}" "${REFRESH_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_import() — approx lines 236-241
_cmd_import () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    _runcmd "$TERRAFORM" import "${VARFILE_ARG[@]}" "${IMPORT_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_console() — approx lines 221-226
_cmd_console () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    _runcmd "$TERRAFORM" console "${VARFILE_ARG[@]}" "${CONSOLE_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_taint() — approx lines 242-247   (no VARFILE_ARG; otherwise identical)
_cmd_taint () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    _runcmd "$TERRAFORM" taint "${TAINT_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_untaint() — approx lines 248-253  (same skeleton, different name/array)
_cmd_untaint () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    _runcmd "$TERRAFORM" untaint "${UNTAINT_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_get() — approx lines 185-190
_cmd_get () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init # 'terraform get' does nothing if we have not initialized terraform
    declare -a args=("$@")
    _runcmd "$TERRAFORM" get "${GET_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_force-unlock() — approx lines 203-208
_cmd_force-unlock () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    _runcmd "$TERRAFORM" force-unlock "${FORCEUNLOCK_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_0.12upgrade() / _cmd_0.13upgrade() — approx lines 209-220 (identical bodies, OH12/OH13)
_cmd_0.12upgrade () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    _runcmd "$TERRAFORM" 0.12upgrade "${OH12UPGRADE_ARGS[@]}" "${args[@]}"
}
_cmd_0.13upgrade () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    _runcmd "$TERRAFORM" 0.13upgrade "${OH13UPGRADE_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_show() — approx lines 290-295   (dependency redirected to stderr: drift #2)
_cmd_show () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init 1>&2 # Send all previous command output to STDERR
    declare -a args=("$@")
    _runcmd "$TERRAFORM" show "${SHOW_ARGS[@]}" "${args[@]}"
}
```

```bash
# _cmd_output() — approx lines 197-202  (dependency is _cmd_refresh, redirected to stderr)
_cmd_output () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_refresh 1>&2 # Send all previous command output to STDERR
    declare -a args=("$@")
    _runcmd "$TERRAFORM" output "${OUTPUT_ARGS[@]}" "${args[@]}"
}
```

Now the divergence. `_cmd_destroy` orders the per-command array **last**, after
the user's `args`, unlike every other wrapper above:

```bash
# _cmd_destroy() — approx lines 161-171  (DESTROY_ARGS appended AFTER user args)
_cmd_destroy () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
    declare -a args=("$@")
    if [ "${USE_PLANFILE:-0}" = "0" ] ; then
        _runcmd "$TERRAFORM" destroy "${VARFILE_ARG[@]}" "${args[@]}" "${DESTROY_ARGS[@]}"
    else
        args+=("$TF_DESTROY_PLANFILE") # Pass plan file after '$@'
        _runcmd "$TERRAFORM" apply "${DESTROY_ARGS[@]}" "${args[@]}" && rm -f "$TF_DESTROY_PLANFILE"
    fi
}
```

And `_cmd_aws_bootstrap` orders `VARFILE_ARG` **after** `IMPORT_ARGS`, the
opposite of `_cmd_import`:

```bash
# _cmd_aws_bootstrap() — approx lines 387 & 397 (IMPORT_ARGS before VARFILE_ARG)
    _runcmd "$TERRAFORM" import "${IMPORT_ARGS[@]}" "${VARFILE_ARG[@]}" aws_s3_bucket.terraform_state "$TF_BACKEND_BUCKET"
    ...
    _runcmd "$TERRAFORM" import "${IMPORT_ARGS[@]}" "${VARFILE_ARG[@]}" aws_dynamodb_table.terraform_lock "$TF_BACKEND_TABLE" || true
```

## Why this is a bug

This is a maintainability defect, not a runtime crash. Three concrete symptoms:

1. **Inconsistent argument ordering (already drifted).** The shared contract is
   "command name, then `VARFILE_ARG`, then the per-command `*_ARGS` defaults,
   then the user's positional args". The plan/refresh/import/console wrappers
   follow `<VARFILE> <CMD_ARGS> <args>`, and the get/taint/untaint/show/output
   wrappers (which omit `VARFILE_ARG`) follow the matching `<CMD_ARGS> <args>`. But
   `_cmd_destroy`'s non-planfile branch emits `<VARFILE> <args> <CMD_ARGS>`,
   placing `DESTROY_ARGS` (which contains `-input=false`) *after* whatever the
   user typed, and `_cmd_aws_bootstrap` emits `<CMD_ARGS> <VARFILE>`. For
   Terraform CLI flags order is usually irrelevant, so today these mostly
   produce the same result — but the divergence means there is no single source
   of truth, and a future flag whose position *does* matter (or a user override
   intended to come last) will behave differently per command for no documented
   reason.

2. **Every shared change is an N-way edit.** A change to the common skeleton —
   e.g. fixing the empty-array-under-`set -u` problem on bash < 4.4 (related
   finding 12), adding a hook before `_runcmd`, or changing how the dependency
   guard reads `NO_DEP_CMDS` — must be applied identically to ~16 functions.
   The probability that all 16 stay in sync is low; the existing drift is the
   proof.

3. **Two more silent inconsistencies riding along.** The `1>&2` redirection on
   the dependency call exists in `_cmd_show`, `_cmd_output`, `_cmd_state`,
   `_cmd_workspace` but not in `_cmd_plan`, `_cmd_refresh`, etc.; and the
   dependency itself varies (`_cmd_validate` vs `_cmd_init` vs `_cmd_get` vs
   `_cmd_refresh`). These are legitimate per-command differences, but because
   they are expressed as hand-written code rather than data, you cannot tell at
   a glance which differences are intentional and which are copy-paste accidents.

Note on `set -u`: each wrapper expands arrays like `"${VARFILE_ARG[@]}"` and
`"${PLAN_ARGS[@]}"` unguarded. Under `set -u` on bash ≥ 4.4 an empty array
expands to nothing safely, but on bash < 4.4 `"${arr[@]}"` for an empty array
raises `unbound variable` (this is the subject of related finding 12). Because
the pattern is duplicated ~16 times, a fix for that issue is itself a 16-way
edit unless this consolidation lands first.

## How to reproduce / trigger

The drift is structural — you can see it directly with a side-by-side print of
the argument vectors each wrapper builds. Run this standalone snippet (ran on
bash 5.2.21, output shown):

```bash
bash -c '
set -e -u -o pipefail
VARFILE_ARG=("-var-file" "common.tfvars")
DESTROY_ARGS=("-input=false")
IMPORT_ARGS=("-input=false")
user_args=("addr1")

echo "=== _cmd_destroy (USE_PLANFILE=0 branch): CMD_ARGS come LAST ==="
printf "%q " destroy "${VARFILE_ARG[@]}" "${user_args[@]}" "${DESTROY_ARGS[@]}"; echo

echo "=== _cmd_import: CMD_ARGS come BEFORE user args ==="
printf "%q " import "${VARFILE_ARG[@]}" "${IMPORT_ARGS[@]}" "${user_args[@]}"; echo

echo "=== _cmd_aws_bootstrap import: VARFILE comes AFTER CMD_ARGS ==="
printf "%q " import "${IMPORT_ARGS[@]}" "${VARFILE_ARG[@]}" aws_s3_bucket.x bkt; echo
'
```

EXPECTED (if the contract were uniform): the per-command `*_ARGS` defaults and
`VARFILE_ARG` would sit in the same relative slot for every command.

ACTUAL (observed):

```
=== _cmd_destroy (USE_PLANFILE=0 branch): CMD_ARGS come LAST ===
destroy -var-file common.tfvars addr1 -input=false
=== _cmd_import: CMD_ARGS come BEFORE user args ===
import -var-file common.tfvars -input=false addr1
=== _cmd_aws_bootstrap import: VARFILE comes AFTER CMD_ARGS ===
import -input=false -var-file common.tfvars aws_s3_bucket.x bkt
```

`-input=false` lands in a different slot in each case, and `-var-file` precedes
vs follows the defaults inconsistently. A real terraformsh invocation such as
`terraformsh -f common.tfvars -P destroy addr1` versus
`terraformsh -f common.tfvars import addr1 id1` exercises exactly these two code
paths.

I also verified that a single data-driven runner reproduces the *uniform*
ordering for all of plan/refresh/import/console/taint from one code path (ran on
bash 5.2.21) — see the fix below; the demo output was:

```
+ echo plan -var-file common.tfvars -input=false user1 user2
+ echo refresh -var-file common.tfvars -input=false user1 user2
+ echo import -var-file common.tfvars -input=false user1 user2
+ echo console -var-file common.tfvars user1 user2
+ echo taint user1 user2
```

## Suggested fix

Replace the ~16 mechanical wrappers with one generic runner driven by three
associative-array tables: the dependency command, whether `VARFILE_ARG` is
included, and the name of the per-command `*_ARGS` variable. Keep the genuinely
special functions (`_cmd_apply`, `_cmd_destroy`, `_cmd_plan` [planfile `-out`],
`_cmd_plan_destroy`, `_cmd_validate` [version gate], `_cmd_state`/`_cmd_workspace`
[subcommand musical-chairs], `_cmd_init` [run-once guard], `_cmd_shell`,
`_cmd_clean*`, `_cmd_approve`, `_cmd_revgrep`, `_cmd_env`, `_cmd_aws_bootstrap`,
`_cmd_catchall`) as bespoke functions — those have logic the table cannot
express.

`declare -n` (namerefs) require bash ≥ 4.3; the script already uses `declare -n`
in `_process_cmds` (`declare -n arr="TF_CMDS_$prevcmd"`), so this raises no new
floor.

```bash
# Tables (place near _default_vars where the *_ARGS defaults already live).
#   dependency command, whether to prepend VARFILE_ARG, per-command args var,
#   and whether the dependency's output is redirected to stderr.
declare -A _CMD_DEP=(
    [refresh]=init [output]=refresh [force-unlock]=init
    [0.12upgrade]=init [0.13upgrade]=init [console]=init
    [get]=init [import]=init [taint]=init [untaint]=init [show]=init
)
declare -A _CMD_USE_VARFILE=(
    [refresh]=1 [console]=1 [import]=1
    # get/taint/untaint/show/output/force-unlock/0.1x = 0 (default)
)
declare -A _CMD_ARGSVAR=(
    [refresh]=REFRESH_ARGS [output]=OUTPUT_ARGS [force-unlock]=FORCEUNLOCK_ARGS
    [0.12upgrade]=OH12UPGRADE_ARGS [0.13upgrade]=OH13UPGRADE_ARGS
    [console]=CONSOLE_ARGS [get]=GET_ARGS [import]=IMPORT_ARGS
    [taint]=TAINT_ARGS [untaint]=UNTAINT_ARGS [show]=SHOW_ARGS
)
declare -A _CMD_DEP_STDERR=( [show]=1 [output]=1 )   # which deps redirect to stderr

_cmd_generic () {
    local name="$1"; shift
    _final_vars
    if [ "${NO_DEP_CMDS:-0}" = "0" ] && [ -n "${_CMD_DEP[$name]:-}" ] ; then
        if [ "${_CMD_DEP_STDERR[$name]:-0}" = "1" ] ; then
            "_cmd_${_CMD_DEP[$name]}" 1>&2
        else
            "_cmd_${_CMD_DEP[$name]}"
        fi
    fi
    declare -a args=("$@") varfile=()
    [ "${_CMD_USE_VARFILE[$name]:-0}" = "1" ] && varfile=("${VARFILE_ARG[@]}")
    declare -n _argsref="${_CMD_ARGSVAR[$name]}"
    # uniform contract: <name> <VARFILE> <CMD_ARGS> <user args>
    _runcmd "$TERRAFORM" "$name" "${varfile[@]}" "${_argsref[@]}" "${args[@]}"
}
```

Then either delete the per-command wrappers and route the dispatcher at the
bottom of the script through `_cmd_generic`, or keep one-line shims for clarity:

```bash
_cmd_refresh ()      { _cmd_generic refresh "$@"; }
_cmd_get ()          { _cmd_generic get "$@"; }
_cmd_import ()       { _cmd_generic import "$@"; }
_cmd_console ()      { _cmd_generic console "$@"; }
_cmd_taint ()        { _cmd_generic taint "$@"; }
_cmd_untaint ()      { _cmd_generic untaint "$@"; }
_cmd_show ()         { _cmd_generic show "$@"; }
_cmd_output ()       { _cmd_generic output "$@"; }
_cmd_force-unlock () { _cmd_generic force-unlock "$@"; }
_cmd_0.12upgrade ()  { _cmd_generic 0.12upgrade "$@"; }
_cmd_0.13upgrade ()  { _cmd_generic 0.13upgrade "$@"; }
```

Alternatively the bottom-of-script dispatcher can call `_cmd_generic "$name"`
directly when no specific `_cmd_$name` exists in the table — but the shim form
above is the smallest, lowest-risk change and preserves the existing
`command -v _cmd_"$name"` lookup unchanged.

Call sites / things to check together:
- **The dispatcher at the bottom** (`if command -v _cmd_"$name" …`) is unchanged
  if you keep the shims; verify each shimmed name still resolves via `command -v`.
- **`_cmd_apply` calls `_cmd_init`**, **`_cmd_output` calls `_cmd_refresh`**,
  **`_cmd_plan` calls `_cmd_validate`** — those dependency call targets must keep
  the same names whether they remain bespoke or become shims.
- **`_cmd_destroy` deliberately differs** (CMD_ARGS last, two branches): leave it
  bespoke, but note in the table comment that its ordering is intentional so a
  future reader does not "fix" it to match the generic contract — or better,
  bring it into the uniform `<VARFILE> <CMD_ARGS> <args>` order as part of this
  change after confirming no test depends on the current order.
- **bash floor**: namerefs (`declare -n`) and associative arrays both need
  bash ≥ 4.3 / ≥ 4.0 respectively. The script already uses `declare -n`, so the
  floor does not move. Confirm the project's minimum supported bash is ≥ 4.3.

## Risk / impact

Impact today is low and almost entirely on maintainers, not end users: the arg
ordering differences are masked by Terraform's flag-order tolerance, so existing
behavior is unlikely to change. The real cost is future: any modification to the
shared wrapper contract is a ~16-way edit, and the present drift demonstrates
that such edits already fail to stay in sync. Consolidation removes a standing
hazard and makes related fixes (finding 12's empty-array guard, finding 19) a
single-site change. The consolidation itself carries moderate risk — it touches
many command paths at once — so it should land behind the existing behavioral
test suite and be reviewed for the bash version floor.

## Related findings

- [12](12-empty-array-set-u-old-bash.md) — the duplicated `"${arr[@]}"`
  expansions are exactly the empty-array-under-`set -u` pattern; consolidating
  first makes that fix one-site instead of ~16.
- [19](19-tool-cascade-duplicated.md) — closely related cleanup; this should
  likely be bundled into the same PR as finding 19.
- [10](10-aws-bootstrap-double-backend-config.md) — also touches
  `_cmd_aws_bootstrap`, whose `IMPORT_ARGS`/`VARFILE_ARG` ordering is one of the
  drift sites called out here.
