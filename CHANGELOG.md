# Changelog

## [v0.12] - 2022-01-25

### Added
 - Option '-n' (NO_CLEANUP_TMP=1) prevents removing the dynamic TF_DATA_DIR
 - Wrappers for most Terraform commands (workspace, console, output, taint, untaint, force-unlock)
 - '-backup=' option added to 'terraformsh state rm ...' commands

### Changed
 - Removal of temporary TF_DATA_DIR is avoided only if NO_CLEANUP_TMP_ON_ERROR=1 . Before it would have left the directory intact on error, leading to it being re-used the next time.
 - Check for files with '-e', do not check if they're readable with '-r'
 - Prevent re-running 'terraform init' multiple times in same session

### Fixed
 - Location of default plan file
 - 'terraform validate' for newer versions of Terraform
 - Passing arbitrary options to commands
 - Detecting sub-commands of parent commands
 - Detecting previously-set TF_DATA_DIR
 - Run 'init' before 'import

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
