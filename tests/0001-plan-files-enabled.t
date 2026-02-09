#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

# Test that plan files show up
_t_plan_files_enabled () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd" "$tmp/"
    _check_and_delete_provider_files "$tmp/null-resource-hello-world.tfd" "$TF_VER"
    cd "$tmp"/null-resource-hello-world.tfd
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
    else
        echo "$base_name: ERROR: terraformsh returned error!"
        ls -la
        return 1
    fi
}

# Test that plan files show up when we use CD_DIR= option
_t_plan_files_enabled_cd_dir () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd" "$tmp/"
    _check_and_delete_provider_files "$tmp/null-resource-hello-world.tfd" "$TF_VER"
    mkdir -p "$tmp/rundir"
    cd "$tmp"/rundir
    if      $testsh_pwd/terraformsh -C "$tmp/null-resource-hello-world.tfd" plan
    then

        TERRAFORM_PWD="$(pwd)"
        TERRAFORM_MODULE_PWD="$tmp/null-resource-hello-world.tfd"

        # The current method of calculating plan file names (copy-paste from terraformsh):
        TF_DD_UNIQUE_NAME="$(printf "%s\n%s\n" "$TERRAFORM_PWD" "$TERRAFORM_MODULE_PWD" | md5sum - | awk '{print $1}' | cut -b 1-10)"

        echo "TF_DD_UNIQUE_NAME=$TF_DD_UNIQUE_NAME"

        if [ ! -e "tf.$TF_DD_UNIQUE_NAME.plan" ] ; then
            echo "$base_name: ERROR: No plan file found!"
            ls -la
            return 1
        fi
    else
        echo "$base_name: ERROR: terraformsh returned error!"
        ls -la "$tmp/null-resource-hello-world.tfd"
        return 1
    fi
}

ext_tests="plan_files_enabled plan_files_enabled_cd_dir"
