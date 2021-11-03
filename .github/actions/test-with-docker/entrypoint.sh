#!/usr/bin/env sh
export DEBUG="${DEBUG:-${1:-0}}"
[ "${DEBUG:-0}" = "1" ] && set -x
set -eux
make
