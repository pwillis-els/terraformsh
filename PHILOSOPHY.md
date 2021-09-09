# Philosophy behind `terraformsh`

## Genesis

    In the beginning Hashicorp created Terraform. And it was good.

    But over time, the users revolted, and did protest much.
    "Too many unnecessary steps! Difficult to manage complex installations!
    Missing features! Not DRY!"

    And Gruntwork said, "Let there be Terragrunt," and there was DRY code.
    And it was good.

    But again, the users revolted, and did protest much.
    "Unnecessary non-standard DSL code! Hidden magic! Generated code!
    Difficult to troubleshoot! Opinionated!"

    And Peter said, "Let there be a Tiny Shell Script", and there was much
    forking. And it was... okay-ish.

---

## The Trouble with Being Advanced

Terraform is inherently complicated and difficult to use. Whether this is by design or by accident is immaterial. It is how it is, and it's not getting any better.

Many people have written small wrappers around Terraform to make its usability suck less. Terragrunt was one of those efforts, designed specifically to make it easier to support larger and more complex Terraform installations without duplicating code.

But the thing is... Terragrunt is *Advanced*. It has its own dialect of a Domain-Specific Language. It also parses Hashicorp Configuration Language. It can generate Terraform code, look up dependencies, etc. A lot of fancy stuff. And that's *cool*... but also *bad*. It leads to more complexity, when what we really want is simplicity.

So, is there a way to get the benefits we're looking for (DRY / easier to manage code, easier to run commands) without the added complexity?

---

## Keep It Simple, Stupid

It turns out that Terraform can be wrestled to do what we want without added complexity. We don't need to parse HCL or generate it, track dependencies, etc. Terraform will do pretty much everything we want, if we manage the code right. All we need to do is organize our Terraform code the right way, and then use a few handy shortcuts to call Terraform in common ways.

`terraformsh` is a POSIX shell script. All it does is run regular-old Terraform commands for you in ways you probably want. And it allows you to override any of its default behavior, so that you can always force it to behave the way you want. In this way it naturally fits into whatever pattern you use to run Terraform, but makes it slightly easier.

What's the magic that makes it both work the same, but also easier?

### 1. Passing multiple command-line options
 - Terraform has the handy property that it lets you pass the same option multiple times. This lets you do things like pass many configuration files, or many configuration options, on a single command-line. You can keep many configuration files spread across a filesystem hierarchy and re-use configuration files across many modules. This simple pattern lets you keep both your modules and module configuration DRY, without needing to pass environment variables to Terraform or auto-generate files. This makes `terraform apply` more immutable, idempotent, and DRY.

### 2. Running commands for you
 - Terraform expects you to be running in a stateful environment. That is to say, each Terraform command expects certain state to already exist; sometimes on the local filesystem, sometimes in remote state. Before you run `terraform plan`, you have to run `terraform init`, and have any credentials and whatnot already loaded. We can make running `terraform plan` easier by first running `terraform init` for you. We do this for any command you issue - unless you disable this feature.

### 3. Pre-configured complex behavior
 - In order to pass in multiple configuration files, or run multiple commands for you, we can load a simple configuration file. This file can determine where to find configuration files, what commands to run (or not run), etc. By automatically loading these configs (or if you pass them explicitly) we can simplify all the steps of running Terraform down to running a single command in a single directory.

### 4. Avoiding common problems
 - Ever changed your version of Terraform, or moved some files around, and tried to run Terraform again? A lot of the time, the old state files will cause Terraform to die and require you to manually intervene. We can automatically clean up these files to ensure that repeated commands in different situations won't die unexpectedly.

### 5. Easier troubleshooting
 - Ever run into an unexpected problem and needed to dig into it with custom Terraform commands? We support a `terraformsh shell` command that will drop you into a command-line prompt (after running the appropriate 'terraform init' etc) to let you deal with the issue manually.

### 6. Bootstrapping remote state
 - Ever want to start some new remote state, but you need to create a DynamoDB table and S3 bucket and do the `terraform init -reconfigure -force-copy` jig? We have a function for all of that.

### 7. Run commands from any directory
 - Don't want to have to 'cd' into a root module directory to run Terraform there? Don't have to. `-C` option does it for you.

