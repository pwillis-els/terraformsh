# Finding 11: _mktemp can loop forever when the target directory is unwritable (errors hidden by 2>&-)

| Field | Value |
|-------|-------|
| Severity | Low-Medium |
| Category | Correctness bug |
| Affected function(s) | `_mktemp` (triggered via `_cmd_state`) |
| Empirically verified | Yes — reproduced on GNU bash 5.2.21 (exit 124 / timed-out hang) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_mktemp` generates a candidate filename with a homegrown PRNG and tries to
create it in a `while :` loop, breaking only when the `touch`/`mkdir` succeeds.
Any failure of `touch`/`mkdir` is swallowed by `2>&-` (stderr is *closed*, not
just redirected to `/dev/null`), and there is no cap on attempts. If the target
directory (`-p DIR`, defaulting to `$TMPDIR`/`/tmp`) is non-existent or
read-only, every attempt fails silently and the loop spins forever, hanging the
whole program with no diagnostic. The only real call site is `terraformsh state
rm`, which calls `_mktemp -p "$TERRAFORM_PWD" ...` to create a `-backup=` state
file, so this triggers when the directory terraformsh was launched from is not
writable.

## Affected code

```bash
# _rand() — approx lines 768-772 (the PRNG used to build the candidate name)
_random="$(( $(date +%s) + $$ ))" # random seed
_rand () { # Linear congruent generator: cc65
    _random="$(( (16843009*_random + 3014898611) % 4294967296 ))"
    printf "%x" "$_random"
}
```

```bash
# _mktemp() — approx lines 773-795
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
# _cmd_state() — approx lines 254-275 (the single caller; the 'rm' subcommand path)
    # add '-backup=' to 'terraform state rm ...' command
    if [ "${cmd:-}" = "rm" ] ; then
        # shellcheck disable=SC2155
        local backupstate="$(_mktemp -p "$TERRAFORM_PWD" "backup.XXXXXXXXXX.tfstate")"
        args+=("-backup=$backupstate")
        [ "${DRYRUN:-0}" = "1" ] && rm -f "$backupstate"
    fi
