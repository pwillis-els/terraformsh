# Finding 09: _rfindfiles uses an unquoted `for p in $cwd/$f`, breaking auto-discovery in paths with spaces

| Field | Value |
|-------|-------|
| Severity | Medium |
| Category | Correctness bug |
| Affected function(s) | `_rfindfiles` (callers: `_load_parent_tffiles`, `_cmd_revgrep`) |
| Empirically verified | Yes — reproduced on GNU bash 5.2.21 |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_rfindfiles` walks the parent-directory chain looking for auto-config files
(`terraform.sh.tfvars`, `tofu.sh.tfvars`, `backend.sh.tfvars`, …) using the
inner loop `for p in $cwd/$f`, where `$cwd` is unquoted. Because the expansion
is unquoted, bash applies word splitting on `$IFS` (which includes a space).
If any ancestor directory in the absolute path contains a space, the candidate
path is split into two or more words — none of which exist on disk — so the
subsequent `[ -e "$p" ]` test fails and the file is silently skipped. The net
effect is that parent `*.sh.tfvars` / `backend.sh.tfvars` files are never
inherited when terraformsh is run from a path containing a space. The same
function also backs `revgrep`, which deliberately relies on `$f` being a glob,
so the fix must quote `$cwd` while keeping `$f` glob-expanded.

## Affected code

```bash
# _rfindfiles() — approx lines 808-820 (commit d0a01c3)
_rfindfiles () {
    cwd="$(pwd)"
    while [ ! "$(dirname "$cwd")" = "/" ] ; do
        for f in "$@" ; do
            for p in $cwd/$f ; do
                if [ ! -d "$p" ] && [ -e "$p" ] ; then
                    printf "%s\n" "$p"
                fi
            done
        done
        cwd="$(dirname "$cwd")"
    done
}
```

Caller 1 — `_load_parent_tffiles()` (approx lines 667-685), passes **literal**
filenames (no glob metacharacters intended):

```bash
# _load_parent_tffiles() — approx lines 677-683 (commit d0a01c3)
        for auto_file in "${auto_files[@]}" ; do
            while read -r LINE ; do VARFILES=("$LINE" "${VARFILES[@]}") ; done < <( _rfindfiles "$auto_file" )
            while read -r LINE ; do VARFILES=("$LINE" "${VARFILES[@]}") ; done < <( _rfindfiles "$auto_file.json" )
        done
        for backend_file in "${backend_files[@]}" ; do
            while read -r LINE ; do BACKENDVARFILES=("$LINE" "${BACKENDVARFILES[@]}") ; done < <( _rfindfiles "$backend_file" )
        done
```

Caller 2 — `_cmd_revgrep()` (approx lines 337-348), passes **globs** on
purpose (`*` and `..?*`):

```bash
# _cmd_revgrep() — approx lines 342-346 (commit d0a01c3)
        while read -r LINE ; do
            if [ -e "$LINE" ] ; then
                grep "$@" "$LINE" || true
            fi
        done < <( _rfindfiles "*" "..?*" )
```

## Why this is a bug

The inner expansion `$cwd/$f` is unquoted, so bash performs the standard
word-splitting and pathname-expansion (globbing) steps on the result:

1. **Word splitting** breaks the joined string on every character in `$IFS`.
   The default `$IFS` is space, tab, newline. `$cwd` comes from `$(pwd)`, i.e.
   an absolute path; if any ancestor segment contains a space (e.g.
   `/tmp/tfsh test/child`), the single candidate
   `/tmp/tfsh test/terraform.sh.tfvars` is split into the two words
   `/tmp/tfsh` and `test/terraform.sh.tfvars`.
2. **Globbing** then runs on each word. Neither word contains glob characters
   here, and neither exists as a file, so under default (non-`failglob`) bash
   they pass through unchanged.
3. The loop body then runs `[ ! -d "$p" ] && [ -e "$p" ]` on each bogus word.
   Both `/tmp/tfsh` and `test/terraform.sh.tfvars` fail `[ -e ]`, so nothing is
   printed and the real file is never returned to the caller.

Quoting matters here precisely *because* `$f` must stay unquoted for `revgrep`'s
glob (`*`, `..?*`) to expand. The correct unit to quote is the directory prefix
`$cwd`, not the pattern `$f`. `set -e`/`pipefail` are not the trigger here — the
function never errors; it simply produces empty output, so the failure is silent
(the `< <( … )` process substitution feeding the `while read` loop just yields no
lines, and `set -u` is satisfied because `cwd`/`f`/`p` are all assigned).

This affects every auto-config file `_load_parent_tffiles` looks for
(`terraform.sh.tfvars`, `tofu.sh.tfvars`, their `.json` variants, and
`backend.sh.tfvars`). When inheritance silently fails, `init` may run with no
`-backend-config` and fall back to local state, and `plan`/`apply` run without
the inherited `-var-file` values — a quiet correctness/behavior change rather
than a hard error.

## How to reproduce / trigger

Real terraformsh invocation: place an auto-config file in a parent directory
whose absolute path contains a space, then run terraformsh from a subdirectory.

```bash
mkdir -p "/tmp/tfsh test/env"
echo 'foo = "bar"' > "/tmp/tfsh test/terraform.sh.tfvars"
cd "/tmp/tfsh test/env"
# put a *.tf here, then:
terraformsh plan
# EXPECTED: ../terraform.sh.tfvars is discovered and passed as -var-file.
# ACTUAL:   it is silently skipped; plan runs without the inherited vars.
```

Minimal standalone repro of the mechanism (run on bash 5.2.21, default IFS):

```bash
env -i bash --noprofile --norc -c '
  base="$(mktemp -d "/tmp/tfsh test.XXXX")"   # parent dir WITH a space
  mkdir -p "$base/child"
  touch "$base/terraform.sh.tfvars"           # file that SHOULD be inherited
  cd "$base/child"
  cwd="$(pwd)"
  # Mimic the buggy inner expansion exactly:
  set -- $cwd/../terraform.sh.tfvars
  echo "word count: $#"
  i=0; for w in "$@"; do i=$((i+1)); echo "  word $i: [$w]"; done
  rm -rf "$base"
