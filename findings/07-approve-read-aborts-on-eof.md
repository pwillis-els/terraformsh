# Finding 07: _cmd_approve aborts before the YES/NO check on non-interactive (EOF) stdin

| Field | Value |
|-------|-------|
| Severity | Medium-Low |
| Category | Correctness bug |
| Affected function(s) | _cmd_approve |
| Empirically verified | Yes (bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_cmd_approve` prompts the user with `read -p ... approve` and then branches on
whether they typed `YES`. The whole script runs under `set -e`. When stdin is
not an interactive terminal (CI, a pipe, or `< /dev/null`), `read` hits EOF and
returns a non-zero status. Under `set -e` that non-zero return aborts the
function immediately, *before* the `if [ "$approve" = "YES" ]` test runs. As a
result the intended `"Approval not given; exiting!"` message never prints — the
script just exits 1 with no explanation. The exit code is "correct" (it does
refuse to proceed), but the operator gets a silent, unexplained failure instead
of the designed error message.

## Affected code

```bash
# _cmd_approve() — approx lines 326-336 (commit d0a01c3)
_cmd_approve () {
    local approve
    [ $QUIET_MODE -eq 1 ] || echo ""
    read -p "$0: Are you SURE you want to continue with the next commands? Type 'YES' to continue: " approve
    if [ "$approve" = "YES" ] ; then
        _log "Approval given; continuing!"
        [ $QUIET_MODE -eq 1 ] || echo ""
    else
        _errexit "Approval not given; exiting!"
    fi
}
```

```bash
# _errexit() — approx line 825 (commit d0a01c3)
_errexit () {  echo "$0: Error: $*" ; exit 1 ;  }
```

```bash
# top-level dispatch loop — approx lines 879-887 (commit d0a01c3)
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

```bash
# global shell options — line 6 (commit d0a01c3)
set -e -u -o pipefail
```

## Why this is a bug

`read` returns a non-zero exit status when it reaches end-of-file before a
delimiter (it returns 1 on EOF). Under `set -e` (errexit), a command that
returns non-zero aborts execution unless it is part of a tested condition (the
condition of `if`/`while`/`until`, an operand of `&&`/`||`, or negated with `!`).

In `_cmd_approve` the `read` statement stands on its own line — it is **not** in
a tested context — so its non-zero EOF return triggers errexit and the function
returns immediately. Control never reaches the `if [ "$approve" = "YES" ]`
block, so:

- `_log "Approval given; continuing!"` is correctly skipped (good), but
- `_errexit "Approval not given; exiting!"` is **also** skipped (bad) — the
  explanatory message is never printed.

Because `_cmd_approve` is invoked directly in the dispatch loop
(`_cmd_"$name" "${array[@]:1}"`, line 883) and not in a tested context, the
errexit abort propagates all the way out and the entire script exits 1 with no
diagnostic output.

`set -u` is incidentally relevant here: when `read` aborts at EOF, the `approve`
variable is left unset/empty. If the `read` were made non-fatal but the variable
left untouched, `[ "$approve" = "YES" ]` would still work because `local approve`
declared it (empty, not unset), so `set -u` does not bite. `pipefail` is not
involved in this path.

This is a real (if minor) correctness bug: the failure mode is "works as
designed but with a worse-than-designed error message". The non-interactive case
is exactly the case where a clear message matters most, because there is no human
at the prompt to see what happened.

## How to reproduce / trigger

Run the `approve` command with a non-interactive stdin:

```sh
terraformsh ... approve < /dev/null
# or in a pipeline / CI runner where stdin is not a TTY:
echo | terraformsh ... approve
```

Expected: the script prints `<script>: Error: Approval not given; exiting!` and
exits 1.
Actual: the script exits 1 silently — no `Approval not given` message.

Minimal standalone reproduction of the mechanism (run on bash 5.2.21 — confirmed):

```bash
bash -c '
set -e -u -o pipefail
_errexit () { echo "Error: $*"; exit 1; }
_cmd_approve () {
    local approve
    read -p "Type YES: " approve
    if [ "$approve" = "YES" ] ; then
        echo "Approval given"
    else
        _errexit "Approval not given; exiting!"
    fi
}
_cmd_approve
echo "after (should not print)"
' < /dev/null
echo "exit code: $?"
```

Observed output: nothing from the function, `exit code: 1`. Neither
`"Approval not given; exiting!"` nor `"after"` is printed — proving the function
aborted at the `read`, before the `if`/`else` branch. (Reproduction run and
verified.)

## Suggested fix

Make the `read` non-fatal so the `if`/`else` branch always runs and the value is
explicitly tested. Two equivalent options:

Option A — defang the `read` with `|| true` (smallest change, keeps the existing
message path intact):

```diff
 _cmd_approve () {
     local approve
     [ $QUIET_MODE -eq 1 ] || echo ""
-    read -p "$0: Are you SURE you want to continue with the next commands? Type 'YES' to continue: " approve
+    read -p "$0: Are you SURE you want to continue with the next commands? Type 'YES' to continue: " approve || true
     if [ "$approve" = "YES" ] ; then
         _log "Approval given; continuing!"
         [ $QUIET_MODE -eq 1 ] || echo ""
     else
         _errexit "Approval not given; exiting!"
     fi
 }
```

On EOF, `approve` is left empty, the `else` branch runs, and the operator now
sees `Approval not given; exiting!` and exits 1 — the designed behavior.

Option B — explicitly detect a non-TTY stdin and give an even clearer message
(distinguishes "no terminal to prompt on" from "user typed something other than
YES"):

```bash
_cmd_approve () {
    local approve=""
    [ $QUIET_MODE -eq 1 ] || echo ""
    if [ ! -t 0 ] ; then
        _errexit "Approval required but stdin is not a terminal; cannot prompt. Exiting!"
    fi
    read -p "$0: Are you SURE you want to continue with the next commands? Type 'YES' to continue: " approve || true
    if [ "$approve" = "YES" ] ; then
        _log "Approval given; continuing!"
        [ $QUIET_MODE -eq 1 ] || echo ""
    else
        _errexit "Approval not given; exiting!"
    fi
}
```

Verified that Option A produces the intended message and exit code under
`set -e -u -o pipefail` with `< /dev/null` (reproduction run: prints
`Error: Approval not given; exiting!`, exit code 1).

Other call sites: `_cmd_approve` is called from exactly one place — the
top-level dispatch loop (line 883, `_cmd_"$name" "${array[@]:1}"`). No other
function invokes it, and the fix only changes behavior on the EOF path (from
"silent exit 1" to "exit 1 with a message"), so no other code path is affected.
`_errexit` already calls `exit 1`, so the exit code is unchanged.

## Risk / impact

Anyone running the `approve` wrapper command non-interactively hits this:
CI/CD pipelines, cron jobs, anything that pipes into terraformsh, or anything
that redirects stdin. The consequence is a silent exit 1 with no message, which
makes the failure hard to diagnose ("why did my pipeline stop here?"). The exit
behavior itself is safe — the script correctly refuses to proceed without
approval — so there is no risk of an unapproved apply running. Impact is limited
to confusing/opaque diagnostics, hence Medium-Low severity. Frequency depends on
how often `approve` is used non-interactively; for purely interactive users this
never triggers.

## Related findings

None. This is a self-contained one-line fix and can ship as its own small PR.