```

## Why this is a bug

The loop's only exit is `"$_cmd" "$_new" 2>&- && break`. There are exactly two
ways to leave the loop body without breaking:

* `[ -e "$_new" ] && continue` — the candidate already exists, retry.
* `"$_cmd" "$_new" 2>&-` fails (non-zero) so `&& break` is not taken, and the
  loop iterates again.

When the target directory is **read-only** or **does not exist**, the
`touch`/`mkdir` fails on *every* iteration. Because `_rand` is deterministic and
just keeps producing new names, none of them collide with an existing file, so
`[ -e "$_new" ]` is false and the loop never `continue`s early either — it just
re-attempts the doomed create forever. There is no attempt counter and no
writability pre-check, so the loop is unbounded.

Two things make this worse:

1. **`2>&-` closes stderr for the create command.** This is stronger than
   `2>/dev/null`: the real error (`touch: cannot touch '...': Permission denied`
   / `No such file or directory`) is discarded, so even an interactive user sees
   only a silent hang with zero diagnostics.

2. **`set -e` cannot save you, and neither can the caller in its current form.**
   Note that `set -e` does not break out of the `while :` loop here because each
   failed `"$_cmd"` is in an `&&` short-circuit list (its non-zero status is
   *consumed* by `&&`), which is explicitly exempt from `set -e`. Even if you
   replaced the loop with a fail-and-`_errexit` path, the caller assigns the
   result with `local backupstate="$(_mktemp ...)"`. The `local` builtin's own
   (success) exit status masks the command-substitution's status, so `set -e`
   would *not* abort at the call site even on failure — and `_errexit` runs
   `exit 1` inside the `$(...)` subshell, which only kills that subshell. (I
   verified this masking interaction directly; see the repro below. It is the
   same `local`-masks-`set -e` hazard noted in finding 01.) The upshot: any fix
   must `return` a non-zero status *and* have the caller check it; relying on
   `_errexit`/`set -e` alone is not enough.

The default branch (`${_dirprefix:-$_tmpdir}`, i.e. `$TMPDIR` or `/tmp`) is also
affected if that directory is unwritable, but in practice the only call site
passes `-p "$TERRAFORM_PWD"`.

## How to reproduce / trigger

Real terraformsh trigger — run `state rm` from a directory you cannot write to
(so `TERRAFORM_PWD` is read-only):

```bash
mkdir /tmp/ro-demo && cd /tmp/ro-demo
# ... a terraform config + state would be here ...
chmod 555 /tmp/ro-demo          # make the launch dir read-only
terraformsh state rm aws_instance.foo
# EXPECTED: a clear error like "cannot create backup state file in <dir>"
# ACTUAL  : hangs forever with no output; must be killed (Ctrl-C / SIGKILL)
```

Minimal standalone repro of the loop in isolation (I ran this; `_mktemp` was
copied verbatim from the script and called with a `chmod 000` directory):

```bash
bash -c '
set -e -u -o pipefail
_random="$(( $(date +%s) + $$ ))"
_rand () { _random="$(( (16843009*_random + 3014898611) % 4294967296 ))"; printf "%x" "$_random"; }
_mktemp () {
    local _tmpdir="${TMPDIR:-/tmp}" _makedir=0 _dirprefix=""
    local _cmd="touch" _template="tmp.XXXXXXXXXX" _new _templatetmp
    while getopts "dp:t:" args ; do
        case $args in
            d)  _makedir=1 ;;
            p)  _dirprefix="$OPTARG" ;;
            t)  _makedir=0 ;;
            *)  echo bad; exit 1 ;;
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
d="$(mktemp -d)"; chmod 000 "$d"
rc=0
timeout 5 bash -c "$(declare -f _rand _mktemp); _random=$_random; _mktemp -p \"$d\" backup.XXXXXXXXXX.tfstate" || rc=$?
echo "exit=$rc  (124 == timed out == infinite loop)"
chmod 755 "$d"; rmdir "$d"
'
```

Note the `|| rc=$?`: it is required because the harness runs under `set -e`, so a
bare `timeout ... ; echo "exit=$?"` would abort at the failing `timeout` and
never print the result or run the cleanup. Capturing the status first lets the
script report it.

Observed output (bash 5.2.21): `exit=124` — i.e. the inner `_mktemp` never
returned and `timeout` killed it. The nonexistent-directory variant
(`_mktemp -p /no/such/dir ...`) behaves identically (exit 124). A writable
directory (`-p /tmp`) returns a path immediately, confirming the loop only hangs
on the failure cases.

I also verified the `local`-masking hazard described above: with
`_errexit() { ...; exit 1; }` and `g () { local x="$(f)"; echo REACHED; }`,
`exit 1` inside the `$(...)` does **not** abort the script — `REACHED` prints and
the script exits 0.

## Suggested fix

Pre-check that the target directory exists and is writable, bound the retry loop,
stop hiding stderr, and **return a non-zero status** on failure (do *not* rely on
`_errexit`/`set -e` from inside the command substitution). Then make the single
caller check the result.

```diff
 _mktemp () {
     local _tmpdir="${TMPDIR:-/tmp}" _makedir=0 _dirprefix=""
     local _cmd="touch" _template="tmp.XXXXXXXXXX" _new _templatetmp
+    local _tries=0 _maxtries=100
     while getopts "dp:t:" args ; do
         case $args in
             d)  _makedir=1 ;;
             p)  _dirprefix="$OPTARG" ;;
             t)  _makedir=0 ;;
