#!/usr/bin/env sh
# test.sh - minimal script testing 'framework'
# Copyright (C) 2020-2021  Peter Willis

[ "${DEBUG:-0}" = "1" ] && set -x
set -u

### How this thing works:
###  1. Create some shell scripts in tests/ directory, filename ending with '.t'
###  2. Define some functions ('_t_NAME') in that shell script
###     Put the space-separated NAMEs of the functions in $ext_tests
###     Make each function end with 'true' or 'false', not 'exit'
###  3. Run `./test.sh tests/*.t`


# Define some common tests here

#_t_something () {
#}


# Don't modify anything after here

### _main() - run the tests
### Arguments:
###     TESTPATH        -   A file path ending with '.t'
_main () {
    _fail=0 _pass=0 _failedtests=""
    testsh_pwd="$(pwd)"

    for i in "$@" ; do

        cd "$testsh_pwd"

        # The following variables should be used by *.t scripts
        base_name="$(basename "$i" .t)"     ### So you don't need ${BASH_SOURCE[0]}
        tmp="$(mktemp -d)"                  ### Copy your test files into here

        . "$i" # load the test script into this shell

        # Now we should have a variable $ext_tests set by the test script.
        # The value is a string of space-separated names of '_t_SOMETHING' functions to run.
        fail=0 pass=0
        for t in $ext_tests ; do
            if ! _t_$t ; then
                echo "$0: $base_name: Test $t failed"
                fail=$(($fail+1))
                _failedtests="$_failedtests $base_name:$t"
            else
                echo "$0: $base_name: Test $t succeeded"
                pass=$(($pass+1))
            fi
        done

        rm -rf "$tmp"
        [ $fail -gt 0 ] && echo "$0: $base_name: Failed $fail tests" && _fail="$(($_fail+$fail))"
        _pass=$(($_pass+$pass))

    done
}

_main "$@"
echo "$0: Passed $_pass tests"
if [ $_fail -gt 0 ] ; then
    echo "$0: Failed $_fail tests: $_failedtests"
    exit 1
fi
