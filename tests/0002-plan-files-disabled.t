#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

# Test that plan files don't show up
_t_plan_files_disabled () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tf"/* "$tmp/"
    cd "$tmp"
    $testsh_pwd/terraformsh -P plan

    TERRAFORM_PWD="$(pwd)"
    TERRAFORM_MODULE_PWD="$TERRAFORM_PWD"

    # The current method of calculating plan file names (copy-paste from terraformsh):
    TF_DD_UNIQUE_NAME="$(printf "%s\n%s\n" "$TERRAFORM_PWD" "$TERRAFORM_MODULE_PWD" | md5sum - | awk '{print $1}' | cut -b 1-10)"

    echo "TF_DD_UNIQUE_NAME=$TF_DD_UNIQUE_NAME"

    if [ -e "tf.$TF_DD_UNIQUE_NAME.plan" ] ; then
        echo "$base_name: ERROR: Plan file found but none expected!"
        ls -la
        false
    fi
}

# Test that plan files don't show up
_t_plan_files_disabled_destroy () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tf"/* "$tmp/"
    cd "$tmp"
    $testsh_pwd/terraformsh -P -E "DESTROY_ARGS+=(-auto-approve)" destroy

    TERRAFORM_PWD="$(pwd)"
    TERRAFORM_MODULE_PWD="$TERRAFORM_PWD"

    # The current method of calculating plan file names (copy-paste from terraformsh):
    TF_DD_UNIQUE_NAME="$(printf "%s\n%s\n" "$TERRAFORM_PWD" "$TERRAFORM_MODULE_PWD" | md5sum - | awk '{print $1}' | cut -b 1-10)"

    echo "TF_DD_UNIQUE_NAME=$TF_DD_UNIQUE_NAME"

    if [ -e "tf.$TF_DD_UNIQUE_NAME.plan" ] ; then
        echo "$base_name: ERROR: Plan file found but none expected!"
        ls -la
        false
    fi
}

ext_tests="plan_files_disabled plan_files_disabled_destroy"
