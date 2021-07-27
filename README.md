    terraformsh v0.7
    Usage: ./terraformsh [OPTIONS] [TFVARS] COMMAND [..]

# Requirements
 - Bash (v3+)
 - Terraform
 - AWS CLI (only for aws_bootstrap command)

# About
  Terraformsh makes it easier to run Terraform by taking care of things you might
  normally need to do by hand. Unlike Terragrunt, the script assumes only the
  default behavior of Terraform and other tools; there is no DSL or code
  generation. However, you can still keep your code and configuration DRY with
  this tool, and reduce the overall complexity needed to maintain your Terraform.

  Terraformsh will detect and use configuration files automatically, making it
  easy to perform immutable, version-controlled, infrastructure-as-code changes.
  Overrides can be passed by environment and command-line options. Good 
  conventions like using .plan files for changes are also the default.

## Examples

 - Run 'plan', ask for approval, then 'apply' the plan:

        $ ./terraformsh \
          -f ../terraform.tfvars.json -f override.auto.tfvars.json \
          -b ../backend.tfvars -b backend-key.tfvars \
          -C ../../../rootmodules/aws-infra-region/ \
          plan approve apply

 - Run 'plan' using a `.terraformshrc` file, but override the *PLAN_ARGS* array:

      $ ./terraformsh \
        -E 'PLAN_ARGS=("-compact-warnings" "-no-color" "-input=false")' \
        plan


 - Run 'plan' on a module, passing configs the shell finds in these directories:

      $ ./terraformsh \
         -C ../../modules/my-database/ \
         *.tfvars \
         *.backend.tfvars \
         my-database/*.tfvars \
         my-database/*.backend.tfvars \
         plan


 - Run 'plan' on a module, implicitly loading configuration files from parent directories:

      $ pwd
      /home/vagrant/git/some-repo/env/non-prod/us-east-2/my-database
      $ echo 'CD_DIRS=(../../../../modules/my-database/)' > terraformsh.conf
      $ echo 'aws_account_id = "0123456789"' > ../../terraform.sh.tfvars
      $ echo 'region = "us-east-2"' > ../terraform.sh.tfvars
      $ echo 'database_name = "some database"' > terraform.sh.tfvars
      $ terraformsh plan


## Details

  Change to the directory of a Terraform module and run `terraformsh` with any
  Terraform commands and arguments you'd normally use. Terraformsh will run any
  'dependent' Terraform commands first; if you run `terraformsh plan`, 
  Terraformsh will first run `terraform validate`, which will first run
  `terraform get`, which will first run `terraform init`.
  Each time Terraformsh passes the correct options as necessary (but you can
  override them multiple ways).

  Terraformsh supports passing multiple commands in one command-line (see
  *Examples* section) as well as multiple of the same option.

  You can configure Terraformsh to change to a module's directory before running
  commands so you don't have to do it yourself (`-C` option).

  You can pass *TFVARS* ('\*.backend.tfvars', '\*.backend.sh.tfvars', '\*.tfvars.json',
  '\*.tfvars', '\*.sh.tfvars.json', '\*.sh.tfvars') after *OPTIONS* to pass these
  files to Terraform commands as needed. Or you can specify them using their 
  accompanying *OPTION* (see below). Finally, if there exist files in any parent
  directory named `backend.sh.tfvars`, `terraform.sh.tfvars.json`, or
  `terraform.sh.tfvars`, those will be loaded automatically as well (disabled with
  `-I` option).

  You can override the following default variables with environment variables, or
  set them in a bash configuration file (`/etc/terraformsh`, `~/.terraformshrc`,
  `.terraformshrc`, `terraformsh.conf`):

    DEBUG=0
    TERRAFORM=terraform
    TF_PLANFILE=terraform.plan
    TF_DESTROY_PLANFILE=terraform-destroy.plan
    TF_BOOTSTAP_PLANFILE=terraform-bootstrap.plan
    USE_PLANFILE=1
    INHERIT_TFFILES=1

  The following can be set in the config file as arrays, or you can set them
  by passing them to `-E`, such as `-E CD_DIRS=(../some-dir/)`

    VARFILE_ARG=()
    CD_DIRS=()
    CMDS=()
    BACKENDVARFILE_ARG=()
    PLAN_ARGS=(-input=false)
    APPLY_ARGS=(-input=false)
    PLANDESTROY_ARGS=(-input=false)
    DESTROY_ARGS=(-input=false)
    REFRESH_ARGS=(-input=false)
    INIT_ARGS=(-input=false)
    IMPORT_ARGS=(-input=false)
    GET_ARGS=(-update=true)
    STATE_ARGS=(-input=false)

  To use the 'aws_bootstrap' command, pass the '-b FILE' option and make sure the
  file(s) have the following variables:

    bucket          - The S3 bucket your Terraform state will live in
    dynamodb_table  - The DynamoDB table your Terraform state will be managed in

---

# Options

  Pass these *OPTIONS* before any others (see examples); do not pass them after
  *TFVARS* or *COMMAND*s.

    -f FILE           A file passed to Terraform's -var-file option
    -b FILE           A file passed to Terraform's -backend-config option
    -C DIR            Change to directory DIR
    -c file           Specify a '.terraformshrc' configuration file to load
    -E EXPR           Evaluate an expression in bash ('eval EXPR')
    -I                Disables automatically loading any 'terraform.sh.tfvars',
                      'terraform.sh.tfvars.json', or 'backend.sh.tfvars' files 
                      found while recursively searching parent directories.
    -P                Do not use '.plan' files for plan/apply/destroy commands
    -N                Dry-run mode (don't execute anything)
    -v                Verbose mode
    -h                This help screen

# Commands

  The following are commands that terraformsh provides wrappers for. Commands
  not listed here will be passed to terraform verbatim, along with any options.

    plan              Run init, get, validate, and `terraform plan -out terraform.plan`
    apply             Run init, get, validate, and `terraform apply terraform.plan`
    plan_destroy      Run init, get, validate, and `terraform plan -destroy -out=terraform-destroy.plan`
    destroy           Run init, get, validate, and `terraform apply terraform-destroy.plan`
    shell             Run init, get, and `bash -i -l`
    refresh           Run init, and `terraform refresh`
    validate          Run init, get, and `terraform validate`
    init              Run clean_modules, and `terraform init`
    clean             Remove '.terraform/modules/*', terraform.tfstate files, and .plan files
    clean_modules     Run `rm -v -rf .terraform/modules/*`
    approve           Prompts the user to approve the next step, or the program will exit with an error.
    aws_bootstrap     Looks for 'bucket' and 'dynamodb_table' in your '-b' file options.
                      If found, creates the bucket and table and initializes your Terraform state with them.
    import            Run `terraform import [...]`
    state             RUn `terraform state [...]`
