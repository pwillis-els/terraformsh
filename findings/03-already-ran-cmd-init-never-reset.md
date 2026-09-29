# Finding 03: _already_ran_cmd_init is never reset, so an explicit `init` after a dependency init is silently skipped

| Field | Value |
|-------|-------|
| Severity | High |
| Category | Correctness bug |
| Affected function(s) | `_cmd_init` (interacts with `_cmd_clean`, `_cmd_clean_modules`, and the command-dispatch loop) |
| Empirically verified | Yes — mechanism reproduced in isolation on bash 5.2.21 |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_cmd_init` short-circuits whenever the process-global flag `_already_ran_cmd_init`
is `1`. That flag is set the **first** time `init` runs in a given `terraformsh`
invocation — and that first run is very often a *dependency* init triggered by
another command (`apply`, `plan`, `get`, `validate`, etc.). Because the flag is
never reset and the guard cannot tell a dependency init from one the user
explicitly requested, a later **explicit** `init` on the same command line is
silently skipped. Worse, an `init` dependency that fires *after* a `clean`
(which removes `.terraform/terraform.tfstate` and the modules) returns early and
never re-initializes, so the following `apply`/`plan` runs against a directory
whose initialization was just invalidated.

## Affected code

```bash
# _cmd_init() — approx lines 229-235 (commit d0a01c3)
_cmd_init () {
    [ "${_already_ran_cmd_init:-0}" = "1" ] && return 0
    _already_ran_cmd_init=1
    _final_vars
    declare -a args=("$@")
    _runcmd "$TERRAFORM" init "${INIT_ARGS[@]}" "${args[@]}"
}
```

The flag is referenced in exactly two places — the guard and the set — and is
never reset anywhere in the script:

```bash
# grep -n "_already_ran_cmd_init" terraformsh
230:    [ "${_already_ran_cmd_init:-0}" = "1" ] && return 0
231:    _already_ran_cmd_init=1
```

The commands that invalidate the working directory do **not** clear the flag:

```bash
# _cmd_clean_modules() — approx lines 318-320 (commit d0a01c3)
_cmd_clean_modules () {
    _runcmd rm -v -rf .terraform/modules/*
}
# _cmd_clean() — approx lines 321-325 (commit d0a01c3)
_cmd_clean () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_clean_modules
    _runcmd rm -vrf "$TF_PLANFILE" "$TF_DESTROY_PLANFILE" .terraform/terraform.tfstate terraform.tfstate || true
}
```

All commands on one command line run sequentially inside a single process via the
dispatch loop, so `_already_ran_cmd_init` lives for the whole invocation:

```bash
# command-dispatch loop — approx lines 878-887 (commit d0a01c3)
declare -a array
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

`_already_ran_cmd_init` is a plain shell variable in the main shell. Every command
the user lists (`terraformsh CMD1 CMD2 CMD3 ...`) is dispatched in order from the
same loop, in the same process (no subshell), so the variable persists from one
command to the next. The guard `[ "${_already_ran_cmd_init:-0}" = "1" ] && return 0`
was presumably intended only to deduplicate the *dependency* inits that nearly
every `_cmd_*` triggers (`_cmd_apply`, `_cmd_plan`→`_cmd_validate`→`_cmd_get`→
`_cmd_init`, `_cmd_get`, `_cmd_refresh`, `_cmd_state`, etc.), so that a single
`apply` doesn't run `terraform init` twice. But the guard is too broad:

1. It does not distinguish a dependency init from an init the **user explicitly
   typed** on the command line. The dispatch loop calls the user's `init` exactly
   the same way (`_cmd_init "${array[@]:1}"`) that an internal caller does, so once
   the flag is set, the user's explicit `init` becomes a no-op.

2. It is never reset, including by `_cmd_clean` / `_cmd_clean_modules`, which delete
   `.terraform/terraform.tfstate` (the backend state pointer) and
   `.terraform/modules/*`. After those run, the working directory is no longer
   properly initialized, yet the next `init` (whether explicit or a dependency of a
   later command) believes init has "already run" and returns `0` without doing
   anything.

Note this is purely a logic bug; `set -e`/`set -u`/`pipefail` are not involved.
The function returns `0`, so `set -e` is happy, which is exactly why the failure is
*silent* — terraform is simply never invoked, and the command that depended on a
fresh init proceeds against a stale/wiped directory.

## How to reproduce / trigger

Real `terraformsh` command lines that hit this:

- `terraformsh -b backend.tfvars init clean apply`
  Expected: `init` initializes, `clean` wipes state/modules, then `apply`'s
  dependency `init` **re-initializes** before applying.
  Actual: the first (explicit) `init` sets the flag; `clean` wipes
  `.terraform/terraform.tfstate` and `.terraform/modules/*`; `apply` calls
  `_cmd_init`, which sees the flag and returns early — so `terraform apply` runs
  against a directory whose backend state pointer and modules were just removed.

- `terraformsh -b backend.tfvars apply init`
  Expected: `apply` (which inits as a dependency), then a fresh explicit `init`
  (e.g. the user wants to re-`init` with `-reconfigure` afterward).
  Actual: `apply`'s dependency init sets the flag; the trailing explicit `init` is
  skipped entirely.

Minimal standalone reproduction (run on bash 5.2.21), using stubs for the verbatim
init/clean logic and simulating the dispatch loop in one process:

```bash
bash -c '
set -e -u -o pipefail
TF_LOG=$(mktemp)
terraform_stub() { echo "terraform $*" >> "$TF_LOG"; }
_runcmd () { echo "+ $*" 1>&2; "$@"; }

_cmd_init () {                       # verbatim guard logic from terraformsh
    [ "${_already_ran_cmd_init:-0}" = "1" ] && return 0
    _already_ran_cmd_init=1
    _runcmd terraform_stub init
}
_cmd_clean_modules () { _runcmd rm -v -rf .terraform/modules/* ; }
_cmd_clean () {
    _cmd_clean_modules
    _runcmd rm -vrf .terraform/terraform.tfstate terraform.tfstate || true
}
_cmd_apply () { _cmd_init ; _runcmd terraform_stub apply ; }

# dispatch loop equivalent of:  terraformsh init clean apply
_cmd_init       # explicit user init
_cmd_clean      # wipes modules + backend state pointer
_cmd_apply      # dependency init is SKIPPED because flag is still 1

echo "===== terraform calls actually made ====="; cat "$TF_LOG"; rm -f "$TF_LOG"
'
```

Observed output (the dependency init before `apply` is missing):

```
+ terraform_stub init
+ rm -v -rf .terraform/modules/*
+ rm -vrf .terraform/terraform.tfstate terraform.tfstate
+ terraform_stub apply
===== terraform calls actually made =====
terraform init
terraform apply
```

The trailing-explicit-init variant (`apply init`) was reproduced the same way and
likewise produced only `terraform init` + `terraform apply`, dropping the final
init. Both were run with the Bash tool and confirmed.

## Suggested fix

Two independent problems need addressing; do both:

1. **An explicit, user-requested `init` must always run.** Have the dispatch loop
   tag the user's own `init` so `_cmd_init` bypasses the dedup guard, while
   dependency callers (which call `_cmd_init` with no tag) keep their dedup
   behavior.

2. **Reset the flag when the working dir is invalidated.** `_cmd_clean` and
   `_cmd_clean_modules` remove `.terraform/modules/*` and
   `.terraform/terraform.tfstate`, so a subsequent init dependency must run again.

```diff
 _cmd_init () {
-    [ "${_already_ran_cmd_init:-0}" = "1" ] && return 0
+    local _explicit=0
+    if [ "${1:-}" = "--tfsh-explicit-init" ] ; then _explicit=1 ; shift ; fi
+    # Dependency inits are de-duplicated; an explicit user 'init' always runs.
+    [ "$_explicit" = "0" ] && [ "${_already_ran_cmd_init:-0}" = "1" ] && return 0
     _already_ran_cmd_init=1
     _final_vars
     declare -a args=("$@")
     _runcmd "$TERRAFORM" init "${INIT_ARGS[@]}" "${args[@]}"
 }
```

```diff
 _cmd_clean_modules () {
     _runcmd rm -v -rf .terraform/modules/*
+    _already_ran_cmd_init=0   # working dir no longer initialized; allow re-init
 }
 _cmd_clean () {
     _final_vars
     [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_clean_modules
     _runcmd rm -vrf "$TF_PLANFILE" "$TF_DESTROY_PLANFILE" .terraform/terraform.tfstate terraform.tfstate || true
+    _already_ran_cmd_init=0   # backend state pointer removed; force re-init
 }
```

And in the dispatch loop, mark only the user-typed `init` as explicit:

```diff
 for pair in "${CMD_PAIRS[@]}" ; do
     eval "$pair"
     name="${array[0]}" # 'array' is defined in 'eval $pair'
     if command -v _cmd_"$name" >/dev/null ; then
-        _cmd_"$name" "${array[@]:1}"
+        if [ "$name" = "init" ] ; then
+            _cmd_init --tfsh-explicit-init "${array[@]:1}"
+        else
+            _cmd_"$name" "${array[@]:1}"
+        fi
     else
         _cmd_catchall "$name" "${array[@]:1}"
     fi
 done
```

Notes for whoever implements this:

- The sentinel `--tfsh-explicit-init` is consumed in `_cmd_init` before `args` is
  built, so it is never forwarded to `terraform init`. A real user is not going to
  pass an init option named `--tfsh-explicit-init`, so the collision risk is
  negligible; if you prefer zero collision risk, use a dedicated global
  (e.g. set `_explicit_init=1` immediately before the call instead of an argv
  marker).
- Every internal caller of `_cmd_init` (`_cmd_apply`, `_cmd_destroy`,
  `_cmd_refresh`, `_cmd_force-unlock`, `_cmd_0.12upgrade`, `_cmd_0.13upgrade`,
  `_cmd_console`, `_cmd_import`, `_cmd_taint`, `_cmd_untaint`, `_cmd_state`,
  `_cmd_workspace`, `_cmd_show`, `_cmd_get`, `_cmd_aws_bootstrap`, and indirectly
  via `_cmd_validate` → `_cmd_get`) keeps calling `_cmd_init` with no marker, so the
  intra-command dedup behavior is unchanged — a single `apply` still inits only
  once.
- If you instead implement *only* the flag-reset half, the `apply init`
  (trailing-explicit) case is still broken; if you implement *only* the explicit
  marker, the `init clean apply` (dependency-after-clean) case is still broken.
  Both halves are needed. The combined fix was verified in isolation on bash
  5.2.21: `init clean apply` produced `init, init, apply` and `apply init`
  produced `apply, init`.

## Risk / impact

Anyone who chains commands such that an `init` (explicit or dependency) needs to
run after a prior init in the same invocation is affected. The two common shapes:

- `... init clean apply` / `... clean apply` after an earlier init, or any pipeline
  that does `clean` between an init and a later apply/plan: the post-clean
  dependency init is skipped, so terraform runs against a directory whose backend
  state pointer and modules were just deleted. Depending on terraform/OpenTofu
  version this surfaces as an error ("Backend initialization required" /
  "Module not installed") or, in the worst case, an apply against an
  unexpectedly-reconfigured/local backend.
- `... apply init` (trailing re-init, e.g. to re-`init -reconfigure` after an
  apply): the explicit init the user asked for is silently a no-op.

It is silent (the function returns `0`, nothing is logged), so users get no signal
that the init they requested didn't happen. Severity High: a wrapper whose entire
job is to run `init` at the right times can quietly *not* run it, and the blast
radius includes state/backend operations.

## Related findings

None identified yet. If a separate finding covers `_cmd_clean` semantics (e.g. it
only removes `.terraform/terraform.tfstate` rather than the whole `.terraform`
directory), the `_already_ran_cmd_init` reset for `clean`/`clean_modules` could be
bundled into the same PR.
