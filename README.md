    terraformsh v0.8
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

 - Run 'plan' in a root module directory, just like Terraform:

       $ cd rootmodules/aws-infra-region/
       $ terraformsh plan

 - Run 'plan', ask for approval, then 'apply' the plan:

        $ terraformsh -C rootmodules/aws-infra-region/ \
          -f terraform.tfvars.json \
          -f override.auto.tfvars.json \
          -b backend.tfvars \
          -b backend-key.tfvars \
          plan approve apply

 - Run 'plan' using a `.terraformshrc` file that has all the above options,
   but override terraformsh's internal arguments to 'terraform plan':

        $ terraformsh -E 'PLAN_ARGS=("-compact-warnings" "-no-color" "-input=false")' \
          plan

 - Run 'plan' on a module and pass any configs found in these directories:

        $ terraformsh -C rootmodules/my-database/ \
           *.tfvars  *.backend.tfvars \
           env/my-database/*.tfvars  env/my-database/*.backend.tfvars \
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
  `.terraformshrc`, `terraformsh.conf`), with the following key=value pairs:

    DEBUG=0
    TERRAFORM=terraform
    TF_PLANFILE=terraform.plan
    TF_DESTROY_PLANFILE=terraform-destroy.plan
    TF_BOOTSTAP_PLANFILE=terraform-bootstrap.plan
    USE_PLANFILE=1
    INHERIT_TFFILES=1
    NO_DEP_CMDS=0

  The following can be set in the Terraformsh config file as Bash arrays, or you
  can set them by passing them to `-E`, such as `-E "CD_DIRS=(../some-dir/)"`.

    VARFILES=()     # files to pass to -var-file
    BACKENDVARFILES=() # files to pass to -backend-config
    CD_DIRS=()       # the directories to change to before running commands
    CMDS=()             # the commands for terraformsh to run
    PLAN_ARGS=(-input=false)   # the arguments for 'terraform plan'
    APPLY_ARGS=(-input=false) # the arguments for 'terraform apply'
    PLANDESTROY_ARGS=(-input=false) # arguments for 'plan -destroy'
    DESTROY_ARGS=(-input=false) # arguments for 'terraform destroy'
    REFRESH_ARGS=(-input=false) # arguments for 'terraform refresh'
    INIT_ARGS=(-input=false)     # arguments for 'terraform init'
    IMPORT_ARGS=(-input=false)   # arguments for 'terraform import'
    GET_ARGS=(-update=true)       # arguments for 'terraform get'
    STATE_ARGS=()     # arguments for 'terraform state'

  To use the 'aws_bootstrap' command, pass the '-b FILE' option and make sure the
  file(s) have the following variables:

    bucket          - The S3 bucket your Terraform state will live in
    dynamodb_table  - The DynamoDB table your Terraform state will be managed in

---

# Options

  Pass these *OPTIONS* before any others (see examples); do not pass them after
  *TFVARS* or *COMMAND*s.

    -f FILE         A file passed to Terraform's -var-file option.
                    (config: VARFILES=)

    -b FILE         A file passed to Terraform's -backend-config option.
                    (config: BACKENDVARFILES=)

    -C DIR          Change to directory DIR. (config: CD_DIRS=())

    -c file         Specify a '.terraformshrc' configuration file to load

    -E EXPR         Evaluate an expression in bash ('eval EXPR').

    -I              Disables automatically loading any 'terraform.sh.tfvars',
                    'terraform.sh.tfvars.json', or 'backend.sh.tfvars' files 
                    found while recursively searching parent directories.
                    (config: INHERIT_TFFILES=0)

    -P              Do not use '.plan' files for plan/apply/destroy commands.
                    (config: USE_PLANFILE=0)

    -D              Don't run 'dependency' commands (e.g. don't run "terraform
                    init" before "terraform apply"). (config: NO_DEP_CMDS=1)

    -N              Dry-run mode (don't execute anything). (config: DRYRUN=1)

    -v              Verbose mode. (config: DEBUG=1)

    -h              This help screen

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