### 8. Use good conventions
 - Don't want to remember to use `terraform plan -out=foo.plan` and `terraform apply foo.plan`? We do it automatically (unless you disable it). Same for `terraform plan -destroy -out=foo.plan`, so you won't accidentally `terraform destroy -auto-approve` all your infrastructure.

### 9. Pass in arbitary Terraform options
 - So you have a weird exception where you want to pass `-target=RESOURCE` to your `terraform plan`. No problem! Just pass in the normal Terraform options after the `plan` command, and `terraformsh` will pass the options in automatically.

### 10. It's Just a Shell Script
 - It's literally just a single POSIX shell script. If it doesn't do what you want, if it breaks, whatever... just change it. You don't have to be a super cool Go programmer or invest a lot of time in testing. It's really frickin' simple if you know shell scripting, and if you don't, you can easily find someone that does.

The end result should be the simplest possible way to make it easier to run Terraform, both in automation, and manually, while keeping code and configs DRY.

---

## Better Code Management

One of the things Terragrunt was designed to do was to manage your code for you. Rather than you setting up lots of modules a certain way, it auto-generates them and runs them for you. This is certainly handy! But if you're willing to do a bit of leg work, you can make these modules yourselves - and keep them (and their configuration) DRY.

The `terraformsh` tool does not solve this problem for us, but it makes it much easier to address. You set up the modules and configuration, and `terraformsh` will juggle them with ease.

Let's go through a quick example.

First, we're going to make some sub-modules. Think of these as libraries or functions in a traditional program. We will write one once, and load it from many other modules. We'll put them in a `submodule/` directory.

```
$ tree submodule/
submodule/
└── aws-s3-bucket
    ├── output.tf
    ├── s3.tf
    └── variables.tf
```

Next, we're going to make some root-modules. Think of these as like executable apps; they'll load sub-modules in at run-time, and configuration, and build our infrastructure. We'll put these in an `rootmodule/` directory.

```
$ tree rootmodule/
rootmodule/
└── aws
    ├── global-iam
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

Next, we're going to make the Terraform `*.tfvars` configuration for all the above Terraform code. If your Terraform modules take variables (and they should!), we can pass configuration files to Terraform at run-time, which will feed the variables used by the modules. We'll put these in a `config/` directory.

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

The last part is up to you, as `terraformsh` can be run in many ways based on your preference.

 - By default, `terraformsh` will run any `terraform` commands you give it (`terraformsh plan`, `terraformsh apply`) with no options, and Terraform assumes your current working directory is a root module. So you can `cd` to a root module and run `terraformsh` commands, or you can pass `terraformsh` the `-C` option with a root module argument. If you want to pass in `config/` files, you'll have to pass them to `terraformsh` using its shortcut options (`-f` and `-b`) or Terraform's options (`-var-file` and `-backend-config`).

 - If you want a little more automation, you can create a `.terraformshrc` file (see the example in this directory) in your current directory. This file can include all the options you would normally pass to `terraformsh`. This way you can just keep a `.terraformshrc` file in any directory, change to that directory, and run `terraformsh plan apply` (or a similar Terraform command).

 - You can keep your `.terraformshrc` file in your `config/` directories. Or you can create a `deploy/` directory with just `terraformsh` configs, and keep one config file per deployment.


My suggestion is to put a `.terraformshrc` file in your `config/` directories. Using the above layout, the `terraform.sh.tfvars` files will be automatically loaded in hierarchical order (`non-prod/terraform.sh.tfvars` will be loaded first, then `non-prod/webserv/terraform.sh.tfvars`, and then `non-prod/webserv/backend.sh.tfvars`) and all passed to Terraform commands as needed. In this way, all you have to do is change to the `config/` directory you want to deploy from, and run `terraformsh plan apply`.

---

## WhaT aBOuT a MaKeFIlE?

I did create a Makefile wrapper for Terraform. And then a shell script and Makefile. And then finally, just a shell script.

Makefiles are not wrappers around tools, they are actually build specifications. Can you make a Makefile basically do what you want with Terraform? Sure. But eventually you want more features, and Make just starts to suck at them.

The shell script is really the simplest you can get to adding useful features around the Terraform command line.

You can also use `terraformsh` with a Makefile.
