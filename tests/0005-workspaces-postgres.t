#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

# Load postgres backend functions/variables
. "./0003-postgres-backend.t"

#ext_tests="workspaces_postgres"
