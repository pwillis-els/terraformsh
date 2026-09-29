# Finding 15: USE_PLANFILE default is read as :-0 in destroy but initialized as :-1 elsewhere

| Field | Value |
|-------|-------|
| Severity | Low |
| Category | Hygiene |
| Affected function(s) | _cmd_destroy, _default_vars (and _cmd_plan, _cmd_apply, _cmd_plan_destroy by comparison) |
| Empirically verified | Reasoned + standalone bash repro (bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

The single concept "should we use a `.plan` file?" is represented by the
variable `USE_PLANFILE`, but the script reads it three different ways. It is
*initialized* with a default of `1` in `_default_vars` (`${USE_PLANFILE:-1}`),
read with a default of `0` in `_cmd_destroy` (`${USE_PLANFILE:-0}`), and read
with **no** inline default at all (bare `$USE_PLANFILE`) in `_cmd_plan`,
`_cmd_apply`, and `_cmd_plan_destroy`. Today this is harmless because
`_default_vars` always runs (and sets the variable) before any `_cmd_*` runs,
so the inline fallbacks never fire. It is nonetheless an inconsistency: the two
fallback values for the same flag disagree with each other, and a future
refactor that left `USE_PLANFILE` unset would make `destroy` silently pick the
"no planfile" path while `plan`/`apply` would instead abort with an `unbound
variable` error under `set -u`.

## Affected code

```bash
# _default_vars() — approx line 533  (the canonical initialization)
    USE_PLANFILE="${USE_PLANFILE:-1}"
```

```bash
# _cmd_destroy() — approx lines 161-171  (reads with :-0 fallback)
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

```bash
# _cmd_plan() — approx line 110  (bare $USE_PLANFILE, NO inline default)
    [ $USE_PLANFILE -eq 1 ] && args+=("-out=$TF_PLANFILE")

# _cmd_apply() — approx line 131  (bare $USE_PLANFILE, NO inline default)
    if [ $USE_PLANFILE -eq 1 ]; then

# _cmd_plan_destroy() — approx line 158  (bare $USE_PLANFILE, NO inline default)
    [ $USE_PLANFILE -eq 1 ] && args+=("-out=$TF_DESTROY_PLANFILE")
```

```bash
# option parsing — approx line 850  (the only other writer of USE_PLANFILE)
        P)  USE_PLANFILE=0 ;;
```

For reference, `_default_vars` is invoked unconditionally at top level
(approx line 840) *before* `getopts` (approx line 842) and before any
`_cmd_*` function is dispatched (approx lines 879-887).

## Why this is a bug

This is a latent-consistency / hygiene problem, not a live functional bug. The
three readers of `USE_PLANFILE` encode three different assumptions about its
unset value:

- `_default_vars` (line 533) assumes the *intended* default is **1** (use a
  planfile). This is the authoritative one and runs first.
- `_cmd_destroy` (line 165) assumes that an unset value should mean **0** (do
  not use a planfile). This directly contradicts the `:-1` default above.
- `_cmd_plan` / `_cmd_apply` / `_cmd_plan_destroy` (lines 110/131/158) assume
  the variable is *always set* and use it bare. Under the script's global
  `set -u`, a bare `$USE_PLANFILE` reference aborts the whole script with
  `USE_PLANFILE: unbound variable` if the variable is unset.

Because `_default_vars` always runs first and always assigns `USE_PLANFILE`
(either via the `${USE_PLANFILE:-1}` default, or to `0` later if `-P` is
passed), the variable is guaranteed to be set by the time any command runs.
The `:-0` in `_cmd_destroy` is therefore effectively dead code today — its
fallback can never be exercised in the normal flow.

The hazard is forward-looking. If a future change ever caused a command to run
with `USE_PLANFILE` unset — for example, `_default_vars` returning early before
line 533 (it has several `return 1` paths around lines 509/518/528/559 during
terraform/tofu auto-detection), or the initialization being moved/guarded — the
behavior would become inconsistent *and asymmetric*:

- `destroy` would silently take the "plain `terraform destroy`, no plan file"
  branch (because `:-0` resolves to `0`), and
- `plan` / `apply` / `plan_destroy` would instead crash with
  `unbound variable`.

So the same unset state produces "silently skip the planfile" in one command
and "hard abort" in others. (In practice, an early `return 1` from
`_default_vars` would itself abort the script under `set -e`, so reaching a
command with the variable unset requires a more invasive refactor — hence
Low severity.)

## How to reproduce / trigger

There is no terraformsh command line that triggers this in the shipped code,
precisely because `_default_vars` always sets the variable first. The
divergence is demonstrable in isolation by simulating an unset `USE_PLANFILE`
and exercising the two read styles. The following was run on bash 5.2.21:

```bash
# Demonstrates the destroy reader (:-0) vs the plan/apply reader (bare $).
# Mirrors lines 165 and 110 with USE_PLANFILE deliberately unset.

