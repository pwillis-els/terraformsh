#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

_t_apply_no_tfvars () {
    pwd

    rm -rf "$tmp"/local-file-hello-world.tfd
    cp -a "$testsh_pwd/tests/local-file-hello-world.tfd" "$tmp/"
    cd "$tmp"/local-file-hello-world.tfd

    if      $testsh_pwd/terraformsh plan apply
    then

        if [ ! "$(cat foo.bar.txt)" = "foo:default:bar" ] ; then
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

ext_tests="apply_no_tfvars"
