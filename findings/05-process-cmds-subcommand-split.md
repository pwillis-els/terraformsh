# Finding 05: _process_cmds splits one invocation in two when a token collides with a command name

| Field | Value |
|-------|-------|
| Severity | Medium-High |
| Category | Correctness bug |
| Affected function(s) | `_process_cmds` |
| Empirically verified | Yes — reproduced on bash 5.x with a standalone harness using the verbatim function |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_process_cmds` classifies each command-line token as either a Terraform/wrapper
*command* (which starts a new `terraform` invocation) or an *option* (which is
appended to the preceding command). The classifier has no notion of "this command
expects a positional argument", so any token that happens to equal a top-level
command word (`plan`, `show`, `list`, `validate`, `apply`, …) is treated as a
*new command* — even when it is really the resource address, workspace name, or
output name that the previous command needs. The result is that a single intended
invocation is silently split into two `terraform` runs: the first one missing its
positional argument, and a second spurious run of the collided command word.

This is a real bug. The original note's framing ("only when a token is *non-adjacent*")
is imprecise: the split also happens for the *immediately adjacent* argument when
the parent command has no subcommand list (e.g. `taint validate`, `import <addr>`).
See the Corrections in the structured output.

## Affected code

```bash
# _process_cmds() — approx lines 690-755 (commit d0a01c3)
# (the classification loop; the TFVARS-extraction prologue above it is elided)
_process_cmds () {
    declare -a cmds=("$@")
    local s=0 p=0 found_cmds=0 cpi=0
    # ... TFVARS extraction loop sets $s ...
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

The relevant command/subcommand tables (approx lines 95-101):

```bash
declare -a TF_COMMANDS=(0.12checklist 0.12upgrade 0.13upgrade apply console debug destroy env fmt force-unlock get graph import init login logout output plan providers push refresh show state taint test untaint validate version workspace)
declare -a TF_CMDS_debug=(json2dot)
declare -a TF_CMDS_env=(delete list new select)
declare -a TF_CMDS_providers=(lock mirror schema)
declare -a TF_CMDS_state=(list mv pull push replace-provider rm show)
declare -a TF_CMDS_workspace=(delete list new select show)
declare -a WRAPPER_COMMANDS=(plan_destroy shell clean clean_modules approve aws_bootstrap revgrep)
```

The consumer of `CMD_PAIRS` (approx lines 879-887) runs each pair as a separate
`terraform` invocation:

```bash
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

The classifier decides "command vs. option" purely by string-matching each token
against `TF_COMMANDS` + `WRAPPER_COMMANDS`. There is no per-command knowledge that
a command consumes a *positional argument* (a resource address, a workspace name,
an output name). So a positional argument that happens to spell a command word is
reclassified as a brand-new command. Two distinct failure paths produce the split:

1. **Parent command has NO subcommand list (`taint`, `untaint`, `import`,
   `output`, `show`, `console`, `force-unlock`, …).** The `valid_cmd=2`
   subcommand-detection branch is gated on `declare -p "TF_CMDS_$prevcmd"`
   succeeding. For these commands no `TF_CMDS_*` array exists, so the branch is
   skipped entirely and the *immediately adjacent* argument that equals a command
   word (e.g. `validate` after `taint`) is classified `valid_cmd=1` → a new
   command. `[ $found_cmds -gt 0 ] && p=$((p+1))` then advances `p`, starting a
   fresh `CMD_PAIRS` entry. The original note's "non-adjacent only" claim is wrong
   here.

2. **Parent command HAS a subcommand list (`state`, `workspace`, `env`,
   `providers`, `debug`).** The subcommand check that yields `valid_cmd=2` only
   fires when `prev == "cmd"`, i.e. for the token *immediately* after the parent.
   Once the subcommand has been consumed, `prev` becomes `"opt"`, so the very next
   token — the positional name the subcommand needs — is matched only against the
   top-level command list. If that name equals a command word it gets
   `valid_cmd=1` → new command. This is the literal reproduction from the note:
   `workspace select plan` (a workspace named `plan`) becomes
   `terraform workspace select` (no name) **plus** `terraform plan`.

   A subtle extra wrinkle: subcommand words that are *not* themselves top-level
   commands — `select`, `rm`, `new`, `delete`, `mv`, `list`, `lock`, `mirror`,
   `schema`, `pull`, `replace-provider`, `json2dot` — never even reach the
   `valid_cmd=2` branch, because the outer `for possiblecmd in TF_COMMANDS …` loop
   never matches them. They fall through as plain `valid_cmd=0` options. Only the
   two words that appear in *both* lists (`show` and `push`) ever produce the
   `valid_cmd=2` "subcommand of previous command" warning. (Note: `list` is a
   subcommand of `state`/`workspace`/`env` but is NOT a top-level `TF_COMMANDS`
   entry, so `state list` / `workspace list` never trip the `valid_cmd=2` path.)
   This does not change the outcome of the bug but matters for the fix (see below).

Because `CMD_PAIRS` is later iterated and each entry is run as an independent
`terraform` command, the consequence is not a parse error — it is two real,
silent, *wrong* Terraform executions. Under `set -e`, if the first truncated
command exits non-zero the loop aborts; but for read-only commands (`state rm`
in `-N` dry-run, `workspace select`, `output`) the truncated command can succeed
or do the wrong thing, and the second spurious command then runs too.

`set -u` / `pipefail` are not implicated here; the defect is logical classification,
not unset-variable or pipeline exit-status handling.

## How to reproduce / trigger

Real `terraformsh` command lines that misbehave (each intends ONE Terraform run):

```
terraformsh workspace select plan      # intends: select workspace literally named 'plan'
terraformsh taint validate             # intends: taint a resource addressed 'validate'
terraformsh import aws_instance.x plan  # intends: import, then collides on 'plan'
terraformsh output show                # intends: read output literally named 'show'
terraformsh state rm aws_instance.x show
```

I extracted the **verbatim** `_process_cmds` (and the command tables) into a
standalone harness and ran it on bash 5.x. Observed ACTUAL behavior:

```
===== workspace select plan =====
  => terraform workspace select       # <-- missing the workspace name 'plan'
  => terraform plan                   # <-- spurious second run

===== taint validate =====
  => terraform taint                  # <-- missing the resource address 'validate'
  => terraform validate               # <-- spurious second run

===== import aws_instance.foo show =====
  => terraform import aws_instance.foo
  => terraform show                   # <-- spurious second run

===== output show =====
  => terraform output                 # <-- missing the output name 'show'
  => terraform show                   # <-- spurious second run

===== state rm aws_instance.foo show =====
  => terraform state rm aws_instance.foo
  => terraform show                   # <-- spurious second run
```

EXPECTED behavior: each of these should produce a SINGLE pair, e.g.
`terraform workspace select plan`, `terraform taint validate`,
`terraform output show`.

Minimal standalone `bash -c` style harness (the exact script I ran; it sources the
verbatim function — trimmed here for length, full version saved while testing):

```bash
#!/usr/bin/env bash
set -e -u -o pipefail
declare -a TF_COMMANDS=(... show state taint ... validate version workspace)   # verbatim
declare -a TF_CMDS_state=(list mv pull push replace-provider rm show)
declare -a TF_CMDS_workspace=(delete list new select show)
declare -a WRAPPER_COMMANDS=(plan_destroy shell clean clean_modules approve aws_bootstrap revgrep)
declare -a CMD_PAIRS=() BACKENDVARFILES=() VARFILES=()
QUIET_MODE=0; TERRAFORM_SHORT_NAME=terraform
_stderrlog(){ printf '%s\n' "$*" >&2; }; _errexit(){ echo "Error: $*"; exit 1; }
_log(){ printf '%s\n' "$*"; }; _usage(){ exit 1; }; _readlinkf(){ printf %s "$1"; }
_process_cmds () { :;}   # <-- paste verbatim body from the script here

declare -a array
_process_cmds workspace select plan
for pair in "${CMD_PAIRS[@]}"; do eval "$pair"
  printf 'terraform'; for a in "${array[@]}"; do printf ' %q' "$a"; done; echo; done
# prints two lines: "terraform workspace select" and "terraform plan"
```

## Suggested fix

Give the classifier a per-command notion of "expects a positional argument" and
suppress command-splitting for the token that fills that position. The minimal,
backward-compatible change:

1. Add a table of commands that take a trailing positional (resource address /
   name). For commands **with** a subcommand list, the positional comes after the
   subcommand; for commands **without** one, it comes immediately after the command.
2. Carry an `expect_arg` / `takes_positional` flag through the loop. When set, the
   next token is appended as a literal option regardless of whether it matches a
   command word.

```diff
@@ _process_cmds ()
     cpi=${#CMD_PAIRS[@]}
     p=$cpi
-    prev='' prevcmd=''
+    prev='' prevcmd='' expect_arg=0 takes_positional=0
     for cmd in "${cmds[@]:$s}" ; do
         local valid_cmd=0
+        # The previous command (or its subcommand) wants a literal positional
+        # argument next: take this token as that argument, never a new command.
+        if [ "$expect_arg" = "1" ] ; then
+            CMD_PAIRS[$p]+=" $(printf "%q" "$cmd")"
+            prev="opt" ; expect_arg=0
+            continue
+        fi
         for possiblecmd in "${TF_COMMANDS[@]}" "${WRAPPER_COMMANDS[@]}" ; do
@@
         if [ $valid_cmd -eq 0 ] || [ $valid_cmd -eq 2 ] ; then
@@
             CMD_PAIRS[$p]+=" $(printf "%q" "$cmd")" # The space before \$( is intentional
+            # If the parent command takes a positional and this token is the
+            # first option after it (its subcommand), the NEXT token is a literal
+            # name (workspace select <name>, state rm <addr>, ...).
+            [ "$prev" = "cmd" ] && [ "$takes_positional" = "1" ] && expect_arg=1
             prev="opt"
         else
             _stderrlog "Info: Found $TERRAFORM_SHORT_NAME command '$cmd'"
             CMD_PAIRS[$p]="array=($(printf "%q" "$cmd")" # Yes this has a leading '('
             found_cmds=$((found_cmds+1))
             prev="cmd"
             prevcmd="$cmd"
+            takes_positional=0
+            if _in_array "$cmd" "${TF_CMDS_WITH_POSITIONAL[@]}" ; then
+                takes_positional=1
+                # Commands with NO subcommand list take the positional directly
+                # (taint <addr>, import <addr>, output <name>): next token is literal.
+                declare -p "TF_CMDS_$cmd" 2>/dev/null 1>&2 || expect_arg=1
+            fi
         fi
     done
```

Supporting additions near the command tables (approx line 101) and a small helper:

```bash
# Commands that take a trailing positional name/address. For ones with a
# subcommand list the positional follows the subcommand; for the rest it
# follows the command directly.
declare -a TF_CMDS_WITH_POSITIONAL=(taint untaint import workspace state output console force-unlock show)

_in_array () { local needle="$1"; shift; local x; for x in "$@"; do [ "$x" = "$needle" ] && return 0; done; return 1; }
```

I implemented exactly this against the verbatim function and re-ran the harness.
Results:

```
workspace select plan       => terraform workspace select plan        (1 pair, FIXED)
taint validate              => terraform taint validate                (1 pair, FIXED)
output show                 => terraform output show                   (1 pair, FIXED)
state rm aws_instance.x show => terraform state rm aws_instance.x ; terraform show
import aws_instance.x show   => terraform import aws_instance.x ; terraform show
# chaining still works:
plan apply                  => terraform plan ; terraform apply
init plan apply             => terraform init ; terraform plan ; terraform apply
get validate plan apply     => 4 separate runs (unchanged)
workspace select myws       => terraform workspace select myws (unchanged)
state list / workspace list => single pair (unchanged)
```

**Known limitation / honest caveat:** this consumes exactly ONE positional. A
*trailing* command-word AFTER the positional still splits (`state rm <addr> show`
→ the trailing `show` becomes a second run; `workspace new dev plan` → trailing
`plan` splits). That is arguably correct, because terraformsh deliberately
supports command chaining (`terraformsh plan apply`), so a bare command word after
the positional is genuinely ambiguous. The cases in the reproduction that have no
trailing command word are fully fixed. A truly unambiguous fix would require either
per-command argument arity or an explicit end-of-options separator (e.g. allow
`terraformsh workspace select -- plan`); that is a larger design change and should
be discussed in the PR.

**Other call sites to check:** `_process_cmds` is called exactly once (approx line
875, `_process_cmds "${CMDS[@]}"`). It mutates the globals `CMD_PAIRS`,
`VARFILES`, `BACKENDVARFILES` and reads `TF_COMMANDS`, `WRAPPER_COMMANDS`, the
`TF_CMDS_*` arrays. The new `TF_CMDS_WITH_POSITIONAL` array and `_in_array` helper
must be declared before `_process_cmds` runs (alongside the other command tables
at the top of the file) so they exist under `set -u`. No `_cmd_*` consumer needs
changes — the pairs they receive are simply more correct.

## Risk / impact

Anyone who passes a resource address, workspace name, or output name that collides
with a Terraform/wrapper command word hits this — and many real names do
(`plan`, `show`, `validate`, `state`, `output`, `apply`, `import`, `test`, `env`,
`get`, …). Concretely:

- `terraformsh workspace select plan` selects nothing useful and then runs a full
  `terraform plan` against whatever workspace is currently active — potentially the
  wrong environment.
- `terraformsh taint validate` taints nothing (missing address) and runs
  `terraform validate`; the intended taint silently never happens.
- `terraformsh state rm <addr> show` removes from state correctly but then runs an
  extra `terraform show`.

The danger is that it is **silent and produces a successful-looking exit** for the
read-mostly cases, so an operator believes they selected workspace `plan` or
tainted `validate` when they did not. For `apply`/`destroy`-class collisions the
spurious second command can perform real infrastructure changes against the wrong
target. Medium-High: not universal, but easy to trip, hard to notice, and the
blast radius includes wrong-environment applies.

## Related findings

- [21](21-eval-constructed-array.md) — related parsing/classification issue in `_process_cmds`
  (same function). Strongly consider bundling both into one PR that reworks the
  command/option classifier, since they touch the same loop and overlapping state
  (`prev`, `prevcmd`, the `TF_CMDS_*` handling).
