# Finding 14: _readlinkf leaks globals (t, link, m_s) and clears CDPATH process-wide

| Field | Value |
|-------|-------|
| Severity | Low |
| Category | Hygiene |
| Affected function(s) | _readlinkf |
| Empirically verified | Yes (bash 5.2.21) — but only as a *latent* fragility; not reachable in current code |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_readlinkf` assigns its working variables `m_s`, `t`, `link` and clears `CDPATH`
without any `local` declarations, so all four are plain global assignments. It
also calls `cd` several times, which mutates the shell's working directory.
**However**, every call site in the script invokes the function inside a command
substitution — `$(_readlinkf "$arg")` — which runs it in a subshell. In a
subshell these assignments and the `cd` are discarded when the substitution
finishes, so today nothing actually leaks into the main process. The defect is
therefore a *latent hygiene problem*: the function is only safe by accident of
how it is currently called. The moment someone calls `_readlinkf` directly (not
in `$(...)`), it would silently clobber the caller's `CDPATH`, `t`, `link`,
`m_s` and the process working directory. Severity is Low because there is no
present-day misbehavior.

## Affected code

```bash
# _readlinkf() — approx lines 796-807 (commit d0a01c3)
_readlinkf () {
    [ "${1:-}" ] || return 1; m_s=40; CDPATH=''; t=$1; [ -e "${t%/}" ] || t=${1%"${1##*[!/]}"}
    [ -d "${t:-/}" ] && t="$t/"; cd -P . 2>/dev/null || return 1;
    while [ "$m_s" -ge 0 ] && m_s=$((m_s - 1)); do
      if [ ! "$t" = "${t%/*}" ]; then case $t in
        /*) cd -P "${t%/*}/"  || break ;;
        *) cd -P "./${t%/*}"  || break ;;
        esac; t=${t##*/}; fi
      if [ ! -L "$t" ]; then t="${PWD%/}${t:+/}${t}"; printf '%s\n' "${t:-/}"; return 0; fi
      link=$(ls -dl -- "$t" 2>/dev/null) || break; t=${link#*" $t -> "}
    done; return 1
}
```

All call sites, for reference (every one is a command substitution):

```bash
# _pre_dirchange_vars() — approx lines 607, 612
VARFILE_ARG+=("-var-file" "$(_readlinkf "$arg")")
BACKENDVARFILE_ARG+=("-backend-config" "$(_readlinkf "$arg")")
# _read_config() — approx line 663
. "$(_readlinkf "$conf")"
# parse_aliases / parse loop — approx lines 700, 705
then  BACKENDVARFILES+=("$(_readlinkf "$cmd")")
then  VARFILES+=("$(_readlinkf "$cmd")")
# getopts handler — approx lines 844-845
f)  VARFILES+=("$(_readlinkf "$OPTARG")") ;;
b)  BACKENDVARFILES+=("$(_readlinkf "$OPTARG")") ;;
```

## Why this is a bug

Inside `_readlinkf`:

- `m_s=40`, `t=$1`, and `link=$(...)` are unqualified assignments. Without
  `local`, bash makes/updates **global** variables. Any variable named `t`,
  `link`, or `m_s` in the caller's scope would be overwritten.
- `CDPATH=''` mutates the special shell variable `CDPATH`. `CDPATH` changes how
  `cd` resolves a *relative* directory argument (it is searched as a colon list
  of base directories). Clearing it globally would change `cd` semantics for the
  rest of the process. The function clears it deliberately so that its own
  internal `cd -P "./${t%/*}"` calls are not redirected by an inherited
  `CDPATH` — that intent is correct, but the scope is wrong: it should be local
  to the function.
- The function also runs `cd -P` repeatedly, mutating the shell working
  directory.

None of these are scoped, so in principle they all escape into whatever shell
context runs the function.

**The mitigating fact** (and the correction to the original review note): in the
real script `_readlinkf` is *never* called bare. It is always invoked as
`$(_readlinkf ...)`, i.e. in a command-substitution subshell. Subshells get a
copy of the parent's variables and a copy of `$PWD`; assignments, `CDPATH=''`,
and `cd` performed inside the subshell are thrown away when the substitution
returns. `set -e -u -o pipefail` does not change this — subshell isolation is
independent of those options. So under the current code the leak does **not**
reach the parent process. The original reproduction ("observe CDPATH and t/link
persist afterward") is therefore inaccurate for the shipped code.

What remains is a real but latent hazard: the function relies entirely on being
called in a subshell for its hygiene. The `cd` calls are arguably proof the
author assumed a subshell (a directory-changing helper would otherwise be
unusable), but nothing in the function *enforces* it. A future direct call —
e.g. `_readlinkf "$x"; use_something` — would clobber the caller's `CDPATH`,
`t`, `link`, `m_s`, and working directory with no warning.

## How to reproduce / trigger

No terraformsh command line exposes the leak today, because every invocation is
wrapped in `$(...)`. A normal run such as:

```sh
terraformsh -f vars.tfvars plan
```

calls `_readlinkf` (via the `-f` handler) but, being in a command substitution,
leaves the parent's `CDPATH`/`t`/`link`/`m_s` and `$PWD` untouched.

**Standalone repro — current (subshell) call pattern, showing NO leak.** Ran on
bash 5.2.21:

```bash
bash -c '
set -e -u -o pipefail
_readlinkf () {
    [ "${1:-}" ] || return 1; m_s=40; CDPATH=""; t=$1; [ -e "${t%/}" ] || t=${1%"${1##*[!/]}"}
    [ -d "${t:-/}" ] && t="$t/"; cd -P . 2>/dev/null || return 1;
    while [ "$m_s" -ge 0 ] && m_s=$((m_s - 1)); do
      if [ ! "$t" = "${t%/*}" ]; then case $t in
        /*) cd -P "${t%/*}/"  || break ;;
        *) cd -P "./${t%/*}"  || break ;;
        esac; t=${t##*/}; fi
      if [ ! -L "$t" ]; then t="${PWD%/}${t:+/}${t}"; printf "%s\n" "${t:-/}"; return 0; fi
      link=$(ls -dl -- "$t" 2>/dev/null) || break; t=${link#*" $t -> "}
    done; return 1
}
CDPATH="SENTINEL"; startpwd="$(pwd)"
out="$(_readlinkf /etc/hostname)"              # the real call style
echo "CDPATH=[${CDPATH}]  t=[${t:-<UNSET>}]  m_s=[${m_s:-<UNSET>}]"
echo "pwd unchanged? $([ "$(pwd)" = "$startpwd" ] && echo YES || echo NO)"
'
```

EXPECTED and ACTUAL output (they match — no leak):

```
CDPATH=[SENTINEL]  t=[<UNSET>]  m_s=[<UNSET>]
pwd unchanged? YES
```

**Standalone repro — hypothetical direct call, showing the latent leak.** Same
function, but invoked bare instead of inside `$(...)`. Ran on bash 5.2.21:

```bash
bash -c '
set -e -u -o pipefail
_readlinkf () { ... same body ... }
CDPATH="SENTINEL"; startpwd="$(pwd)"
_readlinkf /etc/hostname >/dev/null            # NOT in command substitution
echo "CDPATH=[${CDPATH}]  t=[${t:-<UNSET>}]  m_s=[${m_s:-<UNSET>}]"
echo "pwd changed? $([ "$(pwd)" = "$startpwd" ] && echo NO || echo YES:$(pwd))"
'
```

ACTUAL output — globals clobbered and the working directory moved:

```
CDPATH=[]  t=[/etc/hostname]  m_s=[39]
pwd changed? YES:/etc
```

This demonstrates the mechanism in isolation: the hygiene defect is real, it is
simply not reachable through any present call site.

## Suggested fix

Declare every working variable `local`, and scope `CDPATH` to the function as
well. Declaring `CDPATH` `local` (with no value, or `local CDPATH=''`) gives it
a function-scoped empty value while the body runs and restores the caller's
`CDPATH` on return — preserving the intended "ignore inherited CDPATH during my
internal cd" behavior without touching global state. This makes the function
correct regardless of whether a future caller wraps it in `$(...)`.

```diff
 _readlinkf () {
-    [ "${1:-}" ] || return 1; m_s=40; CDPATH=''; t=$1; [ -e "${t%/}" ] || t=${1%"${1##*[!/]}"}
+    [ "${1:-}" ] || return 1
+    local m_s=40 t link
+    local CDPATH=''            # function-scoped; restored on return
+    t=$1; [ -e "${t%/}" ] || t=${1%"${1##*[!/]}"}
     [ -d "${t:-/}" ] && t="$t/"; cd -P . 2>/dev/null || return 1;
     while [ "$m_s" -ge 0 ] && m_s=$((m_s - 1)); do
       if [ ! "$t" = "${t%/*}" ]; then case $t in
         /*) cd -P "${t%/*}/"  || break ;;
         *) cd -P "./${t%/*}"  || break ;;
         esac; t=${t##*/}; fi
       if [ ! -L "$t" ]; then t="${PWD%/}${t:+/}${t}"; printf '%s\n' "${t:-/}"; return 0; fi
       link=$(ls -dl -- "$t" 2>/dev/null) || break; t=${link#*" $t -> "}
     done; return 1
 }