-            *)  _errexit "Please pass correct _mktemp options" ;;
+            *)  _stderrlog "Error: _mktemp: invalid option" ; return 2 ;;
         esac
     done
     shift $(($OPTIND-1))
     [ $# -lt 1 ] || _template="$1"
     [ ! "$_makedir" = "1" ] || _cmd="mkdir"
+    local _target_dir="${_dirprefix:-$_tmpdir}"
+    if [ ! -d "$_target_dir" ] || [ ! -w "$_target_dir" ] ; then
+        _stderrlog "Error: _mktemp: target directory '$_target_dir' does not exist or is not writable"
+        return 1
+    fi
     while : ; do
+        _tries=$((_tries+1))
+        if [ "$_tries" -gt "$_maxtries" ] ; then
+            _stderrlog "Error: _mktemp: gave up after $_maxtries attempts to create a temp file in '$_target_dir'"
+            return 1
+        fi
         _templatetmp="${_template%%XXXXXXXXXX*}$(_rand)${_template##*XXXXXXXXXX}"
-        _new="$( printf "%s/%s" "${_dirprefix:-$_tmpdir}" "$_templatetmp" )"
+        _new="$( printf "%s/%s" "$_target_dir" "$_templatetmp" )"
         [ -e "$_new" ] && continue
-        "$_cmd" "$_new" 2>&- && break
+        "$_cmd" "$_new" && break
     done
     printf %s "$_new"
 }
```

And the **caller must check the return status** (the one call site, in
`_cmd_state`'s `rm` branch). Note that `local x="$(...)"` masks the failure under
`set -e`, so split the declaration and assignment and test explicitly:

```diff
     if [ "${cmd:-}" = "rm" ] ; then
-        # shellcheck disable=SC2155
-        local backupstate="$(_mktemp -p "$TERRAFORM_PWD" "backup.XXXXXXXXXX.tfstate")"
+        local backupstate
+        if ! backupstate="$(_mktemp -p "$TERRAFORM_PWD" "backup.XXXXXXXXXX.tfstate")" ; then
+            _errexit "could not create backup state file under '$TERRAFORM_PWD' (directory writable?)"
+        fi
         args+=("-backup=$backupstate")
         [ "${DRYRUN:-0}" = "1" ] && rm -f "$backupstate"
     fi
```

Notes for the implementer:

* `_mktemp` has **exactly one** call site (`_cmd_state`, line ~268); the
  `_target_dir`/`_maxtries` changes do not affect any other caller. I verified
  with `grep -n _mktemp`.
* Keeping `_errexit` *inside* `_mktemp` would not work for the option-error case
  either if anyone ever called it via `$(...)` — hence the switch to
  `_stderrlog` + `return`. The `_errexit` in the caller is correct because it
  runs in the main shell, not a subshell.
* I ran the fixed version against (a) a `chmod 000` dir, (b) a nonexistent dir,
  and (c) a writable dir: cases (a) and (b) fail fast with a clear stderr message
  and exit 1 (no hang); case (c) still creates the file and returns 0.
* `-d`/`mkdir` mode behaves the same; the `[ -w "$_target_dir" ]` pre-check
  covers it because `mkdir` of a child also needs the parent writable.

## Risk / impact

Who hits it: anyone running `terraformsh state rm ...` from a directory they
cannot write to (read-only checkout, restrictive CI workspace, a dir owned by
another user, or an NFS/overlay mount that has gone read-only). The default-
`$TMPDIR` path is also vulnerable in principle but is not reached by the current
call site.

Consequence: a complete, silent hang — the process spins on a busy CPU loop with
no output and never terminates, requiring manual kill. In automation/CI this
manifests as a job that runs until its outer timeout, burning compute, with no
log line explaining why. It is a correctness/availability bug rather than a
security or data-loss issue (no bad state is written; it simply never proceeds),
which keeps severity at Low-Medium, but the silent-hang behavior makes it
unusually annoying to diagnose.

## Related findings

* [01](01-mktemp-optind-not-reset.md) — same `local x="$(...)"` masking of command
  substitution exit status under `set -e`; the caller fix here depends on
  understanding it. Consider bundling the `_cmd_state` caller change into the
  same PR as finding 01 if that finding also touches `_cmd_state`; otherwise the
  `_mktemp` change can ship on its own.
