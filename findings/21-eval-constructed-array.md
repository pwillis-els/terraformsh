# Finding 21: _process_cmds builds `array=(...)` source strings that are later eval'd to pass arrays

| Field | Value |
|-------|-------|
| Severity | Maintainability |
| Category | Cleanup / simplification |
| Affected function(s) | _process_cmds, main dispatch loop |
| Empirically verified | Reproduced (bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_process_cmds` cannot return an array from a bash function, so instead of using
namerefs or parallel arrays it serializes each parsed command into a literal
chunk of bash *source code* of the form `array=(tok1 tok2 ...)` and stores that
string in the global `CMD_PAIRS`. The main dispatch loop then `eval`s each stored
string to reconstruct the `array` variable before invoking the handler. This is a
working-but-fragile idiom: correctness depends entirely on `printf %q`
round-tripping every token and on the hand-built string opening with `array=(`
and being closed with a matching `)`. It is not, in current form, a security bug
(`%q` quoting holds for the tokens involved), but it is brittle, hard to read, and
trivially replaceable with eval-free array passing.

## Affected code

```bash
# _process_cmds() — approx lines 690-755 (construction of the eval'able strings)
_process_cmds () {
    declare -a cmds=("$@")
    local s=0 p=0 found_cmds=0 cpi=0
    # ... (TFVARS extraction elided) ...
    cpi=${#CMD_PAIRS[@]} # Save this for later, in case this array was already
    p=$cpi               # populated before this function.
    prev='' prevcmd=''
    for cmd in "${cmds[@]:$s}" ; do
        local valid_cmd=0
        for possiblecmd in "${TF_COMMANDS[@]}" "${WRAPPER_COMMANDS[@]}" ; do
            if [ "$possiblecmd" = "$cmd" ] ; then
                if [ "$prev" = "cmd" ] && declare -p "TF_CMDS_$prevcmd" 2>/dev/null 1>&2 ; then
                    declare -n arr="TF_CMDS_$prevcmd"
                    for subcmd in "${arr[@]}" ; do
                        [ "$subcmd" = "$cmd" ] && valid_cmd=2 && break
                    done
                fi
                [ $valid_cmd -eq 2 ] && break
                valid_cmd=1
                [ $found_cmds -gt 0 ] && p=$((p+1))
                break
            fi
        done
        if [ $valid_cmd -eq 0 ] || [ $valid_cmd -eq 2 ] ; then
            if [ $found_cmds -lt 1 ] ; then
                _errexit "Found non-command '$cmd' before a command was found"
            fi
            [ $valid_cmd -eq 0 ] && \
                _stderrlog "Warning: '$cmd' is not a valid command; passing as an option instead"
            [ $valid_cmd -eq 2 ] && \
                _stderrlog "Warning: '$cmd' is a subcommand of previous command '$prevcmd'; passing as an option"
            CMD_PAIRS[$p]+=" $(printf "%q" "$cmd")" # The space before \$( is intentional
            prev="opt"
        else
            _stderrlog "Info: Found $TERRAFORM_SHORT_NAME command '$cmd'"
            CMD_PAIRS[$p]="array=($(printf "%q" "$cmd")" # Yes this has a leading '('
            found_cmds=$((found_cmds+1))
            prev="cmd"
            prevcmd="$cmd"
        fi
    done
    for (( p = cpi; p < ${#CMD_PAIRS[@]}; p++ )) ; do
        CMD_PAIRS[$p]+=")"
    done
    if [ $(( ${#cmds[@]} - $s )) -lt 1 ] ; then
        _log "Error: No COMMAND was specified"; [ $QUIET_MODE -eq 1 ] || echo ""; _usage
    fi
}
```

```bash
# main dispatch loop — approx lines 875-887 (the eval consumer)
_process_cmds "${CMDS[@]}"
_pre_dirchange_vars

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

This is a maintainability / fragility issue, not a correctness or security defect
in the current code. The concerns:

1. **eval of constructed source.** Each `CMD_PAIRS` entry is literal bash code
   (`array=(...)`) that the dispatch loop runs through `eval`. The only thing that
   keeps this safe is that every token is passed through `printf %q`, which emits a
   shell-reusable quoting (either backslash-escaped or `$'...'` ANSI-C form). If a
   future edit ever appends a token to a `CMD_PAIRS` entry *without* `%q`, or
   constructs the surrounding `array=(` / `)` framing incorrectly, the result is
   either a syntax error inside `eval` or execution of attacker-influenced text.
   The safety property lives far away (in the `printf %q` call) from the danger
   (the `eval`), which is exactly the kind of coupling that rots.

2. **Hand-built framing is positional and easy to break.** The opening `array=(`
   is written only on the *command* branch (line 743), the per-option tokens are
   appended with a leading space (line 739), and the closing `)` is added in a
   *separate* second loop (lines 749-751). Three disjoint pieces of code must stay
   in agreement for the string to be valid bash. The inline comments
   (`# Yes this has a leading '('`, `# The space before \$( is intentional`)
   are themselves evidence that the construction is non-obvious.

3. **`set -e` masking.** The whole script runs under `set -e -u -o pipefail`.
   `eval "$pair"` runs the assignment in the current shell; if a malformed `pair`
   produced a parse error, `eval` returns non-zero and `set -e` aborts the loop
   with a bare bash syntax message rather than a useful diagnostic — the user gets
   no indication which command token caused it.

4. **Indirection for no benefit.** The stated reason
   (`since we can't return arrays in Bash`) is real, but bash already offers two
   eval-free idioms for exactly this: namerefs (`declare -n`, which this very
   function *already uses* a few lines up for `TF_CMDS_$prevcmd`), and
   parallel/index arrays. The codebase is therefore inconsistent: it trusts
   namerefs for sub-command lookup but reaches for `eval` of generated source to
   carry the parsed command out of the function.

## How to reproduce / trigger

Any normal invocation exercises this path, e.g.:

```sh
terraformsh -C ./module plan -var=foo=bar
```

produces a `CMD_PAIRS` entry like `array=(plan -var=foo=bar)` which is then
`eval`'d. To see the mechanism (and confirm it currently round-trips safely) in
isolation, the following standalone snippet mirrors the construction and the
`eval` consumer. **I ran this on bash 5.2.21:**

```bash
bash -c '
set -e -u -o pipefail
declare -a CMD_PAIRS=()
p=0
for tok in plan "-var=foo bar" "\$(touch /tmp/PWNED_eval_repro)"; do
    if [ "$tok" = "plan" ]; then
        CMD_PAIRS[$p]="array=($(printf "%q" "$tok")"   # leading (
    else
        CMD_PAIRS[$p]+=" $(printf "%q" "$tok")"
    fi
done
CMD_PAIRS[$p]+=")"
printf "constructed: %s\n" "${CMD_PAIRS[$p]}"
declare -a array
for pair in "${CMD_PAIRS[@]}"; do eval "$pair"; done
i=0; for e in "${array[@]}"; do printf "  [%d]=%q\n" "$i" "$e"; i=$((i+1)); done
[ -e /tmp/PWNED_eval_repro ] && echo INJECTED || echo "no injection (%q held)"
'
```

EXPECTED (and ACTUAL, observed): the tokens round-trip exactly —

```
constructed: array=(plan -var=foo\ bar \$\(touch\ /tmp/PWNED_eval_repro\))
  [0]=plan
  [1]=-var=foo\ bar
  [2]=\$\(touch\ /tmp/PWNED_eval_repro\)
no injection (%q held)
```

So the `$(...)` token is preserved as a literal and **not** executed — confirming
that the current `%q`-based serialization is *correct*. The finding is that the
design is needlessly fragile, not that it is presently exploitable. The danger
surfaces only under future edits that break the `%q`/framing invariant.

## Suggested fix

Stop generating bash source. Carry each parsed command as its own real array and
reference it by name (nameref) — the same primitive `_process_cmds` already uses
internally — so no `eval` is involved. Concretely, replace the string-building in
`CMD_PAIRS` with one indexed array per command plus a list of their names.

```diff
 _process_cmds () {
     declare -a cmds=("$@")
     local s=0 p=0 found_cmds=0 cpi=0
     # ... TFVARS extraction unchanged ...
-    cpi=${#CMD_PAIRS[@]} # Save this for later, in case this array was already
-    p=$cpi               # populated before this function.
+    cpi=${#CMD_GROUPS[@]} # number of command groups already collected
+    p=$cpi
     prev='' prevcmd=''
     for cmd in "${cmds[@]:$s}" ; do
         # ... valid_cmd detection unchanged ...
         if [ $valid_cmd -eq 0 ] || [ $valid_cmd -eq 2 ] ; then
             # ... warnings unchanged ...
-            CMD_PAIRS[$p]+=" $(printf "%q" "$cmd")" # The space before \$( is intentional
+            local _g="${CMD_GROUPS[$p]}"
+            declare -n _gref="$_g"
+            _gref+=("$cmd")
+            unset -n _gref
             prev="opt"
         else
             _stderrlog "Info: Found $TERRAFORM_SHORT_NAME command '$cmd'"
-            CMD_PAIRS[$p]="array=($(printf "%q" "$cmd")" # Yes this has a leading '('
+            [ $found_cmds -gt 0 ] && p=$((p+1))   # (moved out of detection loop)
+            local _g="__cmd_group_$p"
+            declare -g -a "$_g=()"
+            declare -n _gref="$_g"
+            _gref+=("$cmd")
+            unset -n _gref
+            CMD_GROUPS[$p]="$_g"
             found_cmds=$((found_cmds+1))
             prev="cmd"
             prevcmd="$cmd"
         fi
     done
-    for (( p = cpi; p < ${#CMD_PAIRS[@]}; p++ )) ; do
-        CMD_PAIRS[$p]+=")"
-    done
     if [ $(( ${#cmds[@]} - $s )) -lt 1 ] ; then
         _log "Error: No COMMAND was specified"; [ $QUIET_MODE -eq 1 ] || echo ""; _usage
     fi
 }
```

and the dispatch loop becomes eval-free:

```diff
-declare -a array
-for pair in "${CMD_PAIRS[@]}" ; do
-    eval "$pair"
-    name="${array[0]}" # 'array' is defined in 'eval $pair'
-    if command -v _cmd_"$name" >/dev/null ; then
-        _cmd_"$name" "${array[@]:1}"
-    else
-        _cmd_catchall "$name" "${array[@]:1}"
-    fi
-done
+for groupname in "${CMD_GROUPS[@]}" ; do
+    declare -n array="$groupname"
+    name="${array[0]}"
+    if command -v _cmd_"$name" >/dev/null ; then
+        _cmd_"$name" "${array[@]:1}"
+    else
+        _cmd_catchall "$name" "${array[@]:1}"
+    fi
+    unset -n array
+done
```

A simpler variant, if per-command grouping is not actually needed downstream,
is to keep a single flat array and a parallel array of "where each command
starts"; but the nameref-per-group version above preserves the existing
"command + its trailing options" grouping exactly.

Other call sites / things to check together when applying this:

- `CMD_PAIRS` is declared at the top (`declare -a CMDS=() CMD_PAIRS=() CONF_FILE=()`)
  — replace with `declare -a CMD_GROUPS=()`.
- `_process_cmds` is called exactly **once** (`_process_cmds "${CMDS[@]}"`), and
  the dispatch loop is the **only** consumer of `CMD_PAIRS`, so there are no other
  readers to update. I grepped the whole script: `CMD_PAIRS` appears only in the
  declaration, inside `_process_cmds`, and in the dispatch loop.
- Note the `cpi`/append-to-existing logic: `_process_cmds` supports being called
  when `CMD_PAIRS` is *already populated* (`cpi=${#CMD_PAIRS[@]}`). In practice the
  single call site starts from empty, but the rewrite above preserves that
  "append to existing groups" behavior via `cpi=${#CMD_GROUPS[@]}`.
- Minor: move the `[ $found_cmds -gt 0 ] && p=$((p+1))` increment out of the inner
  `possiblecmd` detection loop and into the command branch (as shown) so group
  indexing stays tied to where a new group is actually created. Verify against the
  existing tests that command grouping is unchanged.

## Risk / impact

Today: low. No user reaches a broken path through normal use, because `printf %q`
correctly serializes every token (verified above). The cost is paid by
*maintainers*: the construction is split across three code locations, relies on an
`eval` of generated source, and is annotated with "yes this is intentional"
comments — a classic refactoring hazard. The realistic failure mode is a future
contributor appending a token without `%q`, or altering the open/close framing,
turning a quoting slip into an `eval`-time syntax error or (worst case) execution
of argument-derived text. Removing the `eval` eliminates that entire class of
future regression at zero behavioral cost.

## Related findings

[05](05-process-cmds-subcommand-split.md) — also concerns the command-parsing / dispatch machinery
(`_process_cmds`). Consider bundling this cleanup into the same PR as finding 05,
since both touch `_process_cmds` and the dispatch loop and would otherwise create
overlapping diffs.
