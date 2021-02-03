# terraformsh v0.4
  Usage: ./terraformsh [OPTIONS] COMMAND [..]

# About
  Terraformsh makes it easier to run Terraform in automation. It runs common
  Terraform commands for you in order, passing the right arguments as needed.
  It also defaults to good conventions, like using .plan files for changes.

# Requirements
 - Bash (v3+)
 - Terraform
 - AWS CLI (only for aws_bootstrap command)

# Usage
  You can specify most options and commands multiple times, as Terraform will allow
  you to pass options multiple times. This allows you to split up your configuration
  among multiple files/paths to keep it DRY.

  To use the 'aws_bootstrap' command, pass the '-b FILE' option and make sure the
  file(s) have the following variables:

    bucket          - The S3 bucket your Terraform state will live in
    dynamodb_table  - The DynamoDB table your Terraform state will be managed in

  You can also override the following variables as environment variables or in a
  .terraformshrc file:

    TERRAFORM=terraform
    TF_PLANFILE=terraform.plan
    TF_DESTROY_PLANFILE=terraform-destroy.plan
    TF_BOOTSTAP_PLANFILE=terraform-bootstrap.plan
    USE_PLANFILE=1
    VARFILE_ARG=()
    BACKENDVARFILE_ARG=()
    CD_DIRS=()
    CMDS=()
    PLAN_ARGS=(-input=false -out=terraform.plan)
    APPLY_ARGS=(-input=false terraform.plan)
    PLANDESTROY_ARGS=(-input=false -out=terraform-destroy.plan)
    DESTROY_ARGS=(-input=false terraform-destroy.plan)
    REFRESH_ARGS=(-input=false)
    INIT_ARGS=(-input=false)
    IMPORT_ARGS=(-input=false)
    GET_ARGS=(-update=true)
    DEBUG=0

# Examples
 - Run plan, ask for approval, then apply the plan:
    ```
    ./terraformsh \
      -f ../terraform.tfvars.json \
      -f override.auto.tfvars.json \
      -b ../backend.tfvars \
      -b backend-key.tfvars \
      -C ../../../rootmodules/aws-infra-region/ \
      plan \
      approve \
      apply
    ```
 - Run plan using a .terraformshrc file:
    ```
    ./terraformsh plan
    ```

# Options
    -f FILE           A file passed to Terraform's -var-file option
    -b FILE           A file passed to Terraform's -backend-config option
    -C DIR            Change to directory DIR
    -c file           Specify a '.terraformshrc' file to load
    -P                Do not use '.plan' files for plan/apply/destroy commands
    -v                Verbose mode
    -h                This help screen

# Commands
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
