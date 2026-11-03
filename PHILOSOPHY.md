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

Terraform is inherently complicated and difficult to use. Whether this is by design or by accident is immaterial; it is how it is, and it's not getting any better.

Many people have written wrappers around Terraform to make it less annoying to use. Terragrunt was one of those efforts, designed to make it easier to support larger and more complex Terraform installations without duplicating code.

But the thing is... Terragrunt is <u>*Advanced*</u>. It has its own dialect of a Domain-Specific Language, based on Hashicorp Configuration Language. It can generate Terraform code, look up dependencies, etc. A lot of fancy stuff. And that's *cool*... but it leads to more complexity, when what we (the users) want is more simplicity.

Is there a way to get the benefits we're looking for (DRY / easier to manage code, easier to run commands) without the added complexity?


## KISS: Keep It Simple, Stupid

It turns out, stock Terraform can be wrestled to do what we want without added complexity. You don't need to parse HCL/generate it, track dependencies, etc. All you need is organize your Terraform code the right way, and use a few handy shortcuts to call Terraform.

A simple Bash script can run Terraform commands for you, assume things you probably want, and allow overriding those assumptions. By being a drop-in replacement for `terraform`, it can fit whatever pattern you use, while making it slightly easier by default.

With this simple approach you can use stock Terraform while getting the benefits the average user is looking for, without added complexity.


## How does it do that?


### 1. Passing multiple command-line options
 - Terraform lets you pass the same option multiple times. This lets you pass many configuration files or options to a single command. You can keep configuration files spread across a filesystem hierarchy and re-use the ones that apply to a particular Terraform module (`-var-file a/foo.txt -var-file b/foo.txt`).
   
   **Terraformsh** uses this in a directory hierarchy, to let you keep configs in certain files and reuse them (`-var-file ../../../foo.tfvars -var-file ../../foo.tfvars -var-file ../foo.tfvars`). This lets you keep both your modules and configuration DRY, without needing to pass environment variables or auto-generate files. This makes `terraform apply` more immutable, idempotent, and DRY.

### 2. Running commands for you
 - Terraform's environment is stateful. Each Terraform command expects certain state to already exist; sometimes on the local filesystem, sometimes remotely. Before you run `terraform plan` you have to first run `terraform init` (among other things).
   
   **Terraformsh** can make running commands like `terraform plan` easier by automatically running `terraform init` first. This happens for any command you give, as needed.

### 3. Pre-configured complex behavior
 - In order to pass in multiple configuration files, or run multiple commands for you, we can load a simple configuration file (`terraformsh.conf`). This file can determine where to find configuration files, what commands to run (or not run), etc.
   
   By automatically loading these configs (or pass them explicitly) we can simplify all the steps of running Terraform down to a single command in a single directory.

### 4. Avoiding common problems
 - Ever changed your version of Terraform, or moved some files around, and tried to run Terraform again?<br /> Or have old state files, broken module symlinks, and other files can cause Terraform to die unexpectedly?
   
   **Terraformsh** can automatically clean up these files.

### 5. Easier troubleshooting
 - Ever run into an unexpected problem and needed to dig into it with custom Terraform commands?
   
   A `terraformsh shell` command prepares your local state and drops you into a shell to let you deal with the issue manually. You can also set a `DEBUG=1` environment variable to get more output from `terraformsh`.

### 6. Running multiple commands in order

 - Ever want to run multiple Terraform commands one after another, with specific options for each?
   
   **Terraformsh** can accept multiple commands and options in a single line, execute them in order, and stop on failure.

### 7. Run commands from any directory
 - Don't want to have to 'cd' into a root module directory just to run Terraform there? The `-C` option does it for you. (This used to not be supported by Terraform, but an option was later added)

### 8. Use good conventions
 - Don't want to remember to use `terraform plan -out=foo.plan` and `terraform apply foo.plan`? **Terraformsh** does it automatically (unless you disable it). Same for `terraform plan -destroy -out=destroy.plan` and `terraform apply destroy.plan`, so you can't accidentally destroy your infrastructure.

### 9. Dry-run mode
 - Want to see all the exact commands that **Terraformsh** would run, without running them? `terraformsh -N` is the answer.

### 10. It's Just a Shell Script
 - It's just a single Bash script. If it doesn't do what you want, if it breaks, whatever, you can change it. No need to lean Go programming or invest lots of time in testing. Less functionality means less potential bugs.

The end result should be the simplest possible way to make it easier to run Terraform, both in automation, and manually, while keeping code and configs DRY.

---

## What about a Makefile?

I did create a Makefile wrapper for Terraform. And then a shell script and Makefile. And then finally, just a shell script. Makefiles are not really suitable as wrappers, as they are more like build specifications. You can make Terraform do what you want, but after a while you want more and it gets annoying in Make.

You can use `terraformsh` with a Makefile.
