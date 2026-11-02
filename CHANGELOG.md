# Changelog

## [v0.15] - 2025-02-11

### Added
 - Test running workflow on multiple versions of terraform @pwillis-els (#28)

### Fixed
 - Fix 'terraformsh apply' with no varfiles @peterwwillis (#31)
 - Fix/apply tfvars (from PR #27) @pwillis-els (#29)

---

## [v0.14] - 2023-08-12

### Added
  - Example of migrating state.

### Fixed
  - Bug where "+ cd ..." is printed multiple times. Instead check what the last
    "cd" was set to, and if this one is the same, don't "cd" again.
  - Bug where backend config was getting appended to the init command every time
    the _final_vars function was called.
  - Need to have both 'cd' operations follow each other.
  - Make revgrep run in a subshell so 'cd' in that command doesn't negatively
    effect other commands.
  - Bug where status was returned 0 even if 'terraform apply' had errors.
    Instead return terraform's real return code.
  - Bug where 'terraformsh state rm' does not create a backup file correctly
    on MacOS.

---

## [v0.13] - 2022-09-27

### Added
  - Add revgrep command @pwillis-els (#21)
  - Add asdf plugin support @pwillis-els (#20)
  - Add release drafter and lint script @Th0masL (#18)
  - Try an updated release drafter @pwillis-els (#23)

### Fixed
  - Fix missing '$' in release drafter config @pwillis-els (#24)
  - Fix rfindfiles, add env command, add troubleshooting example @pwillis-els (#22)
  - Fix sed on MacOS @Th0masL (#15)

---

## [v0.12] - 2022-01-31

### Added
 - Option '-n' (NO_CLEANUP_TMP=1) prevents removing the dynamic TF_DATA_DIR
 - Wrappers for most Terraform commands (workspace, console, output, taint, 
   untaint, force-unlock)
 - '-backup=' option added to 'terraformsh state rm ...' commands

### Changed
 - Removal of temporary TF_DATA_DIR is avoided only if NO_CLEANUP_TMP_ON_ERROR=1
   . Before it would have left the directory intact on error, leading to it
   being re-used the next time.
 - Check for files with '-e', do not check if they're readable with '-r'
 - Prevent re-running 'terraform init' multiple times in same session

### Fixed
 - Location of default plan file
 - 'terraform validate' for newer versions of Terraform
 - Passing arbitrary options to commands
 - Detecting sub-commands of parent commands
 - Detecting previously-set TF_DATA_DIR
 - Run 'init' before 'import
 - Fix running 'terraform state' with no other arguments and add missing
   WORKSPACE_ARGS array

---

## [v0.11] - 2021-11-02

### Added
 - Unit tests (only 3 so far)
 - GitHub Actions integration

### Fixed
 - `terraformsh -P destroy` now works as expected. Before it would try to run
     'terraform apply' rather than 'terraform destroy'.
   You can auto-accept with `terraformsh -P -E "DESTROY_ARGS+=(-auto-accept)" destroy`
   (or set it in a config file like ~/.terraformshrc).
   Thanks @AMKamel for the contribution! \o/

---

## [v0.10] - 2021-10-22

### Added
 - Handlers for 0.12upgrade and 0.13upgrade commands
 - Allow overriding `TF_BACKEND_AUTO_CONFIG_FILE` and `TF_AUTO_CONFIG_FILE`
  
### Changed
 - Before, '-reconfigure -force-copy' was always passed to 'terraform init'.
   Now it can now be overridden in `INIT_ARGS` .
 - 'terraform init' output before 'terraform state' now goes to STDERR, so
   that 'terraform state pull > foo.json' works as expected.
   NOTE: This behavior may change in the future (or really, all commands'
   output behavior may change, in order to eliminate this edge case)


### Fixed
 - Tfvars files now have their paths fully resolved before changing directories
 - Make sure configs' full paths are used when 'source'ing into shell
 - Run 'terraform init' before 'terraform state'

---

## [v0.9] - 2021-09-29
Initial release
