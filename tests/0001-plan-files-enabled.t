#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

# Detect terraform version (major + minor)
TF_VER_FULL=$( terraform --version | grep '^Terraform v' | cut -d 'v' -f 2 )
TF_VER_MAJOR=$( echo "$TF_VER_FULL" | awk -F '.' '{print $1}' )
TF_VER_MINOR=$( echo "$TF_VER_FULL" | awk -F '.' '{print $2}' )

# For Terraform < 0.12, the Terraform plugin declaration is different
if [ $TF_VER_MAJOR -eq 0 ] && [ $TF_VER_MINOR -lt 12 ]; then
    TF_VER="pre-0.12"
else
    TF_VER="post-0.12"
fi

echo "Terraform Version: $TF_VER_FULL ($TF_VER)"

# Test that plan files show up
_t_plan_files_enabled () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd" "$tmp/"
    # Optionally delete the null-provider tf file that we don't need
    if [ $TF_VER = "pre-0.12" ]; then
        echo "Using $tmp/null-resource-hello-world.tfd/provider-for-pre-0.12.tf"
    else
        echo "Deleting $tmp/null-resource-hello-world.tfd/provider-for-pre-0.12.tf (not needed)"
        rm -f "$tmp/null-resource-hello-world.tfd/provider-for-pre-0.12.tf"
    fi
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
    fi
}

# Test that plan files show up when we use CD_DIR= option
_t_plan_files_enabled_cd_dir () {
    pwd
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd" "$tmp/"
    # Optionally delete the null-provider tf file that we don't need
    if [ $TF_VER = "pre-0.12" ]; then
        echo "Using $tmp/null-resource-hello-world.tfd/provider-for-pre-0.12.tf"
    else
        echo "Deleting $tmp/null-resource-hello-world.tfd/provider-for-pre-0.12.tf (not needed)"
        rm -f "$tmp/null-resource-hello-world.tfd/provider-for-pre-0.12.tf"
    fi
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
    fi
}

ext_tests="plan_files_enabled plan_files_enabled_cd_dir"
