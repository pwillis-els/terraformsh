#!/usr/bin/env bash
# find_cmds.sh - Really ugly code to recursively look for terraform commands and sub-commands
# Copyright (C) 2021  Peter Willis
[ "${DEBUG:-0}" = "1" ] && set -x

_join_by () { local d=${1-} f=${2-}; if shift 2; then printf %s "$f" "${@/#/$d}"; fi; } ;

_find_cmds () {
    CMDS=$(terraform "$@" --help 2>/dev/null | grep -A999 '^Common\|^Main\|^All\|^Subcommands' | grep -v '^Common\|^Main\|^All\|^Subcommands\|^$' | while read L ; do [ $(expr "$L" : "Global options") -ne 0 ] && break; echo "$L" ; done | awk '{print $1}' | grep -e "^[a-z0-9]\+")

    [ -z "$CMDS" ] && return 0

    if [ $# -gt 0 ] ; then
        str="CMDS_$(_join_by "_" "$@" | tr -cd 'a-zA-Z0-9')" # sanitize
        eval "declare -a $str=();"
    fi

    declare -a cmds=($CMDS)
    for cmd in $CMDS ; do
        if [ $# -gt 0 ] ; then
            eval "$str+=($cmd)"
        fi
        _find_cmds "$@" "$cmd"
    done

    eval "size=\${#$str[@]}"
    if [ $size -gt 0 ] ; then
        eval "echo \"declare -a TF_\$str=(\${$str[*]})\""
    fi
}

_find_cmds
