#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

# Detect terraform version (major + minor)
TF_VER_FULL=$( terraform --version | grep '^Terraform v' | cut -d 'v' -f 2 )
TF_VER_MAJOR=$( echo "$TF_VER_FULL" | awk -F '.' '{print $1}' )
TF_VER_MINOR=$( echo "$TF_VER_FULL" | awk -F '.' '{print $2}' )

# For Terraform < 0.12, the Terraform plugin declaration is different
if [ $TF_VER_MAJOR -eq 0 ] && [ $TF_VER_MINOR -lt 12 ]; then
    TF_VER="pre-0.12"
else
    TF_VER="post-0.12"
fi

echo "Terraform Version: $TF_VER_FULL ($TF_VER)"
