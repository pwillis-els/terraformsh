# Finding 01: _mktemp does not reset OPTIND, so `state rm` writes its state backup to /tmp instead of the module dir

| Field | Value |
|-------|-------|
| Severity | High |
| Category | Correctness bug |
| Affected function(s) | `_mktemp` (called by `_cmd_state` for `state rm`) |
| Empirically verified | Yes (bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_mktemp` runs its own `getopts` loop to parse `-d`, `-p DIR`, and `-t`, but it
never resets `OPTIND` to `1` on entry. `OPTIND` is a single global variable that
bash does **not** auto-reset when a function is entered, and `local` does not
reset it either. The script's main option parser (`while getopts ...`) and prior
`_mktemp` calls both advance `OPTIND`, so when `_mktemp`'s `getopts` runs against
a stale `OPTIND > 1` it starts scanning *past* its own `-p "$TERRAFORM_PWD"`
arguments and never sees them. As a result `_dirprefix` stays empty and the
`-backup=` temp tfstate that `_cmd_state` builds for `state rm` is created in
`$TMPDIR` (`/tmp`) instead of next to the module's state. The backup is then
effectively lost — it is not where the user/automation expects it, and on most
systems `/tmp` is wiped on reboot.

## Affected code

```bash
# _mktemp() — approx lines 774-795 (commit d0a01c3)
# MacOS mktemp sucks and doesn't support -p (nor respects TMPDIR)
_mktemp () {
    local _tmpdir="${TMPDIR:-/tmp}" _makedir=0 _dirprefix=""
    local _cmd="touch" _template="tmp.XXXXXXXXXX" _new _templatetmp
    while getopts "dp:t:" args ; do
        case $args in
            d)  _makedir=1 ;;
            p)  _dirprefix="$OPTARG" ;;
            t)  _makedir=0 ;;
            *)  _errexit "Please pass correct _mktemp options" ;;
        esac
    done
    shift $(($OPTIND-1))
    [ $# -lt 1 ] || _template="$1"
    [ ! "$_makedir" = "1" ] || _cmd="mkdir"
    while : ; do
        _templatetmp="${_template%%XXXXXXXXXX*}$(_rand)${_template##*XXXXXXXXXX}"
        _new="$( printf "%s/%s" "${_dirprefix:-$_tmpdir}" "$_templatetmp" )"
        [ -e "$_new" ] && continue
        "$_cmd" "$_new" 2>&- && break
    done
    printf %s "$_new"
}
```

```bash
# _cmd_state() — approx lines 254-275 (commit d0a01c3) — the only caller of _mktemp
_cmd_state () {
    _final_vars
    [ "${NO_DEP_CMDS:-0}" = "0" ] && _cmd_init 1>&2 # Send all previous command output to STDERR
    declare -a args=()
    local cmd
    # 'terraform state' takes no options, but its commands do, so we play argument musical chairs
    # so that the options come after the sub-command, not after 'terraform state'.
    if [ $# -gt 0 ] ; then
        cmd="$1"; shift
        args+=("$cmd")
    fi
    # add '-backup=' to 'terraform state rm ...' command
    if [ "${cmd:-}" = "rm" ] ; then
        # shellcheck disable=SC2155
        local backupstate="$(_mktemp -p "$TERRAFORM_PWD" "backup.XXXXXXXXXX.tfstate")"
        args+=("-backup=$backupstate")
        [ "${DRYRUN:-0}" = "1" ] && rm -f "$backupstate"
    fi
    args+=("${STATE_ARGS[@]}")
    args+=("$@")
    _runcmd "$TERRAFORM" state "${args[@]}"
}
```

```bash
# main option parser — approx lines 842-861 (commit d0a01c3) — advances OPTIND before any _cmd_* runs
while getopts "f:b:C:c:E:IPDNnhqv" args ; do
    case $args in
        f)  VARFILES+=("$(_readlinkf "$OPTARG")") ;;
        b)  BACKENDVARFILES+=("$(_readlinkf "$OPTARG")") ;;
        ...
    esac
