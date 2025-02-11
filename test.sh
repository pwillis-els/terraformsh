#!/usr/bin/env sh
# test.sh - minimal script testing 'framework'
# Copyright (C) 2020-2021  Peter Willis

[ "${DEBUG:-0}" = "1" ] && set -x
set -u

### How this thing works:
###  1. Create some shell scripts in tests/ directory, filename ending with '.t'
###  2. Define some functions ('_t_NAME') in that shell script
###     a. Put the space-separated NAMEs in $ext_tests
###     b. Register test pass/fail with 'return 0' / 'return 1'
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

        echo "$0: Running test '$base_name' ..." 1>&2

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

        echo "$0: Finished test '$base_name'" 1>&2

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