```

Notes:

- The `cd` calls still change the directory *within the function*; that is fine
  and intended for path resolution, and remains contained by the subshell at
  every current call site. `local` does not (and cannot) scope `cd` — but
  scoping the variables/`CDPATH` removes the part of the hazard that `local`
  can fix and is the conventional hygiene fix. If full direct-call safety is
  desired, the function could additionally save/restore `$PWD` or be documented
  as "must be called in a subshell".
- **No other call site needs to change.** All seven call sites already use
  `$(_readlinkf ...)`, where the `local` declarations are a strict improvement
  and never alter the printed result. The function's stdout (the resolved path)
  is unchanged.

## Risk / impact

Today: effectively none. Every caller runs `_readlinkf` in a command
substitution, so the missing `local`/`CDPATH` scoping has no observable effect
on the running tool. This is purely a maintainability and robustness concern.

Future: a contributor who calls `_readlinkf` directly — a natural mistake, since
the name reads like a pure path-normalization helper — would silently corrupt
the caller's `CDPATH` (changing `cd` resolution for the rest of the run), stomp
any `t`/`link`/`m_s` variables, and move the process working directory. Such a
bug would be confusing to diagnose. The fix is small, zero-risk for existing
behavior, and forecloses that class of regression.

## Related findings

None. This is a small standalone hygiene fix and can be bundled into any
"variable scoping / `local` hygiene" cleanup PR alongside similar findings if
one exists.