done
shift $(($OPTIND-1))
```

## Why this is a bug

`getopts` uses the shell variable `OPTIND` as its cursor into the argument list.
`OPTIND` is a **single process-global variable**. Bash does not reset it to `1`
when a function is called, and declaring it `local` inside a function does *not*
reset it — `local OPTIND` without an explicit value just makes the current
(inherited) value local and still non-`1`. The POSIX/bash-portable idiom for a
function that calls `getopts` is therefore to explicitly do `local OPTIND=1`
(and usually `local OPTARG`) at the top.

`_mktemp` omits this. Two distinct things leave `OPTIND` greater than `1` before
`_mktemp`'s `getopts` runs:

1. **The main option parser.** `while getopts "f:b:C:..." args; do ...; done`
   advances `OPTIND` once per leading option/argument. After `terraformsh -b
   backend.tfvars state rm ...`, `OPTIND` is `3`. The trailing
   `shift $(($OPTIND-1))` shifts the positional parameters but **does not reset
   `OPTIND`** — that reset only happens for the *next* fresh `getopts` loop that
   bothers to reset it. So `OPTIND` is still `3` when `_cmd_state` later calls
   `_mktemp`.

2. **A previous `_mktemp` call in the same process.** `_mktemp` itself leaves
   `OPTIND` at `3` after parsing `-p DIR`. So even when the *first* call was fine
   (no leading options, `OPTIND` started at `1`), a *second* `state rm` in the
   same `terraformsh` invocation starts at the leaked `OPTIND=3` and breaks.

When `getopts "dp:t:"` runs with `OPTIND=3`, it begins scanning at positional
parameter 3 — i.e. *after* `-p` (param 1) and `$TERRAFORM_PWD` (param 2). It
finds only `backup.XXXXXXXXXX.tfstate` (param 3), which is not an option, so the
loop exits immediately. The `p)` branch never runs, `_dirprefix` stays empty, and
`"${_dirprefix:-$_tmpdir}"` falls back to `$TMPDIR` (`/tmp`). The backup tfstate
is created in `/tmp` instead of `$TERRAFORM_PWD`.

Note `set -e -u -o pipefail` does not catch this: nothing returns non-zero. The
`getopts` loop simply finds no options, which is a perfectly "successful" no-op.
It is a silent misbehavior, not an error.

## How to reproduce / trigger

terraformsh invocation that triggers it on the **first** `state rm` (any leading
option advances `OPTIND` before `_cmd_state` runs):

```sh
terraformsh -b backend.tfvars state rm aws_instance.foo
# EXPECTED: backup written to <module dir>/backup.<rand>.tfstate
# ACTUAL:   backup written to /tmp (or $TMPDIR)/backup.<rand>.tfstate
```

Even with **no** leading options, the *second* `state rm` in one invocation
breaks, because the first `_mktemp` call leaks `OPTIND=3`:

```sh
terraformsh state rm aws_instance.a state rm aws_instance.b
# 1st rm: backup correctly in module dir
# 2nd rm: backup wrongly in /tmp
```

Minimal standalone `bash -c` reproduction of the mechanism (run on bash 5.2.21):

```bash
bash -euo pipefail -c '
  _mktemp () {
      local _dirprefix=""
      while getopts "dp:t:" a; do case $a in p) _dirprefix="$OPTARG";; esac; done
      printf "OPTIND=%s _dirprefix=%q\n" "$OPTIND" "$_dirprefix"
  }
  # Simulate terraformsh main parser: terraformsh -b backend.tfvars state rm ...
  set -- -b backend.tfvars state rm aws_instance.foo
  while getopts "f:b:C:c:E:IPDNnhqv" a; do :; done
  shift $(($OPTIND-1))
  echo "main parser left OPTIND=$OPTIND"
  # _cmd_state now calls:
  _mktemp -p /home/user/module backup.XXXXXXXXXX.tfstate
'
```

Observed output:

```
main parser left OPTIND=3
OPTIND=3 _dirprefix=''
```

`_dirprefix` is empty — the `-p /home/user/module` was skipped, confirming the
backup would land in `$TMPDIR`. I ran this; it reproduces. With `local OPTIND=1`
added to `_mktemp`, the same harness prints `_dirprefix=/home/user/module`.

## Suggested fix

Reset `OPTIND` (and make `OPTARG` local for hygiene) at the very top of
`_mktemp` so its `getopts` always starts fresh, independent of any caller:

```diff
 _mktemp () {
+    local OPTIND=1 OPTARG
     local _tmpdir="${TMPDIR:-/tmp}" _makedir=0 _dirprefix=""
     local _cmd="touch" _template="tmp.XXXXXXXXXX" _new _templatetmp
     while getopts "dp:t:" args ; do
         case $args in
             d)  _makedir=1 ;;
             p)  _dirprefix="$OPTARG" ;;
             t)  _makedir=0 ;;
             *)  _errexit "Please pass correct _mktemp options" ;;
         esac
     done
     shift $(($OPTIND-1))
```

Making `OPTIND` local also means `_mktemp` no longer *leaks* a modified `OPTIND`
back to its callers, which is the second half of the bug.

Call-site check: `_mktemp` has exactly one caller, `_cmd_state` (line 268,
`state rm`). `_cmd_state` does not use `getopts` or `OPTIND` itself, so localizing
`OPTIND` inside `_mktemp` cannot break it. No other function in the script calls
`_mktemp`. The only other `getopts`/`OPTIND` users are the main parser (top
level, runs before any function) and the `local OPTIND` pattern is the standard,
safe idiom there is nothing else to change. Optionally, `args` (the loop var)
could be renamed to avoid colliding with the `declare -a args` arrays used in the
`_cmd_*` functions, but those are in different scopes so it is not required for
correctness.

## Risk / impact

Anyone who runs `terraformsh state rm ...` with any leading option (`-b`, `-f`,
`-C`, etc. — and `-b` is the normal way to select a backend, so this is the
common case), or who runs more than one `state rm` per invocation, gets their
safety backup of the prior state written to `/tmp` instead of beside the module.
The `terraform state rm -backup=` file is the user's escape hatch to recover from
a botched removal. Silently relocating it to `/tmp` means: it is not where the
operator or any automation looks for it; it can be clobbered by other temp files;
and on reboot/`/tmp` cleanup it is gone — so a `state rm` mistake becomes
unrecoverable. The operation still "succeeds," masking the problem. Likelihood is
high for real-world usage and the data-loss consequence is severe, hence High.

## Related findings

[11](11-mktemp-infinite-loop-unwritable-dir.md) — related `getopts`/`OPTIND` / option-parsing issue; if finding 11
is the same `local OPTIND` class of defect, the two should be fixed and reviewed
together in one PR.
