# Finding 19: The both/terraform/tofu selection cascade is open-coded four times

| Field | Value |
|-------|-------|
| Severity | Maintainability |
| Category | Cleanup / reuse |
| Affected function(s) | _default_vars |
| Empirically verified | Yes (divergence reproduced on bash 5.2.21) |
| Status | Open — not yet fixed |
| Reference commit | d0a01c3 |

> Note: line numbers in this document refer to commit d0a01c3. Fixes will
> land as separate PRs, so line numbers WILL drift. Always locate the code by
> **function name** and the quoted snippets below, not by line number.

## Summary

`_default_vars` contains four separate `if/elif` blocks that all branch on the
same `$TERRAFORM_TOOLS_EXIST` value (`both` / `terraform` / `tofu` / `none`).
Two of those blocks — the ones that build `TF_AUTO_CONFIG_FILES` and
`DEFAULT_CONF_FILES` — share an identical structure ("if both, pick a single
short-name file; otherwise list both variants in some order"), but their
single-tool arms already disagree with each other — and they do so
systematically: `TF_AUTO_CONFIG_FILES` lists the *active* tool's variant first
(e.g. on a terraform-only install: `terraform.sh.tfvars`, then `tofu.sh.tfvars`),
while `DEFAULT_CONF_FILES` lists the *other* tool's variant first (on the same
install: `tofush.conf`, then `terraformsh.conf`). The same active-first
vs other-first split is present in the tofu-only arms too, so it is not a single
stray typo. Because the logic is copy-pasted rather than factored into one helper,
this kind of drift is easy to introduce and easy to miss. This is a
maintainability/consistency issue, not a crash; one of the two ordering
conventions is almost certainly an unintended copy artifact.

## Affected code

```bash
# _default_vars() — tool detection — approx lines 480-490
    TERRAFORM_TOOLS_EXIST="none"
    local has_terraform=0 has_tofu=0
    command -v terraform >/dev/null 2>&1 && has_terraform=1
    command -v tofu >/dev/null 2>&1 && has_tofu=1
    if [ $has_terraform -eq 1 ] && [ $has_tofu -eq 1 ] ; then
        TERRAFORM_TOOLS_EXIST="both"
    elif [ $has_terraform -eq 1 ] ; then
        TERRAFORM_TOOLS_EXIST="terraform"
    elif [ $has_tofu -eq 1 ] ; then
        TERRAFORM_TOOLS_EXIST="tofu"
    fi
```

```bash
# _default_vars() — TERRAFORM binary selection — approx lines 496-519
        if [ "$TERRAFORM_TOOLS_EXIST" = "both" ] ; then
            case "$SCRIPT_NAME" in
                terraformsh)
                    TERRAFORM="terraform"
                    ;;
                tofush)
                    TERRAFORM="tofu"
                    ;;
                *)
                    _stderrlog "Error: When both terraform and tofu are installed, invoke as terraformsh or tofush (e.g., via symlink)."
                    _stderrlog "Error: Current name: '$SCRIPT_NAME'. Example: ln -s terraformsh tofush"
                    _stderrlog "Error: Or set TERRAFORM=terraform or TERRAFORM=tofu to explicitly choose a tool."
                    return 1
                    ;;
            esac
        elif [ "$TERRAFORM_TOOLS_EXIST" = "terraform" ] ; then
            TERRAFORM="terraform"
        elif [ "$TERRAFORM_TOOLS_EXIST" = "tofu" ] ; then
            TERRAFORM="tofu"
        else
            _stderrlog "Error: 'TERRAFORM' environment variable is not set, and neither terraform nor tofu was found in PATH."
            return 1
        fi
```

