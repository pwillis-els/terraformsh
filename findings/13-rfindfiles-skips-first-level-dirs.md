# Finding 13: _rfindfiles never searches direct children of / (root off-by-one)

| Field | Value |
|-------|-------|
| Severity | Low |
| Category | Correctness bug |
| Affected function(s) | `_rfindfiles` (callers: `_load_parent_tffiles`, `_cmd_revgrep`) |
| Empirically verified | Yes — reproduced on GNU bash 5.2.21 |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_rfindfiles` walks the parent-directory chain upward from the current directory
looking for auto-config files to inherit. Its loop guard,
`while [ ! "$(dirname "$cwd")" = "/" ]`, tests the *parent* of `cwd` at the top
of each iteration and exits *before* the body runs whenever that parent is `/`.
The consequence is an off-by-one: the loop never searches any first-level
directory (a direct child of `/`, such as `/tmp`, `/opt`, `/srv`, `/home`).
Auto-config files placed directly in such a directory are therefore never
inherited by runs from deeper subdirectories, and a run started *in* a
first-level directory searches nothing at all. This is a low-severity edge case
(few deployments keep `terraform.sh.tfvars` directly under a top-level dir), but
the behavior is silent and surprising.

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
filenames; these are the auto-config files the bug silently fails to inherit:

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

Caller 2 — `_cmd_revgrep()` (approx lines 337-348), passes **globs**
(`*` and `..?*`) on purpose, and likewise never reaches first-level dirs:

```bash
# _cmd_revgrep() — approx lines 342-346 (commit d0a01c3)
        while read -r LINE ; do
            if [ -e "$LINE" ] ; then
                grep "$@" "$LINE" || true
            fi
        done < <( _rfindfiles "*" "..?*" )
```

## Why this is a bug

The intent of the function is "search `cwd` and every ancestor directory up to
(but not including) `/`". The implementation instead checks the parent of `cwd`
*before* searching `cwd`:

1. The guard `while [ ! "$(dirname "$cwd")" = "/" ]` is evaluated at the top of
   each pass. When `cwd` is a first-level directory (for example `/tmp`),
   `dirname "$cwd"` is `/`, so the test `[ ! "/" = "/" ]` is **false** and the
   loop terminates **without executing the body** for that directory.
2. As a result, the body (the `for f` / `for p` globbing) runs for the starting
   directory and for every ancestor *down to a second-level directory*, but the
   first-level directory itself is skipped. The starting directory `cwd` is
   only reached if it is at least a second-level path.
3. The most extreme case: if `cwd` is *exactly* a first-level directory, the
   loop body never runs at all and `_rfindfiles` returns nothing.

This is purely a loop-bound off-by-one. It is unrelated to `set -e` / `set -u` /
`pipefail`: the function never errors and `cwd` is always assigned, so `set -u`
is satisfied; it simply emits no output for the skipped directory, which makes
the failure silent. (The unquoted `$cwd/$f` expansion visible in the same loop
is a *separate* defect — see Finding 09 — and is orthogonal to this off-by-one.)

The original guard does correctly express one piece of intent: `/` itself should
not be searched (you do not want `revgrep`'s `*` glob to enumerate the entire
root filesystem). The fix must preserve that exclusion while still searching
first-level directories.

## How to reproduce / trigger

Real terraformsh invocation: put an auto-config file directly in a first-level
directory and run terraformsh from a deeper subdirectory.

```bash
mkdir -p /tmp/proj/env
echo 'foo = "bar"' > /tmp/terraform.sh.tfvars   # file in first-level dir /tmp
cd /tmp/proj/env
# put a *.tf here, then:
terraformsh plan
# EXPECTED: /tmp/terraform.sh.tfvars is discovered and passed as -var-file.
# ACTUAL:   it is silently skipped; plan runs without the inherited vars.
```

Minimal standalone repro of the mechanism (run on GNU bash 5.2.21):

```bash
# Mimic the exact loop bound of _rfindfiles and print which dirs it searches.
echo "=== from /tmp/proj/env ==="
cwd="/tmp/proj/env"
while [ ! "$(dirname "$cwd")" = "/" ] ; do
    echo "search dir: $cwd"
    cwd="$(dirname "$cwd")"
done
echo "(loop ended; first-level dir never searched: $cwd)"

