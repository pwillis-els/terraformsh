#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

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
        echo "$output" | grep -q -- "terraform.sh.tfvars" || return 1
        echo "$output" | grep -q -- "-lock=false" || return 1
        echo "$output" | grep -q -- "tofu.sh.tfvars" && return 1
        echo "$output" | grep -q -- "-refresh=false" && return 1
    else
        echo "$output" | grep -q -- "terraform.sh.tfvars" || return 1
        echo "$output" | grep -q -- "tofu.sh.tfvars" || return 1
        echo "$output" | grep -q -- "-lock=false" || return 1
        echo "$output" | grep -q -- "-refresh=false" || return 1
    fi
}

ext_tests="autoloads_tool_tfvars_and_confs"
