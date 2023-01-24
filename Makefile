# Makefile for creating multi-arch images
#

# 1st item is default, so 'make' with no arguments shows help
## help: show this help message
help:
	@echo "Usage: \n"
	@sed -n 's/^##//p' ${MAKEFILE_LIST} | column -t -s ':' | sed -e 's/^/ /' | sort

# Default to a development docker path (we do this so that we don't accidentally change
# production 'docker-prod' packages when running on a developer mac)
ENV ?= docker-dev
GCP_PROJECT ?= multi-arch-docker
DOCKER_REPO = us-docker.pkg.dev/$(GCP_PROJECT)/$(ENV)
CACHE_ROOT = $(DOCKER_REPO)/cache

# define docker to run using BUILDKIT features
DOCKER = DOCKER_BUILDKIT=1 docker

# Run 'docker buildx' normally (on builds that don't approach an hour)
DOCKER_BUILDX_NORMAL = $(DOCKER) buildx

# Run 'docker buildx' via our special script to deal with GCP Cloud Build timeouts on long builds
DOCKER_BUILDX_SPLIT = ./docker-buildx.sh

# If DRYRUN set, just echo docker commands
ifdef DRYRUN
DOCKER := echo "[dry-run] $(DOCKER)"
DOCKER_BUILDX_SPLIT := echo "[dry-run] $(DOCKER_BUILDX_SPLIT)"
DOCKER_BUILDX_NORMAL := echo "[dry-run] $(DOCKER_BUILDX_NORMAL)"
endif

# Platforms defaults to amd64 and arm64, but one can override at runtime (e.g., PLATFORMS=linux/amd64 make xxx)
PLATFORMS ?= linux/amd64,linux/arm64

# A unique BUILDER needed in cloud build since we run builds in parallel. Otherwise you get an error like this:
#    ERROR: Error response from daemon: Conflict. The container name "/buildx_buildkit_xxx0" is already in use by
#           container "b7f13...e". You have to remove (or rename) that container to be able to reuse that name.
# Locally, we assume one is only doing builds serially.
BUILDER ?= builder-local

# Name of the arm64 VM instance
ARM64_VM ?= builder-arm64-2cpu

# By default, do not auto start/stop VM in build
AUTO_START_STOP ?= 0

# If set to 1, assumes caller has created 'amd_node' and 'arm_node' Docker contexts, which is
# how we do arm64 builds on remote hardware.  See 'pr.yaml' to see context creation.
MULTI_CONTEXT ?= 0

# TAG_MODIFIER is set by seed-arm64.sh script, and is used to publish the final image under an
# alternate tag (so as not to overwrite the real tag).  We do this to generate new cache entries
# for the arm64 build.
ifdef TAG_MODIFIER
TAG_MODIFIER := -$(TAG_MODIFIER)
endif

# Image used to do cloud builds - version should be kept in sync with pr.yaml
# Note: The alpine/golang versions needs to be in 'thirdparty.txt' so it is vendored.
CLOUDBUILD_ALPINE_VERSION ?= 3.15
CLOUDBUILD_GOLANG_VERSION ?= 1.18-alpine3.15
CLOUDBUILD_NAME = cloud-build:alpine$(CLOUDBUILD_ALPINE_VERSION)
CLOUDBUILD_TAG = $(DOCKER_REPO)/$(CLOUDBUILD_NAME)

# Versions we are building
ALPINE_VERSION ?= 3.15
GO_VERSION ?= 1.18

# Runtime image
RUNTIME_NAME = runtime:$(ALPINE_VERSION)
RUNTIME_TAG = $(DOCKER_REPO)/$(RUNTIME_NAME)$(TAG_MODIFIER)
RUNTIME_CACHE_TAG = $(CACHE_ROOT)/$(RUNTIME_NAME)

# Build image
BUILD_NAME = golang-build:$(GO_VERSION)
BUILD_TAG = $(DOCKER_REPO)/$(BUILD_NAME)$(TAG_MODIFIER)
BUILD_CACHE_TAG = $(CACHE_ROOT)/$(BUILD_NAME)

# Image for odb
# Note: The debian version needs to be in 'thirdparty.txt' so it is vendored.
DEBIAN_VERSION = 11-slim
ODB_VERSION := 2.5.0-b.23
ODB_NAME = odb:${ODB_VERSION}
ODB_TAG = $(DOCKER_REPO)/$(ODB_NAME)$(TAG_MODIFIER)
ODB_CACHE_TAG = $(CACHE_ROOT)/$(ODB_NAME)

