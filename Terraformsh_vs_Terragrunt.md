# Terraformsh VS Terragrunt

This is an (admittedly biased) comparison of Terraformsh to Terragrunt. If you find it to be inaccurate or need improving, please feel free to open a PR.

For the more wordy origins of Terraformsh, see [PHILOSOPHY.md](./PHILOSOPHY.md).

## Main Takeaways

### Terraformsh
 - Users don't need to learn custom HCL to modify configs and deploy changes
 - Config file designed for user to not need to know anything, just run `terraformsh` command in a specific dir and it does what's needed. No knowledge about the tool required
 - Run it how you want. Endless configuration options, execution options. Modify the source code if you want (it's just a small shell script!)
 - Almost the same as stock Terraform, while making things easier, safer, more reliable by default

### Terragrunt
 - Implements its own custom version of HCL which user needs to learn first, not applicable to any other tool
 - Writes/builds custom Terraform code on the fly, execution is dynamic and based on reading/interpreting many files
 - Many more concepts built in; more to learn, more to go wrong
 - Limiting: can't do things with Terragrunt unless there's a built-in feature. No customizing/tweaking/hacking (without becoming a Go programmer)


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

### Design Concepts/Features

Terraformsh has fewer design concepts and features.

<table>
<tr>
<td>

#### Terraformsh
<ul>
<li> Shell scripting
<li> Terraform commands
<li> Hierarchical configuration
<li> Sane/safe default behavior
<li> Avoid common problems
<li> Automate away toil
</ul>
</td><td>

#### Terragrunt
<ul>
<li> Units
<li> Stacks
<li> Includes
<li> Backends
<li> Catalogs
<li> Scaffolds
<li> Extra Arguments
<li> Authentication
<li> Before/After/Error Hooks
<li> Auto-init
<li> Feature flags
<li> Provider Cache Server
</ul>
</td>
</tr>
</table>

## Configuration examples

Below are examples of Terraformsh and Terragrunt.

What you'll find is that Terraformsh's configuration and operation is much smaller and simpler, while Terragrunt's is complex.

Despite that, they accomplish virtually the same tasks, the difference being a human (or AI agent) organizes and runs them differently.

### Terraformsh

#### Sample: A deployable Terraform module

<details>
<summary>[expand] Sample configuration files for Terraformsh</summary>

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

</details>
<br />

##### What does that sample configuration do?

1. User changes to directory `root/stage/us-east-1/mysql` and runs `$ terraformsh plan`
   1. Terraformsh finds all files in parent directories like `terraform.sh.tfvars` or `backend.sh.tfvars`
   2. Terraformsh will change to the `$CD_DIR` directory (the root of the git repo + `tf/aws/root/rds/cluster-aurora`)
   3. Terraformsh will run `terraform plan` and pass all the `terraform.sh.tfvars` and `backend.sh.tfvars` files

Everything that happens is effectively identical to stock Terraform.

Note that Terraformsh doesn't force you to write your Terraform modules in any particular way.
If you want your modules to be reusable and DRY, you must write them that way (Terraformsh doesn't do it for you).
You must therefore intentionally name variables so they are independent per module (if you want them to be
inherited separatey), or reuse the same name variable across modules (to overwrite their values).

The benefit here is a *lack* of advanced functionality, which forces you to work in a simple way.
The result is it's easier to see what, where, and how everything is, so there's less that can go wrong.


### Terragrunt

#### Sample: A Terragrunt installation

<details>
<summary>[expand] Sample Terragrunt configuration files</summary>
From https://github.com/gruntwork-io/terragrunt-infrastructure-live-example/ :

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

</details>
<br />

##### What does that sample configuration do?

1. User runs Terragrunt; it scans all subdirectories for modules.
2. For Terragrunt to run a command in those subdirectories, it will begin processing them one by one...
   1. It goes to subdirectory `nonprod/us-east-1/stage/mysql`
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
    

**As you can see, there's a lot more going on with Terragrunt:**
 - Multiple directories traversed
 - Code generated on the fly (debugging is harder)
 - Variables created on the fly (hard to tell where a value/change originates)
 - Files loaded from different paths depending what's going on (hard to follow execution without reading and traversing every file)
 - Different parts of a single Terraform module defined in different Terragrunt files
 - Execution in different files at different times

**So consequently:**
 - Troubleshooting will be more difficult, as you attempt to determine at which point a problem has occurred.
 - In order to edit or troubleshoot any of this, you will have to be trained on Terragrunt concepts, operation, and language, after you have learned Terraform.
 - None of this is stock Terraform behavior.



