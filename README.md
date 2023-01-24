# multi-arch-docker

This repo demonstrates how to build multi-architecture Docker images using a native
`arm64` VM on Google Cloud Build and `docker buildx`.

It is meant to be fairly complete and practically production-ready way to build
common build infrastructure.  Of course the contents of the `build` and `runtime`
images would need to be enhanced to meet real-world needs.

Hopefully it will be of use to anyone trying to do multi-architecture Docker builds
on GCP.  

If you are on AWS or Azure (or somewhere else), the concepts should be useful
and the only things to figure out are probably around networking access from your
build tool to your dedicated `arm64` VMs.  Docker does allow direct access over `ssh`,
which may be easier than doing the `ssh` tunnel.  Unfortunately, in GCP, the
IAP-based tunneling via `gcloud` was the only option.

## Images

Three images are built to approximate a real-life build need. These images 
support `linux/amd64` and `linux/arm64` architectures:

- `multi-arch-docker/docker-prod/build/runtime:3.15` - Alpine 3.15 runtime image
- `multi-arch-docker/docker-prod/build/golang-build:1.18` - Go 1.18 build image
- `multi-arch-docker/docker-prod/build/odb:2.5.0-b.23` - [odb](https://www.codesynthesis.com/products/odb) tools and library

## Thirdparty Images

Images defined in `thirdparty.txt` are automatically copied to Artifact Registry.  These
multi-arch images are the base images to build images defined in this repo.

## Image Details

All images are multi-architecture images supporting `amd64` and `arm64`.  When an image is pulled, 
Docker automatically pulls the image variant that matches the host system.  In the case of M1 
macs, it will pull the `linux/arm64` variant.

### `multi-arch-docker/docker-prod/build/runtime:3.15`

This image variant is meant to be used as a runtime image which makes it suitable as 
the image to be used for deployments.  It is just a base Alpine image with a few packages 
added on.

### `multi-arch-docker/docker-prod/build/golang-build:1.18`

This image variant is meant to be an example of a build image that might be suitable for:

- building "static" binaries to be copied into the runtime image
- running CI tests

It is, in essence, built upon the vanilla `golang:1.8-alpine3.15` image variant. The image is built 
with additional software packages installed to facilitate compiling Go binaries and running CI tooling.

### `multi-arch-docker/docker-prod/build/odb:2.5.0-b.23`

This image demonstrates building a complex C++ executable and libraries.

## Implementation and Development Notes

### ARM64 Builder

See [ARM64_BUILDER.md](ARM64_BUILDER.md) for details on how to create the dedicated `arm64` Linux VM,
which is used by the Cloud Builder.

### TL;DR

The steps for doing working on a new release of the images are as follows (each command is 
explained in detail below):

While doing development, images are published (by default) to the
[docker-dev](https://console.cloud.google.com/artifacts/docker/multi-arch-docker/us/docker-dev?project=multi-arch-docker)
directory of our Artifact Registry repo.

```shell
gcloud config set project multi-arch-docker
make info
make thirdparty
make build-publish-cloud-builder
make cloud-build
```

For a real-world production release, imagine having a build trigger that runs the `pr.yaml` file
using `_ENV=docker-prod` upon merge to master.  Before merging, take the following steps if
the `Docker-cloud-builder` image changed or doesn't exist yet:

```shell
gcloud config set project multi-arch-docker

# Optional - only needed if source images for cloud-builder haven't been built yet
ENV=docker-prod make thirdparty

# Run this if Dockerfile-cloud-builder updated
ENV=docker-prod make build-publish-cloud-builder
```

### Seeding ARM64

Without a native `arm64` VM, the Cloud Build does the `arm64` part of the build under QEMU emulation on the
`amd64` hardware in Cloud Build.  This is extremely slow, so to speed things one can "seed" the `arm64`
builds by running on an M1 mac.  Absent a dedicated `arm64` VM, these are the steps to take on an M1 
Mac prior to merging a PR:

```bash
# Run this if want to seed the build with 'arm64' images
ENV=docker-prod make thirdparty
ENV=docker-prod make seed-arm64
```

**NOTE**: With the native `arm64` VM, this isn't necessary, but I'm keeping these instructions around 
to demonstrate how "seeding" works (this can be used in as a short term solution if there are problems
with the `arm64` VM).

### Docker Repository

Every action done by the `Makefile` publishes images relative to a root Docker repository path.  The
production repository is
[us-docker.pkg.dev/multi-arch-docker/docker-prod](https://console.cloud.google.com/artifacts/browse/multi-arch-docker/docker-prod?project=multi-arch-docker).

The `ENV` variable determines which repository to use.  If set to `docker-prod`, the production repository 
path is used.  If it is not set, `ENV` defaults to `docker-dev` and this value is appended to the repository 
path.  For example,
[us-docker.pkg.dev/multi-arch-docker/docker-dev](https://console.cloud.google.com/artifacts/docker/multi-arch-docker/us/docker-dev?project=multi-arch-docker).

To create these repositories, or others for testing, use the **+ Create Repository** button and use
these values:

* Name: `docker-dev` or `docker-prod` or `yourname-test`
* Format: `Docker`
* Location type: `Multi-region`
* Region: `us`
* Encryption: `Google-managed encryption key`

Use the `ENV` variable to specify the repo in make commands like this:

```shell
ENV=yourname-test make info
```

### `make help`

This list all available `make` commands.

### `make info`

This steps acts as a sanity check to verify the proper environment variables are being set. 

### `make thirdparty`

This step uses the `crane` tool to copy multi-arch vendor images to our artifact registry 
(a process we call 'vendoring').  This step should be run whenever new versions are added
that introduce new Alpine or Golang versions.

If `crane` doesn't exist on your system, it is auto-installed.

The actual work is done by `thirdparty.sh` which is driven from `thirdparty.txt`.  This file
should be edited to add new thirdparty images and/or versions.  The script is smart and will
only actually copy files if their manifests are different.

This step is also run as part of the cloud build, so that when run as part of a scheduled build,
we also update our thirdparty images.

### `make build-publish-cloud-builder`

This step creates an image used in GCP Cloud Builds to run our build steps.  It typically only needs 
to be run when a new repository is set up or changes are made to the `Dockerfile-cloud-builder` file.

### `make seed-arm64`

**NOTE**: As mentioned above, this script is no longer needed since we have a dedicated
`arm64` VM.  However, keeping this around for reference and "just in case".

**NOTE**: This step is meant to be run on an M1 (Apple Silicon) Mac on Linux `arm64` VM only.  

The purpose of this script is to work around the issue that doing `arm64` builds in GCP Cloud Builder is 
very very very slow due to QEMU emulation.  Utilizing the Docker `--cache-to`/`--cache-from` options, 
we build the `arm64` images on a local M1 Mac or `arm64` VM and cache the build results in the artifact 
registry.  These results are then re-used when the actual cloud build runs.  We are, in essence, 
"seeding" the cache with the `arm64` images.

One can run `make seed-arm64-dry-run` to see what commands this will actually run as a sanity
check before running the real thing.

You can verify caching is working by re-running the script.  While an initial run may take 20 minutes, 
a re-run should take less than 2.

To seed a build for a specific platform, you can do something like this:

```shell
# Dry run
DRYRUN=1 PLATFORMS="linux/arm64" TAG_MODIFIER="arm64-seed" RUNTIME_VERSION=4 make buildx-publish-runtime

# For real
PLATFORMS="linux/arm64" TAG_MODIFIER="arm64-seed" RUNTIME_VERSION=4 make buildx-publish-runtime
```

### `make cloud-build`

This step launches the cloud build (defined in `pr.yaml`) to publish to the `docker-dev` repository.

By default, it assumes the `arm64` VM is already running (e.g., via `make start-vm`).  To auto start/stop the VM, 
as build steps, do this:

```shell
AUTO_START_STOP=1 make cloud-build
```

### Docker Details

It is best to consult the `Makefile` and various `Dockerfile`'s for full details on the options used.  
However, here are some notes on how things work for background:

Builds are done using the Docker `buildx` plug-in.  When you use Docker Desktop on your Mac, this plug-in is
bundled in.  On Linux, it is not, which is why we create our own cloud builder image in 
`Dockerfile-cloud-builder`.

We utilize the `--cache-from`/`--cache-to` options to persist build steps across builds.  This not only 
speeds up subsequent builds (if nothing has changed), it also provides a way for us to seed `arm64` 
builds from an M1 mac. The cache files are stored in the `cache` sub-folder under the root repo.

In Cloud Build (as defined in `pr.yaml`), we create an `ssh` tunnel using IAP (Identity Aware Proxy)
to Docker on the dedicated `arm64` VM.  This speeds up builds considerably, eliminating the need for 
seeding from a local developer desktop.  See the comments in the `.yaml` file and 
[ARM64_BUILDER.md](ARM64_BUILDER.md) for more details.

### Local Development Notes

#### Makefile

Run `make help` to list all build commands intended for developer use.

#### No Space Left On Device

After doing many local builds, you may see a message like:

```shell
error: failed to solve: failed to create temp dir: mkdir /tmp/containerd-mount1784717: no space left on device
```

To reclaim space:

```shell
docker system prune
```