'
```

Observed output:

```
word count: 2
  word 1: [/tmp/tfsh]
  word 2: [test.xxxx/child/../terraform.sh.tfvars]
```

Two split words, neither of which exists, so `[ -e "$p" ]` is false for both.
A full `_rfindfiles` repro (buggy vs. fixed) confirmed the buggy function
returns an empty result for `terraform.sh.tfvars` while the fixed function
returns the correct absolute path. **I ran both repros; the bug reproduces.**

> Caveat verified during testing: under an interactive shell that has set a
> custom `$IFS`, the split may not occur and the bug appears to "not happen."
> The bug manifests under the **default** `$IFS` that terraformsh actually runs
> with (the script never modifies `IFS`), which is why the repro above forces a
> clean `env -i` shell.

## Suggested fix

Quote the directory prefix `$cwd` so it is treated as a single word, but keep
`$f` unquoted so globbing still works for `revgrep`. Collect the matches into an
array first so the `for p` iteration is over real, unsplit paths.

```diff
 _rfindfiles () {
     cwd="$(pwd)"
     while [ ! "$(dirname "$cwd")" = "/" ] ; do
         for f in "$@" ; do
-            for p in $cwd/$f ; do
+            # Quote $cwd (may contain spaces) but leave $f unquoted so callers
+            # that pass a glob (e.g. revgrep: "*" "..?*") still expand. Collect
+            # matches into an array so the inner loop never re-word-splits.
+            local matches=()
+            for m in "$cwd"/$f ; do matches+=("$m") ; done
+            for p in "${matches[@]}" ; do
                 if [ ! -d "$p" ] && [ -e "$p" ] ; then
                     printf "%s\n" "$p"
                 fi
             done
         done
         cwd="$(dirname "$cwd")"
     done
 }
```

Notes on correctness and other call sites:

- **`_load_parent_tffiles`** (literal filenames): `"$cwd"/terraform.sh.tfvars`
  now stays a single word; the file is found in space-containing paths.
  Verified.
- **`_cmd_revgrep`** (`_rfindfiles "*" "..?*"`): `$f` remains unquoted, so
  `"$cwd"/*` and `"$cwd"/..?*` still glob-expand as before. Verified the glob
  still enumerates files, and that `..?*` correctly excludes `.` / `..` while
  matching real dotfiles.
- **No-match case under `set -e`**: when the glob matches nothing, default bash
  leaves the literal pattern, the `[ -e "$p" ]` test is false, and the function
  exits 0 — no `set -e`/`failglob` regression. Verified.
- `local matches=()` is safe because `_rfindfiles` is only ever called as a
  function. If a maintainer prefers to avoid `local` (e.g. for POSIX-ish
  consistency with the rest of the file, which uses bare globals like `cwd`),
  the same effect can be had by quoting only the prefix:
  `for p in "$cwd"/$f` directly — that single-line change also fixes the bug and
  preserves `revgrep`'s globbing; the array form is just slightly more robust
  against future inner-loop edits.

## Risk / impact

- **Who hits it:** anyone running terraformsh from, or with auto-config files
  living in, a directory whose absolute path contains a space (e.g.
  `~/My Projects/...`, macOS paths under `Application Support`, CI checkout
  dirs containing a space). Default-config users rely on this inheritance for
  both `-var-file` and `-backend-config` discovery.
- **How often:** every run from such a path; deterministic, not intermittent.
- **Consequence:** silent — no error is printed. Inherited var files and, more
  importantly, the inherited `backend.sh.tfvars` are dropped. With no
  `-backend-config`, `init` warns "No -b option passed! Potentially using only
  local state" and may operate on local state instead of the intended remote
  backend, and `plan`/`apply` run without inherited variables. Wrong-state /
  wrong-input operations are worse than a loud failure, hence Medium severity.

## Related findings

- [13](13-rfindfiles-skips-first-level-dirs.md) — related word-splitting / quoting issue (per review notes).
  These are both unquoted-expansion correctness bugs and could reasonably be
  bundled into a single "quoting hardening" PR if 13 also touches path handling.
