#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

_fail_with_output () {
    label="$1"
    output="$2"
    echo "$base_name: ERROR: $label"
    echo "$output"
    return 1
}

_t_autoloads_tool_tfvars_and_confs () {
    cp -a "$testsh_pwd/tests/null-resource-hello-world.tfd" "$tmp/"
    _check_and_delete_provider_files "$tmp/null-resource-hello-world.tfd" "$TF_VER"
    cd "$tmp"/null-resource-hello-world.tfd || return 1

    cat > terraform.sh.tfvars <<'EOTFFILE'
example = "terraform"
EOTFFILE
    cat > tofu.sh.tfvars <<'EOTFFILE'
example = "tofu"
EOTFFILE

    cat > terraformsh.conf <<'EOTCONF'
PLAN_ARGS+=("-lock=false")
EOTCONF
    cat > tofush.conf <<'EOTCONF'
PLAN_ARGS+=("-refresh=false")
EOTCONF

    output="$($testsh_pwd/terraformsh -N -D plan 2>&1)"
    if echo "$output" | grep -q -- "+ terraform plan" ; then
        :
    elif echo "$output" | grep -q -- "+ tofu plan" ; then
        :
    else
        echo "$base_name: ERROR: Expected terraform or tofu plan command output."
        return 1
    fi
    has_terraform=0
    has_tofu=0
    command -v terraform >/dev/null 2>&1 && has_terraform=1
    command -v tofu >/dev/null 2>&1 && has_tofu=1
    if [ $has_terraform -eq 1 ] && [ $has_tofu -eq 1 ] ; then
        echo "$output" | grep -q -- "terraform.sh.tfvars" || _fail_with_output "Expected terraform.sh.tfvars in terraformsh output." "$output"
        echo "$output" | grep -q -- "-lock=false" || _fail_with_output "Expected terraformsh.conf args in terraformsh output." "$output"
        echo "$output" | grep -q -- "tofu.sh.tfvars" && _fail_with_output "Unexpected tofu.sh.tfvars in terraformsh output." "$output"
        echo "$output" | grep -q -- "-refresh=false" && _fail_with_output "Unexpected tofush.conf args in terraformsh output." "$output"
        ln -s "$testsh_pwd/terraformsh" "$tmp/tofush"
        tofush_output="$("$tmp/tofush" -N -D plan 2>&1)"
        echo "$tofush_output" | grep -q -- "+ tofu plan" || _fail_with_output "Expected tofu plan in tofush output." "$tofush_output"
        echo "$tofush_output" | grep -q -- "tofu.sh.tfvars" || _fail_with_output "Expected tofu.sh.tfvars in tofush output." "$tofush_output"
        echo "$tofush_output" | grep -q -- "-refresh=false" || _fail_with_output "Expected tofush.conf args in tofush output." "$tofush_output"
        echo "$tofush_output" | grep -q -- "terraform.sh.tfvars" && _fail_with_output "Unexpected terraform.sh.tfvars in tofush output." "$tofush_output"
        echo "$tofush_output" | grep -q -- "-lock=false" && _fail_with_output "Unexpected terraformsh.conf args in tofush output." "$tofush_output"
        ln -s "$testsh_pwd/terraformsh" "$tmp/invalidsh"
        invalid_output="$("$tmp/invalidsh" -N -D plan 2>&1)"
        invalid_status=$?
        if [ $invalid_status -eq 0 ] ; then
            echo "$base_name: ERROR: Expected failure for invalid script name."
            return 1
        fi
        echo "$invalid_output" | grep -q -- "invoke as terraformsh or tofush" || _fail_with_output "Expected invalid script name guidance." "$invalid_output"
    else
        if [ -f terraform.sh.tfvars ] ; then
            echo "$output" | grep -q -- "terraform.sh.tfvars" || _fail_with_output "Expected terraform.sh.tfvars in output." "$output"
        fi
        if [ -f tofu.sh.tfvars ] ; then
            echo "$output" | grep -q -- "tofu.sh.tfvars" || _fail_with_output "Expected tofu.sh.tfvars in output." "$output"
        fi
        if [ -f terraformsh.conf ] ; then
            echo "$output" | grep -q -- "-lock=false" || _fail_with_output "Expected terraformsh.conf args in output." "$output"
        fi
        if [ -f tofush.conf ] ; then
            echo "$output" | grep -q -- "-refresh=false" || _fail_with_output "Expected tofush.conf args in output." "$output"
        fi
    fi
}

ext_tests="autoloads_tool_tfvars_and_confs"
