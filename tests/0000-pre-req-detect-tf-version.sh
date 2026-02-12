#!/usr/bin/env sh
# vim: syntax=sh
[ "${DEBUG:-0}" = "1" ] && set -x
set -u

if [ -n "$( which terraform 2>/dev/null )" ]; then
    TERRAFORM_SHORT_NAME="terraform"
elif [ -n "$( which tofu 2>/dev/null )" ]; then
    TERRAFORM_SHORT_NAME="tofu"
else
    echo "Error: Unable to find terraform or tofu."
    exit 1
fi

# Detect terraform version (major + minor)
TF_VER_OUTPUT=$( $TERRAFORM_SHORT_NAME --version | grep -E '^Terraform v|^OpenTofu v' | head -1 )
TERRAFORM_NICE_NAME=$( echo "$TF_VER_OUTPUT" | awk '{print $1}' ) 
TF_VER_FULL=$( echo "$TF_VER_OUTPUT" | awk '{print $2}' | tr -d 'v' )
TF_VER_MAJOR=$( echo "$TF_VER_FULL" | awk -F '.' '{print $1}' )
TF_VER_MINOR=$( echo "$TF_VER_FULL" | awk -F '.' '{print $2}' )

# For Terraform < 0.12, the Terraform plugin declaration is different
if [ "$TERRAFORM_SHORT_NAME" = "terraform" ]; then
    if [ $TF_VER_MAJOR -eq 0 ] && [ $TF_VER_MINOR -lt 12 ]; then
        TF_VER="pre-0.12"
    else
        TF_VER="post-0.12"
    fi
else
    TF_VER="$TF_VER_MAJOR.$TF_VER_MINOR"
fi

echo "$TERRAFORM_NICE_NAME Version: $TF_VER_FULL ($TF_VER)"