## info: print info about build environment
info:
	@echo "Environment is $(ENV)"
	@echo "  DOCKER_REPO=$(DOCKER_REPO)"
	@echo "  PLATFORMS=$(PLATFORMS)"
	@echo "  MULTI_CONTEXT=$(MULTI_CONTEXT)"
	@echo "  TAG_MODIFIER=$(TAG_MODIFIER)"

# determine GOPATH, default to ${GOPATH} if 'go' not installed
GOPATH := $(shell go env GOPATH 2>/dev/null || echo ${GOPATH})

# Auto-install crane tool if not already installed
$(GOPATH)/bin/crane:
	@echo "'$(GOPATH)/bin/crane' not found, attempting to install..."
	go install github.com/google/go-containerregistry/cmd/crane@latest

## thirdparty: copy thirdparty images from official sources to our artifact registry
thirdparty: $(GOPATH)/bin/crane
	ENV=$(ENV) PATH=$(GOPATH)/bin:${PATH} ./thirdparty.sh

## build-publish-cloud-builder: build + push the image used in GCP cloud builds (see _CLOUDBUILD_IMAGE in pr.yaml)
# Note: since this is only really used inside of GCP, a multi-arch image isn't necessary here, and we build for amd64
build-publish-cloud-builder:
	$(DOCKER) build --file Dockerfile-cloud-builder --pull \
		--platform linux/amd64 \
		--build-arg DOCKER_REPO=$(DOCKER_REPO) \
		--build-arg CLOUDBUILD_ALPINE_VERSION=$(CLOUDBUILD_ALPINE_VERSION) \
		--build-arg CLOUDBUILD_GOLANG_VERSION=$(CLOUDBUILD_GOLANG_VERSION) \
		--tag $(CLOUDBUILD_TAG) .
	$(DOCKER) push $(CLOUDBUILD_TAG)

## build-build: build build image using local architecture (mostly used when developing this image)
build-build:
	@echo '=> Building $(BUILD_TAG)...'
	$(DOCKER) build --file Dockerfile-build \
		--build-arg DOCKER_REPO=$(DOCKER_REPO) \
		--build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--pull --tag $(BUILD_TAG) .

## build-runtime: build runtime image using local architecture (mostly used when developing this image)
build-runtime:
	@echo '=> Building $(RUNTIME_TAG)...'
	$(DOCKER) build --file Dockerfile-runtime \
		--build-arg DOCKER_REPO=$(DOCKER_REPO) \
		--build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
		--pull --tag $(RUNTIME_TAG) .

## build-odb: build odb image using local architecture (mostly used when developing this image)
build-odb:
	@echo '=> Building $(ODB_TAG)...'
	$(DOCKER) build --file Dockerfile-odb \
		--build-arg DOCKER_REPO=$(DOCKER_REPO) \
		--build-arg DEBIAN_VERSION=$(DEBIAN_VERSION) \
		--build-arg ODB_VERSION=$(ODB_VERSION) \
		--pull --tag $(ODB_TAG) .

# common setup for buildx tasks.  If MULTI_CONTEXT=1, this assumes 'amd_node' and 'arm_node' contexts exist.
buildx-setup:
	@echo "Setting up buildx, MULTI_CONTEXT=$(MULTI_CONTEXT).  Current builders:"
	$(DOCKER_BUILDX_NORMAL) ls || true
	@if ! $(DOCKER_BUILDX_NORMAL) inspect --builder $(BUILDER) > /dev/null 2>&1; then \
  		if [ "$(MULTI_CONTEXT)" = "1" ]; then \
  			echo "Creating new multi-context builder '$(BUILDER)'"; \
  		    $(DOCKER_BUILDX_NORMAL) create --use --name $(BUILDER) --platform linux/amd64 amd_node; \
            $(DOCKER_BUILDX_NORMAL) create --append --name $(BUILDER) --platform linux/arm64 arm_node; \
  		else \
  			echo "Creating new builder '$(BUILDER)'"; \
  			$(DOCKER_BUILDX_NORMAL) create --name $(BUILDER); \
		fi \
	else \
		echo "Using existing builder $(BUILDER)"; \
	fi

## buildx-publish-build: build and publish the build multi-architecture base image (amd64|arm64)
buildx-publish-build: buildx-setup
	@echo '=> Build and publish multi-arch image $(BUILD_TAG)...'
	$(DOCKER_BUILDX_NORMAL) build --file Dockerfile-build \
		--platform $(PLATFORMS) \
		--builder $(BUILDER) \
		--progress plain \
		--build-arg DOCKER_REPO=$(DOCKER_REPO) \
		--build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
		--build-arg GO_VERSION=$(GO_VERSION) \
		--cache-from type=registry,ref=$(BUILD_CACHE_TAG) \
		--cache-to type=registry,ref=$(BUILD_CACHE_TAG),mode=max \
		--pull --push --tag $(BUILD_TAG) .

