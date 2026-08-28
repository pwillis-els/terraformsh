#!/usr/bin/env sh
# shellcheck disable=SC2034,SC2154 # Variables are supplied/consumed by test.sh.
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

_t_inherits_tfvars_from_path_with_spaces () {
    parent="$tmp/parent with space"
    module="$parent/module"
    mkdir -p "$module" || return 1
    printf '%s\n' 'example = "inherited"' > "$parent/terraform.sh.tfvars"
    cd "$module" || return 1

    output="$("$testsh_pwd/terraformsh" -N -D -P plan 2>&1)"
    status=$?
    if [ "$status" -ne 0 ]; then
        echo "$base_name: ERROR: terraformsh returned $status"
        echo "$output"
        return 1
    fi

    expected="-var-file $parent/terraform.sh.tfvars"
    if ! printf '%s\n' "$output" | grep -F -- "$expected" >/dev/null; then
        echo "$base_name: ERROR: inherited tfvars were omitted from a path containing spaces"
        echo "Expected output to contain: $expected"
        echo "$output"
        return 1
    fi
}

ext_tests="inherits_tfvars_from_path_with_spaces"
