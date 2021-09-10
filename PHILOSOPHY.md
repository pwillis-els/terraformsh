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

But the thing is... Terragrunt is *Advanced*. It has its own dialect of a Domain-Specific Language. It also parses Hashicorp Configuration Language. It can generate Terraform code, look up dependencies, etc. A lot of fancy stuff. And that's *cool*... but it leads to more complexity, when what we want is simplicity.

Is there a way to get the benefits we're looking for (DRY / easier to manage code, easier to run commands) without the added complexity?

---

## Keep It Simple, Stupid

Terraform can be wrestled to do what we want without added complexity. Terraformsh doesn't need to parse HCL or generate it, track dependencies, etc. All we need to do is organize our Terraform code the right way, and then use a few handy shortcuts to call Terraform in common ways.

`terraformsh` is a Bash script. It runs regular-old Terraform commands for you and assumes certain things you probably want. It also allows you to override its assumptions so you can force it to behave the way you want. This way it fits into whatever pattern you use to run Terraform, but makes it slightly easier by default.

So, how does it do all that / what does it do?

### 1. Passing multiple command-line options
 - Terraform lets you pass the same option multiple times. This lets you pass many configuration files or options to a single command. You can keep configuration files spread across a filesystem hierarchy and re-use the ones that apply to a particular Terraform module. This simple pattern lets you keep both your modules and configuration DRY, without needing to pass environment variables or auto-generate files. This makes `terraform apply` more immutable, idempotent, and DRY.

### 2. Running commands for you
 - Terraform's environment is stateful. Each Terraform command expects certain state to already exist; sometimes on the local filesystem, sometimes remotely. Before you run `terraform plan` you have to run `terraform init` (among other things). **Terraformsh** can make running commands like `terraform plan` easier by automatically running `terraform init` first. This happens for any command you give, as needed.

### 3. Pre-configured complex behavior
 - In order to pass in multiple configuration files, or run multiple commands for you, we can load a simple configuration file. This file can determine where to find configuration files, what commands to run (or not run), etc. By automatically loading these configs (or if you pass them explicitly) we can simplify all the steps of running Terraform down to running a single command in a single directory.

### 4. Avoiding common problems
 - Ever changed your version of Terraform, or moved some files around, and tried to run Terraform again? Old state files, broken module symlinks, and other files can cause Terraform to die unexpectedly. **Terraformsh** can automatically clean up these files.

### 5. Easier troubleshooting
 - Ever run into an unexpected problem and needed to dig into it with custom Terraform commands? A `terraformsh shell` command will prepare your local state and drop you into a shell to let you deal with the issue manually. You can also set a `DEBUG=1` environment variable to get more output from `terraformsh`.

### 6. Bootstrapping remote state
 - Ever need to start new remote state but you need to create a DynamoDB table and S3 bucket and do the `terraform init -reconfigure -force-copy` jig? **Terraformsh** has a function for all of that.

### 7. Run commands from any directory
 - Don't want to have to 'cd' into a root module directory just to run Terraform there? The `-C` option does it for you.

### 8. Use good conventions
 - Don't want to remember to use `terraform plan -out=foo.plan` and `terraform apply foo.plan`? **Terraformsh** does it automatically (unless you disable it). Same for `terraform plan -destroy -out=destroy.plan` and `terraform apply destroy.plan`, so you can't accidentally destroy your infrastructure.

### 9. Pass in arbitary Terraform options
 - So you have a weird exception where you want to pass `-target=RESOURCE` to your `terraform plan`. No problem! Just pass in the normal Terraform options after the `plan` command, and `terraformsh` will pass the options to `terraform plan`.

### 10. It's Just a Shell Script
 - It's just a single Bash script. If it doesn't do what you want, if it breaks, whatever, you can change it. No need to lean Go programming or invest lots of time in testing. Less functionality means less potential bugs.

The end result should be the simplest possible way to make it easier to run Terraform, both in automation, and manually, while keeping code and configs DRY.

---

## What about a Makefile?

I did create a Makefile wrapper for Terraform. And then a shell script and Makefile. And then finally, just a shell script. Makefiles are not really suitable as wrappers, as they are more like build specifications. You can make Terraform do what you want, but after a while you want more and it gets annoying in Make.

You can use `terraformsh` with a Makefile.