```bash
# _default_vars() — TF_AUTO_CONFIG_FILES — approx lines 567-584
    TF_AUTO_CONFIG_FILES=()
    if [ $tf_auto_config_default -eq 1 ] ; then
        if [ "$TERRAFORM_TOOLS_EXIST" = "both" ] ; then
            if [ "$TERRAFORM_SHORT_NAME" = "tofu" ] ; then
                TF_AUTO_CONFIG_FILES=("tofu.sh.tfvars")
            else
                TF_AUTO_CONFIG_FILES=("terraform.sh.tfvars")
            fi
        elif [ "$TERRAFORM_TOOLS_EXIST" = "terraform" ] ; then
            TF_AUTO_CONFIG_FILES=("terraform.sh.tfvars" "tofu.sh.tfvars")
        elif [ "$TERRAFORM_TOOLS_EXIST" = "tofu" ] ; then
            TF_AUTO_CONFIG_FILES=("tofu.sh.tfvars" "terraform.sh.tfvars")
        else
            TF_AUTO_CONFIG_FILES=("terraform.sh.tfvars")
        fi
    else
        TF_AUTO_CONFIG_FILES=("$TF_AUTO_CONFIG_FILE")
    fi
```

```bash
# _default_vars() — DEFAULT_CONF_FILES — approx lines 587-600
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

## Why this is a bug

This is a maintainability defect (DRY violation) with a concrete, already-present
consistency bug as evidence:

1. **The two file-list cascades share an identical shape but disagree in their
   single-tool arms — systematically, for BOTH single-tool states.** Both
   `TF_AUTO_CONFIG_FILES` and `DEFAULT_CONF_FILES` implement "if `both`, emit one
   short-name file; if a single tool, emit both variants in some order; if
   `none`, emit just the terraform variant." But the two cascades order the
   single-tool pair by *opposite* rules:

   | `TERRAFORM_TOOLS_EXIST` | `TF_AUTO_CONFIG_FILES` (line 576/578) | first entry | `DEFAULT_CONF_FILES` (line 595/597) | first entry |
   |---|---|---|---|---|
   | `terraform` | `("terraform.sh.tfvars" "tofu.sh.tfvars")` | **active** (terraform) | `("./tofush.conf" "./terraformsh.conf")` | **other** (tofu) |
   | `tofu` | `("tofu.sh.tfvars" "terraform.sh.tfvars")` | **active** (tofu) | `("./terraformsh.conf" "./tofush.conf")` | **other** (terraform) |

   In other words `TF_AUTO_CONFIG_FILES` consistently lists the *active* tool's
   variant first, while `DEFAULT_CONF_FILES` consistently lists the *other*
   tool's variant first. The divergence is not a one-off typo in the
   terraform-only arm — it is a systematic difference in the ordering convention
   between the two cascades, and it shows up identically in both the
   terraform-only and tofu-only branches.

   Ordering is *not* cosmetic here:
   - `_load_conf` sources `DEFAULT_CONF_FILES` in array order with `.` (`source`),
     so **later files override earlier ones** — list order decides which
     `*.conf` wins.
   - `_load_parent_tffiles` iterates `TF_AUTO_CONFIG_FILES` and prepends each
     discovered file to `VARFILES`, so order affects var-file precedence too.

   So on a single-tool host the two cascades feed their consumers opposite
   orderings of the same tool pair: `_load_conf` sees the active tool's `*.conf`
   last (so it wins on conflicts via last-wins sourcing), whereas
   `_load_parent_tffiles` walks `TF_AUTO_CONFIG_FILES` with the active tool's
   var-file first. Whatever the intended convention is, only one of these two
   arrangements can match it. This would not be caught by tests unless someone
   exercised a single-tool host with both `terraformsh.conf` and `tofush.conf` (or
   both `*.sh.tfvars` variants) present and with conflicting settings.

2. **The cost of the duplication is exactly this kind of drift.** Four blocks
   keyed off the same variable must be kept mutually consistent by hand. A fix
   applied to one (say, changing the preferred ordering or adding a new state)
   can silently miss the others.

No `set -e` / `set -u` / `pipefail` interaction is involved — all four blocks use
plain array assignments and guarded `[ ... ]` tests, so nothing here aborts the
script. The "bug" is structural duplication plus the divergent ordering it
already produced.

### Correction to the original review note

The original note said the cascade is "written out four separate times … with
subtly different else-arms." That overstates the structural match:

- The **tool-detection** block (`has_terraform`/`has_tofu` → `TERRAFORM_TOOLS_EXIST`)
  is not the same pattern at all — it *produces* the state variable and has no
  "both → prefer short name" arm.
- The **TERRAFORM binary selection** block branches on `$SCRIPT_NAME` (via a
  `case`) for the `both` arm, not on `$TERRAFORM_SHORT_NAME`, and its non-both
  arms are trivial single assignments / errors, not ordered pairs.

Only **two** of the four blocks (`TF_AUTO_CONFIG_FILES` and `DEFAULT_CONF_FILES`)
genuinely share the "both → single short-name; single tool → ordered pair;
none → terraform-only" structure, and those two are where the else-arms actually
diverge. The other two are related-but-different `$TERRAFORM_TOOLS_EXIST`
dispatches. The headline ("the selection cascade is open-coded four times")
remains a fair description of the smell, but the precise, fixable duplication is
the two file-list cascades.

## How to reproduce / trigger

Trigger condition (real terraformsh): a host where **only terraform** is
installed (`TERRAFORM_TOOLS_EXIST="terraform"`), running terraformsh with default
config (no `-c`), with both `./terraformsh.conf` and `./tofush.conf` present in
the working directory. `_load_conf` will source `./tofush.conf` first and then
`./terraformsh.conf`, so terraformsh.conf wins on conflicts — the opposite
precedence from what the analogous `TF_AUTO_CONFIG_FILES` arm implies for the
same single-terraform host.

Minimal standalone repro of the divergence (run on bash 5.2.21):

```bash
bash -c '
set -e -u -o pipefail
# The two "terraform-only" else-arms, copied verbatim from the script.

