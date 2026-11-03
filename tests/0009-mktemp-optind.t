#!/usr/bin/env sh
# shellcheck disable=SC2034,SC2154 # Variables are supplied/consumed by test.sh.
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

_t_state_rm_backup_in_module_dir_after_options () {
    module="$tmp/module"
    mkdir -p "$module" || return 1
    printf '%s\n' 'bucket = "example"' > "$module/backend.tfvars"
    cd "$module" || return 1

    output="$("$testsh_pwd/terraformsh" -N -D -b backend.tfvars state rm null_resource.example 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "$base_name: ERROR: terraformsh returned $status"
        echo "$output"
        return 1
    fi

    expected="-backup=$module/backup."
    if ! printf '%s\n' "$output" | grep -F -- "$expected" >/dev/null; then
        echo "$base_name: ERROR: 'state rm' backup was not created in the module directory"
        echo "Expected output to contain: $expected"
        echo "$output"
        return 1
    fi
}

ext_tests="state_rm_backup_in_module_dir_after_options"
