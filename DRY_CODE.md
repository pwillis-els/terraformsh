# DRY Code and Configuration

DRY is an acronym for Don't Repeat Yourself. It means to not duplicate programming code, and instead write the code once and load it from other pieces of code.

This concept is important for Terraform. At various times you may find yourself copying snippets of Terraform into multiple environments, only to find later that you did so inconsistently. DRY Terraform modules allow you to fix bugs in one place and apply the fix everywhere that the module is loaded without extra work and testing.

DRY configuration is the same idea as DRY code. You may have some array of tags that you want to apply to a lot of infrastructure, and later want to change one of the tags, and end up editing them all manually. It's better to keep those tags in one configuration file and load it every time you have a module that needs those tags.

One of the things Terragrunt was designed to do was to make your Terraform code more DRY. But you can have DRY code and configuration without Terragrunt. **Terraformsh**'s purpose is to assist you in running Terraform, partly to make common commands easier, and also to make it easier to use DRY configuration in a directory hierarchy.

## Example

First let's make some sub-modules. Think of these as libraries or functions in a traditional program. We write one module and load it from many other modules. We'll put them in a `submodule/` directory.
```
$ tree submodule/
submodule/
├── aws-ec2-instance
│   ├── output.tf
│   ├── s3.tf
│   └── variables.tf
└── aws-s3-bucket
    ├── output.tf
    ├── s3.tf
    └── variables.tf
```

Next let's make some root modules. Think of these like a compiled application: it dynamically loads its libraries (sub-modules) at run-time, and then takes input (configuration files), and then executes (builds our infrastructure). Let's put them in a `rootmodule/` directory.
```
$ tree rootmodule/
rootmodule/
└── aws
    ├── account-wide-iam
    │   ├── data.tf
    │   ├── modules.tf
    │   ├── output.tf
    │   ├── providers.tf
    │   ├── variables.tf
    │   └── versions.tf
    └── webserv
        ├── data.tf
        ├── modules.tf
        ├── output.tf
        ├── providers.tf
        ├── variables.tf
        └── versions.tf
```

Next we'll make the Terraform `*.tfvars` configuration that will be used by the variables in the Terraform modules. The names of these config files are auto-detected by **Terraformsh** if they are in the current directory or a parent directory. We'll put them in a directory called `config/`.
```
$ tree config/
config/
└── aws
    └── non-prod
        ├── global
        │   └── iam
        │       ├── backend.sh.tfvars
        │       └── terraform.sh.tfvars
        ├── terraform.sh.tfvars
        └── us-east-1
            └── webserv
                ├── backend.sh.tfvars
                └── terraform.sh.tfvars
```

Notice how the configs are split up in different directories. This has two purposes:

1. By putting the configuration files in a hierarchy, **Terraformsh** will detect them all by walking backwards up the directory tree, and pass them all to the subsequent `terraform` commands.

2. If you have a lot of infrastructure, you're going to need to split it up into pieces and deploy each piece separately. This is partly because deploying it all at once is very slow, but also because different parts of the system have different requirements. For example, IAM rules are applied globally to an AWS account, but an S3 bucket or EC2 instance is region-specific, so we split these pieces up so they can each be deployed according to their region or other logical separation. You can later reference different deployed components using Terraform's remote state data source.

The last part - how you actually run **Terraformsh** - is completely up to you. Here are some options:

 - If your current working directory isn't a Terraform root module, you'll have to pass the `-C` option to **Terraformsh** to have it change to a root directory for you. So you can decide to either change directories every time you want to run **Terraformsh** (just like with Terraform), or you can pass the `-C` option to **Terraformsh**, or you can create a `.terraformshrc` config file with the `CD_DIRS=(...)` option defined. The latter is the easiest way to run **Terraformsh**.

 - To pass configuration files to Terraform (your root modules probably have variables they want configuration for) you can pass the `-f` and `-b` options to **Terraformsh**. But if any files exist in the current or parent directories matching specific file names (`terraform.sh.tfvars`, `terraform.sh.tfvars.json`, `backend.sh.tfvars`), those config files will be loaded automatically. In addition, you can specify any configs you want in a `.terraformshrc` config file. So you can run **Terraformsh** from specific `config/` directory, or you can use the `.terraformshrc` config files from any directory.

 - Any option can be controlled from a `.terraformshrc` file, and you can pass those config files to **Terraformsh** using the `-c` option. On top of that, the `.terraformshrc` file is actually just a shell script loaded into **Terraformsh**'s shell at run time. You can really do anything you want with that file, including modifying the **Terraformsh** code on the fly!

 - You can keep `.terraformshrc` files in your `config/` directories. In this way you can just change to a `config/` directory and run `terraformsh` with no options at all, and everything will be detected and run automatically for you. This way you can make Terraform deployments without having to know anything at all except what directory you want to deploy. This is the principle by which all of **Terraformsh** was developed, so it is the suggested method to keep your code & configs DRY.


The final example should look something like this:
```
$ tree -a
.
├── config
│   └── aws
│       └── non-prod
│           ├── global
│           │   └── iam
│           │       ├── .terraformshrc
│           │       └── terraform.sh.tfvars
│           ├── terraform.sh.tfvars
│           └── us-east-1
│               └── webserv
│                   ├── backend.sh.tfvars
│                   ├── .terraformshrc
│                   └── terraform.sh.tfvars
├── rootmodule
│   └── aws
│       ├── global-iam
│       │   ├── data.tf
│       │   ├── modules.tf
│       │   ├── output.tf
│       │   ├── providers.tf
│       │   ├── variables.tf
│       │   └── versions.tf
│       └── webserv
│           ├── data.tf
│           ├── modules.tf
│           ├── output.tf
│           ├── providers.tf
│           ├── variables.tf
│           └── versions.tf
└── submodule
    ├── aws-ec2-instance
    │   ├── output.tf
    │   ├── s3.tf
    │   └── variables.tf
    └── aws-s3-bucket
        ├── output.tf
        ├── s3.tf
        └── variables.tf
```

And you would deploy it with the following commands:
```
$ pwd
/home/vagrant/git/terraformsh/dry-example
$ cd config/aws/non-prod/global/iam/

### This command is only used once, the first time you set up the
### remote state for this particular account. You can also just
### set up the backend state manually.
$ terraformsh aws_bootstrap

$ terraformsh
..... <terraformsh output> .....
$ cd ../../us-east-1/webserv/
$ terraformsh aws_bootstrap
$ terraformsh
..... <terraformsh output> .....
```