# 1) destroy-style read: defaults to 0 -> "no planfile" branch, no error
bash -c '
set -e -u -o pipefail
unset USE_PLANFILE
if [ "${USE_PLANFILE:-0}" = "0" ] ; then
    echo "destroy: unset -> treated as 0 -> plain destroy (no planfile)"
else
    echo "destroy: unset -> treated as 1 -> planfile path"
fi
'
# prints: destroy: unset -> treated as 0 -> plain destroy (no planfile)

# 2) plan/apply-style read: bare $USE_PLANFILE under set -u -> hard abort
bash -c '
set -e -u -o pipefail
unset USE_PLANFILE
[ $USE_PLANFILE -eq 1 ] && echo "plan: planfile" || echo "plan: no planfile"
'
# prints: bash: line 4: USE_PLANFILE: unbound variable   (exit 1)
```

EXPECTED (if the flag were handled consistently): both readers should agree on
the meaning of an unset `USE_PLANFILE`, or — better — the variable should be
guaranteed set in one place and read uniformly everywhere.

ACTUAL: the destroy reader silently defaults to `0` while the plan/apply
readers abort under `set -u`. I ran both snippets above; output matches the
comments.

## Suggested fix

Pick one representation and use it everywhere. Since `_default_vars` already
guarantees `USE_PLANFILE` is set (and is the canonical place for the default),
the cleanest fix is to drop the inline `:-0` fallback in `_cmd_destroy` and
read the variable the same bare way the other commands do. This also makes the
three plan-related commands and destroy behave identically.

```diff
 _cmd_destroy () {
     _final_vars
     [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init
     declare -a args=("$@")
-    if [ "${USE_PLANFILE:-0}" = "0" ] ; then
+    if [ "$USE_PLANFILE" = "0" ] ; then
         _runcmd "$TERRAFORM" destroy "${VARFILE_ARG[@]}" "${args[@]}" "${DESTROY_ARGS[@]}"
     else
         args+=("$TF_DESTROY_PLANFILE") # Pass plan file after '$@'
         _runcmd "$TERRAFORM" apply "${DESTROY_ARGS[@]}" "${args[@]}" && rm -f "$TF_DESTROY_PLANFILE"
     fi
 }
```

Notes on correctness and other call sites:

- `_default_vars` (line 533) keeps the single source of truth:
  `USE_PLANFILE="${USE_PLANFILE:-1}"`. No change needed there.
- `_cmd_plan`, `_cmd_apply`, `_cmd_plan_destroy` already read `$USE_PLANFILE`
  bare and need no change; this edit makes `destroy` consistent with them.
- The `-P` option writer (line 850, `USE_PLANFILE=0`) is unaffected.
- After the change, an unset `USE_PLANFILE` would make *all four* commands fail
  the same way under `set -u`, which is the desired symmetric behavior (a loud
  failure beats a silent divergence).

If a defensive default is preferred instead, normalize it in `_default_vars`
and keep the bare reads — but in either case the value used by `destroy` must
match the value used by `plan`/`apply` (`1`, not `0`), so do **not** simply
change the destroy fallback to `:-1` without also confirming intent; the point
is consistency, and the `:-1` default already lives in `_default_vars`.

## Risk / impact

No end user hits this in the shipped script: `_default_vars` always sets
`USE_PLANFILE` before any command runs, so `destroy` and `plan`/`apply` always
see the same concrete value (`1` by default, or `0` with `-P` / config). The
impact is entirely on future maintainers: the contradictory `:-0` vs `:-1`
defaults are a trap that would surface as a confusing, asymmetric bug (silent
"no planfile" destroy vs `unbound variable` crash on plan/apply) if a refactor
ever let the variable reach a command unset. Consequence if triggered would be
moderate (a `destroy` quietly run without the expected plan file), but the
likelihood is low, hence Low / Hygiene.

## Related findings

None. This is a small, self-contained one-line hygiene fix and can ship in its
own PR or be bundled with other `_default_vars` / flag-consistency cleanups if
any exist.
