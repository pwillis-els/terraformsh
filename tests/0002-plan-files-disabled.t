#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

# Test that plan files don't show up
_t_plan_files_disabled () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd" "$tmp/"
    cd "$tmp"/null-resource-hello-world.tfd
    if      $testsh_pwd/terraformsh -P plan
    then

        TERRAFORM_PWD="$(pwd)"
        TERRAFORM_MODULE_PWD="$TERRAFORM_PWD"

        # The current method of calculating plan file names (copy-paste from terraformsh):
        TF_DD_UNIQUE_NAME="$(printf "%s\n%s\n" "$TERRAFORM_PWD" "$TERRAFORM_MODULE_PWD" | md5sum - | awk '{print $1}' | cut -b 1-10)"

        echo "TF_DD_UNIQUE_NAME=$TF_DD_UNIQUE_NAME"

        if [ -e "tf.$TF_DD_UNIQUE_NAME.plan" ] ; then
            echo "$base_name: ERROR: Plan file found but none expected!"
            ls -la
            return 1
        fi
    fi
}

# Test that plan files don't show up when CD_DIR= is used
_t_plan_files_disabled_cd_dir () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd" "$tmp/"
    mkdir -p "$tmp/rundir"
    cd "$tmp"/rundir
    if      $testsh_pwd/terraformsh -c "$tmp/null-resource-hello-world.tfd" -P plan
    then

        TERRAFORM_PWD="$(pwd)"
        TERRAFORM_MODULE_PWD="$tmp/null-resource-hello-world.tfd"

        # The current method of calculating plan file names (copy-paste from terraformsh):
        TF_DD_UNIQUE_NAME="$(printf "%s\n%s\n" "$TERRAFORM_PWD" "$TERRAFORM_MODULE_PWD" | md5sum - | awk '{print $1}' | cut -b 1-10)"

        echo "TF_DD_UNIQUE_NAME=$TF_DD_UNIQUE_NAME"

        if [ -e "tf.$TF_DD_UNIQUE_NAME.plan" ] ; then
            echo "$base_name: ERROR: Plan file found but none expected!"
            ls -la
            return 1
        fi
    fi
}


# Test that plan files don't show up when using destroy.
# 
# This also tests whether 'destroy' works as expected when plan files are disabled:
# namely that it should run a destroy and not an apply.
_t_plan_files_disabled_destroy () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd" "$tmp/"
    cd "$tmp"/null-resource-hello-world.tfd

    set -e

    if     $testsh_pwd/terraformsh -P -E "DESTROY_ARGS+=(-auto-approve)" destroy 2>&1 | tee test.log
    then

        # Check for 'apply'
        if grep 'Apply complete' test.log ; then
            echo "$base_name: ERROR: Ran apply instead of destroy!"
            return 1
        fi

        TERRAFORM_PWD="$(pwd)"
        TERRAFORM_MODULE_PWD="$TERRAFORM_PWD"

        # The current method of calculating plan file names (copy-paste from terraformsh):
        TF_DD_UNIQUE_NAME="$(printf "%s\n%s\n" "$TERRAFORM_PWD" "$TERRAFORM_MODULE_PWD" | md5sum - | awk '{print $1}' | cut -b 1-10)"

        echo "TF_DD_UNIQUE_NAME=$TF_DD_UNIQUE_NAME"

        if [ -e "tf.$TF_DD_UNIQUE_NAME.plan" ] ; then
            echo "$base_name: ERROR: Plan file found but none expected!"
            ls -la
            return 1
        fi
    fi
}

# This tests that plan files don't show up,
# *and* that when using apply, tfvars are passed if you disable
# plan files. Requires use of -auto-approve to pass in CI.
# (if you aren't running in CI, use '-E APPLY_ARGS=()' to remove
#  the -input=false option)
_t_plan_files_disabled_apply_tfvars () {
    pwd

    cp -a "$testsh_pwd/tests/local-file-hello-world.tfd" "$tmp/"

    cd "$tmp"/null-resource-hello-world.tfd

    cat >terraform.sh.tfvars <<EOTFFILE1
insert-value = "(this is from the tfvars file)"
EOTFFILE1

    if      $testsh_pwd/terraformsh -P apply -auto-approve
    then

        TERRAFORM_PWD="$(pwd)"
        TERRAFORM_MODULE_PWD="$TERRAFORM_PWD"

        # The current method of calculating plan file names (copy-paste from terraformsh):
        TF_DD_UNIQUE_NAME="$(printf "%s\n%s\n" "$TERRAFORM_PWD" "$TERRAFORM_MODULE_PWD" | md5sum - | awk '{print $1}' | cut -b 1-10)"

        echo "TF_DD_UNIQUE_NAME=$TF_DD_UNIQUE_NAME"

        if [ -e "tf.$TF_DD_UNIQUE_NAME.plan" ] ; then
            echo "$base_name: ERROR: Plan file found but none expected!"
            ls -la
            return 1
        fi

        if [ ! "$(cat foo.bar.txt)" = "foo:(this is from the tfvars file):bar" ] ; then
            echo "$base_name: ERROR: file contents were not as expected!"
            ls -la
            return 1
        fi
    else
        echo "$base_name: ERROR: terraformsh returned error!"
        ls -la
        return 1
    fi
}

ext_tests="plan_files_disabled plan_files_disabled_cd_dir plan_files_disabled_destroy plan_files_disabled_apply_tfvars"
