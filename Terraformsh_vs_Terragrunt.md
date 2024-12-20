# Terraformsh VS Terragrunt

This is an admittedly biased comparison of Terraformsh to Terragrunt.
If any inaccuracies are found (or it's just confusing), please open an issue or pull request so it can be corrected here.
Thank you


## Design overview

### Goals

| Terraformsh | Terragrunt |
| ---         | ---        |
|  DRY code   | DRY code   |
|  DRY configuration | Less DRY configuration   |
| Compatible with all Terraform versions | Compatible with Terraform 0.12+ |
| Portable to all operating systems & CPU architectures (with bash) | Portable to Linux, Mac Windows, X86_64 and ARM64 |
| Simple | Complex |
| Configuration file is just a shell script ("foo=bar") | Configuration file is a DSL based on HCL |
| Assumes the use of .tfvars files to pass data to Terraform | Mixes environment variables, .tfvars, and Terraform code generated on-the-fly |
| Unopinionated | Opinionated |

### Notes

#### Terraformsh
 - Users do not need to learn HCL to modify .tfvars files and deploy changes to modules
 - Configuration file designed so you can have a user just run the 'terraformsh' command, and it will do whatever is needed, with no knowledge about the tool required.
 - Run it any way you want, use it any way you want. Endless configuration options, execution options. Modify the source code if you want (it's just a shell script)

#### Terragrunt
 - Implements its own custom Domain-Specific Language. 
   You cannot modify anything in Terragrunt without first learning Hashicorp Configuration Language, and then learning Terragrunt's changes to the language.
   No other tool uses this, so once you learn this, you can't use this knowledge for any other purpose.
   Any users you want to work with your infra will have to become Terraform/Terragrunt experts.
 - Writes/builds custom Terraform code on the fly
 - Limiting
   - You cannot do things with Terragrunt unless they have built a feature for it. No customizing/tweaking/hacking, without becoming a Go programmer and forking the Terragrunt source code.


### Design Concepts/Features

#### Terraformsh
 - Shell scripting
 - Terraform commands
 - Hierarchical configuration
 - Sane/safe default behavior
 - Avoid common problems
 - Automate away toil

#### Terragrunt
 - Units
 - Stacks
 - Includes
 - Backends
 - Catalogs
 - Scaffolds
 - Extra Arguments
 - Authentication
 - Before/After/Error Hooks
 - Auto-init
 - Feature flags
 - Provider Cache Server


## Configuration example

### Terraformsh

#### Sample 1: A deployable Terraform module

This is a configuration file for a deployable directory with Terraformsh.

```
# root/terraform.sh.tfvars
#
aws_account_id = "123456789"
```

```
# root/backend.sh.tfvars
#
bucket          = "tf-state-123456789"
dynamodb_table  = "tf-state-lock-123456789"
```

```
# root/stage/terraform.sh.tfvars
#
environment_type                = "stage"
kms_alias_ssm_session_manager   = "ssm-session-manager-main-key-us-east-1"
```

```
# root/stage/us-east-1/terraform.sh.tfvars
#
region      = "us-east-1"
rds_kms_key = "alias/rds-kms-key"
```

```
# root/stage/us-east-1/backend.sh.tfvars
#
region = "us-east-1"
```

```
# root/stage/us-east-1/mysql/terraformsh.conf

ROOTDIR=$(git rev-parse --show-toplevel)
CD_DIR="$ROOTDIR/tf/aws/root/rds/cluster-aurora"
```

```
# root/stage/us-east-1/mysql/terraform.sh.tfvars
#
service_name = "mydb"
```
```
# root/stage/us-east-1/mysql/backend.sh.tfvars
#
key = "tfstate/stage/us-east-1/mysql.tfstate"
```



##### What does this do?

1. The user changes to directory `root/stage/us-east-1/mysql` and runs `$ terraformsh plan`
   1. Terraformsh finds all files in parent directories like `terraform.sh.tfvars` or `backend.sh.tfvars`
   2. Terraformsh will change to the `$CD_DIR` directory (the root of the git repo + `tf/aws/root/rds/cluster-aurora`)
   3. Terraformsh will run `terraform plan` and pass all the `terraform.sh.tfvars` and `backend.sh.tfvars` files

As you can see, it's not doing anything special, and doesn't require lots of configuration.
Everything that happens at this point is the same way it is with stock Terraform.

A "downside" here is that it doesn't force you to write your Terraform modules any particular way.
You must intentionally write your modules to be reusable and DRY. You must also intentionally create
your .tfvars files to split up and inherit your configuration.

The "upside" here is there is no advanced functionality to use, so you are forced to do things in a simple way.
That ends up making it much easier to see where everything is, how it all works, and there is less that can go wrong.



### Terragrunt

#### Sample 1: A sample Terragrunt installation

This is the root file of their configuration, from https://github.com/gruntwork-io/terragrunt-infrastructure-live-example/

```
# root.hcl
#
locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))

  region_vars = read_terragrunt_config(find_in_parent_folders("region.hcl"))

  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  account_name = local.account_vars.locals.account_name
  account_id   = local.account_vars.locals.aws_account_id
  aws_region   = local.region_vars.locals.aws_region
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"

  allowed_account_ids = ["${local.account_id}"]
}
EOF
}

remote_state {
  backend = "s3"
  config = {
    encrypt        = true
    bucket         = "${get_env("TG_BUCKET_PREFIX", "")}terragrunt-example-tf-state-${local.account_name}-${local.aws_region}"
    key            = "${path_relative_to_include()}/tf.tfstate"
    region         = local.aws_region
    dynamodb_table = "tf-locks"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}

catalog {
  urls = [
    "https://github.com/gruntwork-io/terragrunt-infrastructure-modules-example",
    "https://github.com/gruntwork-io/terraform-aws-utilities",
    "https://github.com/gruntwork-io/terraform-kubernetes-namespace"
  ]
}

inputs = merge(
  local.account_vars.locals,
  local.region_vars.locals,
  local.environment_vars.locals,
)
```

```
# _envcommon/mysql.hcl
#
locals {
  environment_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  env = local.environment_vars.locals.environment

  base_source_url = "git::git@github.com:gruntwork-io/terragrunt-infrastructure-modules-example.git//modules/mysql"
}

inputs = {
  name              = "mysql_${local.env}"
  instance_class    = "db.t2.micro"
  allocated_storage = 20
  storage_type      = "standard"
  master_username   = "admin"
}
```

```
# nonprod/account.hcl
#
# Set account-wide variables. These are automatically pulled in to configure the remote state bucket in the root
# terragrunt.hcl configuration.
locals {
  account_name   = "non-prod"
  aws_account_id = "replaceme" # TODO: replace me with your AWS account ID!
}
```

```
# nonprod/us-east-1/region.hcl
#
locals {
  aws_region = "us-east-1"
}
```


```
# nonprod/us-east-1/stage/env.hcl
#
locals {
  environment = "stage"
}
```

```
# nonprod/us-east-1/stage/mysql/terragrunt.hcl
# 
include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path = "${dirname(find_in_parent_folders("root.hcl"))}/_envcommon/mysql.hcl"
  # We want to reference the variables from the included config in this configuration, so we expose it.
  expose = true
}

terraform {
  source = "${include.envcommon.locals.base_source_url}?ref=v0.8.0"
}
```

##### What does this do?

1. When you run Terragrunt, it will scan all subdirectories for modules.
2. If you wanted Terragrunt to run a command in those subdirectories, it will begin processing them one by one...
   1. It goes to the subdirectory: `nonprod/us-east-1/stage/mysql`
   2. It looks in all parent directories for a `root.hcl` file and begins parsing it
      1. It looks in parent directories of the first subdirectory (not the root directory...) for a file `account.hcl`
      2. It sets `account_name` and `aws_account_id` local variables
      3. It adds those variables to a list `account_vars`
      4. It creates another local variable `account_name` which points at `local.account_vars.local.account_name`
      5. It begins generating custom Terraform code on the fly
        1. It will overwrite a file `provider.tf`
        2. It sets the provider `region`
        3. It sets the provider `allowed_account_ids`
      6. It creates a block in memory for remote storage
        1. It defines an s3 backend
        2. It defines the `encrypt, `bucket`, `key`, `region`, and `dynamodb_table` entries
           1. `bucket` is based on both an environment variable (sometimes!) and two local variables
           2. `key` is based on the relative path of the current directory, so if you move this directory, it will change where the terraform state is stored in S3
      7. It defines a series of URLs to search for catalog function (Terragrunt-specific)
      8. It defines variables that all modules inherit from this file
   3. It again looks for the parent directory with `root.hcl`, but this time to specify a path to a file `/_envcommon/mysql.hcl` in it, and parses/includes that file
      1. It finds and loads the `env.hcl` file from one of the middle-directories
      2. It defines more local variables
      3. It defines the path to a terraform module in a Git repo
      4. It defines some default inputs to a Terraform module, such as the instance type of a database
   4. It defines the version of the Terraform module to deploy from this directory
    

As you can see, there is a lot going on here.
 - Multiple directories are traversed, variables get created on the fly, code is generated.
 - Files are loaded from all different paths depending on what's going on; it's hard to follow the execution without reading and traversing every file.
 - There are many different new failure modes exposed here (ways things can go wrong) that don't exist with stock Terraform.
 - Variables are created on the fly, rather than being static, so it's hard to tell where a value or change is coming from.
 - Execution jumps around in different files at different times. Different parts of a Terraform module are defined in different Terragrunt files. You can't just look at one directory of files and see what the Terraform module will do or look like, it's generated on the fly.

Consequently:
 - Troubleshooting will be more difficult, as you attempt to determine at which point a problem has occurred.
 - In order to edit or troubleshoot any of this, you will have to be trained on Terragrunt concepts, operation, and language, after you have learned Terraform.
 - None of this is stock Terraform behavior.