# TF_AUTO_CONFIG_FILES, terraform-only (approx line 576)
auto=("terraform.sh.tfvars" "tofu.sh.tfvars")   # active tool (terraform) FIRST

# DEFAULT_CONF_FILES, terraform-only (approx line 595)
conf=("./tofush.conf" "./terraformsh.conf")     # other tool (tofu) FIRST

echo "auto-config terraform-only, first entry: ${auto[0]}"
echo "conf-files  terraform-only, first entry: ${conf[0]}"
'
```

EXPECTED (if both cascades were derived from one helper): both should put the
active tool's variant first, i.e. `terraform.sh.tfvars` and `./terraformsh.conf`.

ACTUAL (observed, ran it): the two arms order the pair oppositely —

```
auto-config terraform-only, first entry: terraform.sh.tfvars
conf-files  terraform-only, first entry: ./tofush.conf
```

The same opposite-ordering split is present in the **tofu-only** arms too:
`TF_AUTO_CONFIG_FILES` tofu-only is `("tofu.sh.tfvars" "terraform.sh.tfvars")`
(active tool first) while `DEFAULT_CONF_FILES` tofu-only is
`("./terraformsh.conf" "./tofush.conf")` (other tool first). So the divergence is
between the two cascades as a whole (active-first vs other-first), not a single
stray arm.

A helper-based version (also run) reproduces `TF_AUTO_CONFIG_FILES` exactly. If
that same helper is used to drive `DEFAULT_CONF_FILES`, it standardizes both
single-tool arms onto the active-tool-first convention, which **changes** the
existing `DEFAULT_CONF_FILES` ordering for *both* the terraform-only and
tofu-only states (see the behavior-change note under Suggested fix).

## Suggested fix

Extract a single helper that, given the two tool-specific tokens and the current
state, emits the ordered list, then call it from both file-list cascades. To stay
array-safe under `set -u` (avoid word-splitting on filenames), have the helper
populate a named array via `declare -n` rather than `echo`. Example:

```bash
# Populate the array named by $1 with the tool-ordered pair.
#   $1 = name of target array
#   $2 = terraform-variant token   $3 = tofu-variant token
#   $4 = $TERRAFORM_TOOLS_EXIST     $5 = $TERRAFORM_SHORT_NAME
_tool_ordered_files () {
    local -n _out="$1"
    local tf_tok="$2" tofu_tok="$3" state="$4" short="$5"
    case "$state" in
        both)
            if [ "$short" = "tofu" ] ; then _out=("$tofu_tok") ; else _out=("$tf_tok") ; fi ;;
        terraform) _out=("$tf_tok" "$tofu_tok") ;;
        tofu)       _out=("$tofu_tok" "$tf_tok") ;;
        *)          _out=("$tf_tok") ;;
    esac
}
```

Then the two cascades collapse to:

```bash
    TF_AUTO_CONFIG_FILES=()
    if [ $tf_auto_config_default -eq 1 ] ; then
        _tool_ordered_files TF_AUTO_CONFIG_FILES \
            "terraform.sh.tfvars" "tofu.sh.tfvars" \
            "$TERRAFORM_TOOLS_EXIST" "$TERRAFORM_SHORT_NAME"
    else
        TF_AUTO_CONFIG_FILES=("$TF_AUTO_CONFIG_FILE")
    fi

    DEFAULT_CONF_FILES=("/etc/terraformsh" ~/.terraformshrc "./.terraformshrc")
    declare -a _conf_pair=()
    _tool_ordered_files _conf_pair \
        "./terraformsh.conf" "./tofush.conf" \
        "$TERRAFORM_TOOLS_EXIST" "$TERRAFORM_SHORT_NAME"
    DEFAULT_CONF_FILES+=("${_conf_pair[@]}")
