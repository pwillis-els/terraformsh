# Changelog

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
