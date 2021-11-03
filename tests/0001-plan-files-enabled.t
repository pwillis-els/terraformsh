#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

# Test that plan files show up
_t_plan_files_enabled () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tf" "$tmp/"
    cd "$tmp"/null-resource-hello-world.tf
    if      $testsh_pwd/terraformsh plan
    then

        TERRAFORM_PWD="$(pwd)"
        TERRAFORM_MODULE_PWD="$TERRAFORM_PWD"

        # The current method of calculating plan file names (copy-paste from terraformsh):
        TF_DD_UNIQUE_NAME="$(printf "%s\n%s\n" "$TERRAFORM_PWD" "$TERRAFORM_MODULE_PWD" | md5sum - | awk '{print $1}' | cut -b 1-10)"

        echo "TF_DD_UNIQUE_NAME=$TF_DD_UNIQUE_NAME"

        if [ ! -e "tf.$TF_DD_UNIQUE_NAME.plan" ] ; then
            echo "$base_name: ERROR: No plan file found!"
            ls -la
            return 1
        fi
    fi
}

ext_tests="plan_files_enabled"
