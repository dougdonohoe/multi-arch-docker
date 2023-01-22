#!/usr/bin/env bash
#
# There is a bug that manifests itself when a 'docker buildx' is run in GCP Cloud Build.
# Builds that run longer than an hour experience an error like this when trying to push/pull
# from artifact registry:
#
#   ERROR: failed to authorize: failed to fetch oauth token: unexpected status: 401 Unauthorized
#
# This script takes what a normal 'docker buildx' command would be and splits it up into three steps
# when in a cloud build.  First, it does a build without the '--push' and the '--cache-to'. This does the build
# which caches the results locally in the builder, but not at the remote artifactory cache.  Then, it stops
# the builder (this is a crucial step as the auth tokens seem to be generated when the builder starts).
# Finally, it does the same build again, but with all options.  This build should be very quick as everything
# is already cached locally.  The cache and final image are sent to artifact registry.
#

# Exit on error
set -e
set -o pipefail

# define docker to run using BUILDKIT features
DOCKER="DOCKER_BUILDKIT=1 docker buildx"

# Get arguments
ARGS=$*
PART1=$(echo $ARGS | sed -e 's/--push //' | sed -e 's/--cache-to [^ ]* //')
BUILDER=$(echo $ARGS | sed -e 's/.*--builder //' | sed -e 's/ .*//')

# BUILDER_OUTPUT is defined in GCP Cloud Build (if not defined, we are running
# locally, so just do a normal build)
if [[ -n "${BUILDER_OUTPUT}" ]]; then
  # Part 1
  echo
  echo "[DOCKER-BUILDX] Doing build w/out --push/--cache-to: $DOCKER $PART1"
  eval "$DOCKER $PART1"

  # Stop builder
  echo
  echo "[DOCKER-BUILDX] Stopping builder '$BUILDER'"
  eval "$DOCKER stop ${BUILDER}"
fi

# Original command
echo
echo "[DOCKER-BUILDX] Doing full build: $DOCKER $ARGS"
eval "$DOCKER $ARGS"
