#!/usr/bin/env bash
#
# Script to copy thirdparty images from their origins.  Uses the 'thirdparty.txt' to
# define images and versions.  Script only updates if manifests have changed.
#

set -e -o pipefail

DST_IMAGE_ROOT=us-docker.pkg.dev/${GCP_PROJECT:-multi-arch-docker}/${ENV:-docker-dev}
SCRIPT_DIR=$(dirname $(cd ${0%/*} && echo $PWD/${0##*/}))
THIRDPARTY_CONFIG="${SCRIPT_DIR}/thirdparty.txt"

# TEMP DIR, cleanup on exit
TMPDIR="$(mktemp -d)"
trap 'rm -rf -- "$TMPDIR"' EXIT

function get_images() {
  grep -v "^#" "${THIRDPARTY_CONFIG}" | grep -v "^[\w]*$" | sed -e 's/:.*//'
}

function get_versions() {
  local image=$1
  grep "^$image" "${THIRDPARTY_CONFIG}" | sed -e 's/.*: *//'
}

function get_manifest() {
  local image=$1
  local file=$2
  local missing_ok=$3
  if [[ "${missing_ok}" == "yes" ]]; then
    set +e
  fi
  crane manifest "${image}" > "${file}" 2>&1
  if [[ "${missing_ok}" == "yes" ]]; then
    set -e
  fi
}

# Copy an image if it doesn't exist or the manifests don't match
function copy() {
  local image=$1
  local version=$2
  local src_image_version="${image}:${version}"
  local dst_image_version="${DST_IMAGE_ROOT}/thirdparty/${src_image_version#*/}"
  local src_manifest="${TMPDIR}/src.txt"
  local dst_manifest="${TMPDIR}/dst.txt"

  # get src manifest - don't allow error (if it doesn't exist, probably an error in config file)
  get_manifest "$src_image_version" "${src_manifest}" no

  # get dst manifest - okay if error since it may not exist yet in Artifact Registry
  get_manifest "$dst_image_version" "${dst_manifest}" yes

  # Calculate diff, if not same, do the copy
  diff=$(diff -q "${src_manifest}" "${dst_manifest}" > /dev/null 2>&1; echo $?)
  if [[ "${diff}" == "0" ]]; then
    echo "  $version:  Image ${dst_image_version} is up to date."
  else
    echo "  $version:  Updating via 'crane ${src_image_version} to ${dst_image_version}'..."
    crane copy "${src_image_version}" "${dst_image_version}" 2>&1 | sed -e 's/^/    /'
  fi
}

# Loop over all images
function process_images() {
  for image in $(get_images); do
    echo "Processing ${image}..."
    for version in $(get_versions "${image}"); do
      copy "${image}" "${version}"
    done
    echo
  done
  echo "Done."
}

# Run script
process_images