## buildx-publish-runtime: build and publish a multi-architecture runtime image (amd64|arm64)
buildx-publish-runtime: buildx-setup
	@echo '=> Build and publish multi-arch image $(RUNTIME_TAG)...'
	$(DOCKER_BUILDX_NORMAL) build --file Dockerfile-runtime \
		--platform $(PLATFORMS) \
		--builder $(BUILDER) \
		--progress plain \
		--build-arg DOCKER_REPO=$(DOCKER_REPO) \
		--build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
		--cache-from type=registry,ref=$(RUNTIME_CACHE_TAG) \
		--cache-to type=registry,ref=$(RUNTIME_CACHE_TAG),mode=max \
		--pull --push --tag $(RUNTIME_TAG) .

## buildx-publish-odb: build and publish a multi-architecture odb image (amd64|arm64)
ODB_BUILD_CACHE_TAG = $(ODB_CACHE_TAG)-as-build-stage
buildx-publish-odb: buildx-setup
	@echo '=> Building odb multi-arch image $(ODB_TAG)...'
	$(DOCKER_BUILDX_SPLIT) build --file Dockerfile-odb \
		--platform $(PLATFORMS) \
		--builder $(BUILDER) \
		--progress plain \
		--build-arg DOCKER_REPO=$(DOCKER_REPO) \
		--build-arg DEBIAN_VERSION=$(DEBIAN_VERSION) \
		--build-arg ODB_VERSION=$(ODB_VERSION) \
		--cache-from type=registry,ref=$(ODB_BUILD_CACHE_TAG) \
		--cache-from type=registry,ref=$(ODB_CACHE_TAG) \
		--cache-to type=registry,ref=$(ODB_CACHE_TAG),mode=max \
		--pull --push --tag $(ODB_TAG) .

## start-vm: start the VM
start-vm:
	gcloud compute instances start $(ARM64_VM) --project $(GCP_PROJECT) --zone us-central1-a

## stop-vm: stop the VM
stop-vm:
	gcloud compute instances stop $(ARM64_VM) --project $(GCP_PROJECT) --zone us-central1-a

## ssh-tunnel: setup ssh-tunnel to remote arm64 VM
ssh-tunnel:
	gcloud compute ssh --project $(GCP_PROJECT) --zone us-central1-a $(ARM64_VM) \
		--tunnel-through-iap -- -L 127.0.0.1:2375:0.0.0.0:2375 -N -f

## pull-runtime: pull runtime image locally (do after doing a 'buildx-publish-runtime' to get the version for local platform)
pull-runtime:
	$(DOCKER) pull $(RUNTIME_TAG)

## pull-build: pull build image locally (do after doing a 'buildx-publish-build' to get the version for local platform)
pull-build:
	$(DOCKER) pull $(BUILD_TAG)

## pull-odb: pull odb image locally (do after doing a 'buildx-publish-odb' to get the version for local platform)
pull-odb:
	$(DOCKER) pull $(ODB_TAG)

## seed-arm64-dry-run: dry-run of seed docker with 'arm64' build (to see what commands will be run)
seed-arm64-dry-run:
	ENV=$(ENV) ./seed-arm64.sh --dry-run

## seed-arm64: seed docker with 'arm64' build
seed-arm64:
	ENV=$(ENV) ./seed-arm64.sh

## cloud-build: run cloud build
cloud-build:
	gcloud builds submit --project=$(GCP_PROJECT) --region=global --config cloudbuild/pr.yaml \
 		--substitutions=_ENV=$(ENV),_CLOUDBUILD_IMAGE=$(CLOUDBUILD_TAG),_AUTO_START_STOP=$(AUTO_START_STOP) \
		.

## clean: remove local copies of runtime, build and ODB_validator images
clean:
	$(DOCKER) rmi $(RUNTIME_TAG)
	$(DOCKER) rmi $(BUILD_TAG)
	$(DOCKER) rmi $(ODB_TAG)

## prune: clean up the local cache specified by $(BUILDER)
prune:
	$(DOCKER_BUILDX_NORMAL) prune --builder $(BUILDER) --all --force

## buildx-ls: list all buildx builders
buildx-ls:
	$(DOCKER_BUILDX_NORMAL) ls
