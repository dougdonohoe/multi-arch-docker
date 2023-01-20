#!/usr/bin/env bash
#
# GCP Cloud Build does not have builders with ARM chips, so building 'linux/arm64' images
# take a very long time (due to the QEMU emulation).  It takes over an hour which
# triggers this failure:
#
#   #32 ERROR: failed to authorize: failed to fetch oauth token: unexpected status: 401 Unauthorized
#
# We found a workaround (explained here: https://github.com/dougdonohoe/build-timeout), which allows
# builds to succeed, but they still take a while.
#
# The purpose of this script is to run a build on an M1 Mac (i.e., one with Apple Silicon) or arm64 Linux VM
#  and take advantage of Docker caching to cache the results.  A subsequent linux/arm64 build in GCP should
# utilize these cached results.  This script extracts and runs the same docker build steps specified in the
# cloudbuild/pr.yaml file (to avoid having to duplicate steps in that file here).
#
# The original intent is that a developer making changes to this repo should run this script from the local
# branch (after the PR is approved) but prior to PR merging.  By doing so, the cache is updated, and then when
# the PR is merged, which kicks off the cloud build, the ARM building steps should use the newly updated cache.
# In development, this eliminates the need to sometimes multiple hours for the build to complete.
#
# The subsequent intent is to use this from an arm64 VM, via cron, so the arm64 half of the build can be seeded
# before the 4am Sunday scheduled build.
#
# Usage: ENV=name seed-arm64.sh [--dry-run]
#    --dry-run: echos docker commands instead of running them so you can sanity check
#    ENV=name: define the environment (e.g., 'docker-prod' or 'docker-dev' ... in normal usage this is set via the Makefile)
#

# exit on any error
set -e

function usage() {
  echo "$@"
  echo
  echo "Usage: ENV=name seed-arm64.sh [--dry-run]"
  exit 1
}

# Parse params
while [[ $# -gt 0 ]]; do
  key="$1"
  case ${key} in
  --dry-run)
    export DRYRUN="true"
    ;;
  *)
    usage "ERROR: Unknown parameter '${key}'"
    ;;
  esac
  shift
done

# Ask user to confirm ok to proceed
function confirm_yes() {
  echo -n "Are you sure you want to continue? [y/n]: "
  read -r ANSWER

  if [[ "${ANSWER}" != "y" ]]; then
    echo "Aborting..."
    exit 1
  fi
}

# Validate on arm64
MACHINE=$(uname -m)
if [[ "$MACHINE" != "arm64" && "$MACHINE" != "aarch64" ]]; then
  echo "WARNING:  This script is meant to be run on an M1 Mac (arm64) or arm64 Linux VM (aarch64), but this"
  echo "          is a '${MACHINE}' machine.  The build will probably work, but it will take a very very long time."
  echo
  confirm_yes
fi

# validate ENV given
if [[ -z "${ENV}" ]]; then
  usage "ENV" variable not defined
fi
export _ENV="${ENV}"

# TEMP DIR, cleanup on exit
TMPDIR="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR"' EXIT
TMP_SCRIPT="${TMPDIR}/seed.sh"

# change to parent of 'docker-multi' directory
PARENT_DIR=$(dirname $(dirname $(cd ${0%/*} && echo $PWD/${0##*/})))
cd "${PARENT_DIR}"

# We are explicitly setting PLATFORMS, overriding that in the Makefile
export PLATFORMS="linux/arm64"

# We set a TAG_MODIFIER so we do not overwrite the production image tags
export TAG_MODIFIER="arm64-seed"

# Extract build steps from the cloudbuild definition, removing leading spaces, removing BUILDER value,
grep "make -C docker-multi buildx" cloudbuild/pr.yaml | sed -e 's/^ *//' -e 's/BUILDER=[^ ]* //g' > "${TMP_SCRIPT}"

# Confirm with user
echo "About to run this script:"
echo "===================================================================================="
cat "${TMP_SCRIPT}"
echo "===================================================================================="
echo
echo "Using these variables:"
echo "  _ENV=${_ENV}"
echo "  PLATFORMS=${PLATFORMS}"
echo "  TAG_MODIFIER=${TAG_MODIFIER}"
if [[ -n "${DRYRUN}" ]]; then
  echo
  echo "*****************"
  echo "**** DRY-RUN ****"
  echo "*****************"
fi
echo
confirm_yes

# Run the script
source "${TMP_SCRIPT}"