```

Notes for whoever applies this:

- **Behavior change to acknowledge:** the helper standardizes the single-tool
  ordering to "active tool first," which **changes** the current
  `DEFAULT_CONF_FILES` result for **both** single-tool states:
  - terraform-only: `(tofush.conf, terraformsh.conf)` → `(terraformsh.conf, tofush.conf)`
  - tofu-only: `(terraformsh.conf, tofush.conf)` → `(tofush.conf, terraformsh.conf)`

  Both flips change `_load_conf` override precedence (last file sourced wins).
  Decide deliberately whether reordering both arms to "active tool first" is the
  intended behavior, or whether `TF_AUTO_CONFIG_FILES` is the one that should
  change to match the old conf ordering (other tool first). Either way, pick one
  convention and document it; the value of the helper is that the two cascades can
  no longer silently disagree.
- `declare -n` / `local -n` namerefs require bash 4.3+. The script already relies
  on bash arrays and `mapfile`-style constructs, so this is consistent with the
  existing baseline; confirm against the project's minimum bash version.
- The other two `$TERRAFORM_TOOLS_EXIST` blocks (tool detection and `TERRAFORM`
  binary selection) are **not** ordered-pair cascades and should be left as-is;
  do not try to force them through the same helper.

## Risk / impact

- **Who hits it:** anyone on a terraform-only (or tofu-only) host who keeps both a
  `terraformsh.conf` and a `tofush.conf` in the same directory, or both
  `terraform.sh.tfvars` and `tofu.sh.tfvars` in the inheritance path, with
  conflicting settings. That is a narrow population.
- **How often:** rare in practice — most users have one tool and one conf file.
- **How bad:** low. Worst case is surprising config precedence (the "wrong"
  `*.conf` overriding the other) on a single-tool host, not a crash or data loss.
  The larger, ongoing cost is maintainability: four `$TERRAFORM_TOOLS_EXIST`
  dispatches that future edits must keep in sync, which is exactly how the
  current ordering inconsistency slipped in.

## Related findings

- [18](18-duplicated-cmd-functions.md) and [20](20-version-spawned-repeatedly.md) — other `_default_vars` / tool-selection cleanups;
  this is a good candidate to bundle into the same "tool-selection refactor" PR as
  18 and 20 so the `$TERRAFORM_TOOLS_EXIST` handling is consolidated in one change.