echo "=== from /tmp ==="
cwd="/tmp"
while [ ! "$(dirname "$cwd")" = "/" ] ; do
    echo "search dir: $cwd"
    cwd="$(dirname "$cwd")"
done
echo "(loop body never ran; dirname /tmp = $(dirname /tmp))"
```

Observed output:

```
=== from /tmp/proj/env ===
search dir: /tmp/proj/env
search dir: /tmp/proj
(loop ended; first-level dir never searched: /tmp)
=== from /tmp ===
(loop body never ran; dirname /tmp = /)
```

I also ran the **full** function against the real filesystem: with
`/tmp/terraform_repro_marker.tfvars` present and the current directory set to
`/tmp/repro_proj/env`, the unmodified `_rfindfiles "terraform_repro_marker.tfvars"`
returned **nothing**, whereas the fixed version (below) returned
`/tmp/terraform_repro_marker.tfvars`. **The bug reproduces; expected output is
the marker path, actual output is empty.**

## Suggested fix

Restructure the ascent so each directory is searched *before* the guard decides
whether to climb further, and break only after a first-level directory has been
searched — so `/` itself is still excluded. The smallest change that does this is
to convert the `while` into a search-then-test loop:

```diff
 _rfindfiles () {
     cwd="$(pwd)"
-    while [ ! "$(dirname "$cwd")" = "/" ] ; do
+    while : ; do
         for f in "$@" ; do
             for p in $cwd/$f ; do
                 if [ ! -d "$p" ] && [ -e "$p" ] ; then
                     printf "%s\n" "$p"
                 fi
             done
         done
+        # Search cwd first, then stop once we have just searched a
+        # first-level directory (one whose parent is /). This still
+        # excludes / itself from the search.
+        [ "$(dirname "$cwd")" = "/" ] && break
         cwd="$(dirname "$cwd")"
     done
 }
```

Behavior of the fixed loop (verified):

- From `/tmp/proj/env`: searches `/tmp/proj/env`, `/tmp/proj`, then `/tmp`, then
  stops (never searches `/`).
- From `/tmp` (a first-level dir): searches `/tmp`, then stops.
- From `/` itself (degenerate): searches `/` once, then stops. This only happens
  when terraformsh is literally invoked with the working directory at `/`, which
  is not a normal deployment layout; if even this is undesirable, guard the body
  with `[ "$cwd" != "/" ]`.

Other call sites — both checked:

- **`_load_parent_tffiles`** (literal filenames): now correctly inherits
  `terraform.sh.tfvars` / `backend.sh.tfvars` placed in a first-level directory.
  No behavior change for deeper layouts.
- **`_cmd_revgrep`** (`_rfindfiles "*" "..?*"`): the glob now also runs against
  the first-level directory, which is the intended behavior, and `/` is still
  excluded so `revgrep` never enumerates the entire root filesystem. The
  `[ -e "$LINE" ]` re-check in the caller is unaffected.

This fix is independent of Finding 09. If both land together (recommended — see
Related), apply 09's `"$cwd"` quoting on the `for p in "$cwd"/$f` line in the
same edit; the two changes do not conflict.

## Risk / impact

- **Who hits it:** anyone who keeps a `terraform.sh.tfvars` /
  `backend.sh.tfvars` (or `.json` variant) directly inside a first-level
  directory such as `/srv/terraform.sh.tfvars`, `/opt/terraform.sh.tfvars`, or
  who runs terraformsh from within a first-level directory. Most real layouts
  nest config two or more levels deep (`/home/user/proj/...`), so this is an
  uncommon edge case — hence Low severity.
- **How often:** deterministic when it applies; never intermittent.
- **Consequence:** silent — no error is printed. The affected auto-config file
  is simply not inherited, so `plan`/`apply` run without those `-var-file`
  values and, if a first-level `backend.sh.tfvars` is the missing one, `init`
  may fall back to local state. Same class of silent wrong-input behavior as
  Finding 09, but with a much narrower trigger.

## Related findings

- [09](09-rfindfiles-unquoted-glob-wordsplit.md) — the unquoted `$cwd/$f`
  word-splitting bug in the **same** function. (Note: finding 09's "Related"
  section guessed that 13 was another word-splitting issue; it is not — 13 is the
  loop-bound off-by-one described here.) Both are silent auto-config-inheritance
  defects in `_rfindfiles` and should be bundled into a single "`_rfindfiles`
  hardening" PR, fixing the quoting and the off-by-one in one edit.
