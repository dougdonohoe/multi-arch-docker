# ARM64 Builder

## Introduction

This file documents how the dedicated `arm64` VM is created and set-up.  We do this because building `arm64`
images on `amd64` hardware is so very, very slow.  However, Docker allows using remote machines running Docker
for portions of the build process.

We essentially create a Tau (aka `arm64`) VM and configure our Cloud Builder to use that machine for the 
`arm64` portion of the build.

## Summary / TL;DR

Steps taken:

* Create `builder` Service Account
* Create `gcloud` `ssh` credentials for use in IAP tunneling
* Configure IAP
* Create VM
  * Install Docker + configure to listen to `tcp` locally
  * Allow `sshd` root login and port forwarding

## GCP Project

If you have the right permissions, you can create a new GCP project called `multi-arch-docker` to try
this out.  If you have an existing GCP project, just do a global search and replace 
of `multi-arch-docker` with your project name in all the files of this repo.

## Create Service Account

Created a dedicated service account in `multi-arch-docker` 
[GCP Console]https://console.cloud.google.com/iam-admin/serviceaccounts?project=multi-arch-docker) for the VM:

* Name: `builder@multi-arch-docker.iam.gserviceaccount.com`
* Roles: `Artifact Registry Writer` - enables push and pull images from Artifact Registry

## Create SSH Credentials and Saving to Cloud Secrets and Project Metadata

We need to create an `ssh` key for use in Cloud Build to tunnel to the `arm64` VM.  This only needs to be
done once, but if you need to recreate them, follow these steps:

First, create a temporary directory and an `ssh` key. 

```bash
mkdir /tmp/builder-keys
cd /tmp/builder-keys
ssh-keygen -t ed25519 -f build-google_compute_engine.ed25519 -N "" -C "root@builder"
```

This creates

* `build-google_compute_engine.ed25519`
* `build-google_compute_engine.ed25519.pub`

Then save as GCP secret (enable the API if prompted):

```bash
gcloud secrets create build-google_compute_engine-ssh-priv --replication-policy="automatic" \
       --project=multi-arch-docker --data-file=build-google_compute_engine.ed25519
gcloud secrets create build-google_compute_engine-ssh-pub --replication-policy="automatic" \
       --project=multi-arch-docker --data-file=build-google_compute_engine.ed25519.pub
```

You should see them in the [GCP Console - Secret Manager](https://console.cloud.google.com/security/secret-manager?referrer=search&project=multi-arch-docker).

You can also fetch them via `gcloud`:

```bash
gcloud secrets versions access latest --secret=build-google_compute_engine-ssh-priv --project multi-arch-docker
gcloud secrets versions access latest --secret=build-google_compute_engine-ssh-pub --project multi-arch-docker
```

To delete:

```bash
gcloud secrets delete build-google_compute_engine-ssh-priv --project multi-arch-docker
gcloud secrets delete build-google_compute_engine-ssh-pub --project multi-arch-docker
```

Then need to uploaded as project metadata ([docs](https://cloud.google.com/compute/docs/connect/add-ssh-keys#add_ssh_keys_to_project_metadata) - 
enabled the Compute API if prompted):

```text
# Get old keys and append new one
gcloud compute --project multi-arch-docker project-info describe --format="value(commonInstanceMetadata[items][ssh-keys])" | tee ssh_metadata
echo "root:$(cat build-google_compute_engine.ed25519.pub)" | tee -a ssh_metadata

# verify local file
cat ssh_metadata

# save
gcloud compute --project multi-arch-docker project-info add-metadata --metadata-from-file=ssh-keys=ssh_metadata

# fetch metadata again to verify it worked
gcloud compute --project multi-arch-docker project-info describe --format="value(commonInstanceMetadata[items][ssh-keys])"
```

You should see them in the [GCP Console - Metadata](https://console.cloud.google.com/compute/metadata?project=multi-arch-docker&tab=sshkeys).

Remove temp directory and keys:

```text
rm -rf /tmp/builder-keys
```

## IAP - Identity Aware Proxy

In order for the Cloud Builder to talk to the VM, it has to use Identity Aware Proxy (IAP).  

* [Google Cloud Build Bug - Be able to configure Cloud Build to a VPC](https://issuetracker.google.com/issues/123374893) -
  why we need to use IAP (because one can't set up a VPC to directly talk to a VM over `ssh`)
* [Useful post](https://hodo.dev/posts/post-14-cloud-build-iap/) - how to use IAP to access VM from Cloud Build

To use and configure IAP, you need to grant yourself these roles via
[IAM Admin](https://console.cloud.google.com/iam-admin/iam?project=multi-arch-docker):

* `IAP-secured Tunnel User`
* `IAP Policy Admin`
* `IAP Settings Admin`
* `Compute Instance Admin (v1)`
* `Service Account User`

If you can't grant yourself these permissions, ask a teammate or manager who has higher privileges to help.

Enable IAP for the project:

```bash
gcloud --project=multi-arch-docker services enable iap.googleapis.com
```

Add a firewall rule enabling IAP access from Cloud Build IPs:

```bash
gcloud --project=multi-arch-docker compute firewall-rules create allow-ssh-ingress-from-iap \
  --direction=INGRESS \
  --action=allow \
  --rules=tcp:22 \
  --source-ranges=35.235.240.0/20
```

Because we are using IAP, and for stronger security, we have disabled normal `ssh` via this command:

```bash
gcloud --project=multi-arch-docker compute firewall-rules update default-allow-ssh --disabled
```

You can see firewall rules in the [GCP Console - Firewall](https://console.cloud.google.com/networking/firewalls/list?project=multi-arch-docker).

You also need [add these roles](https://console.cloud.google.com/iam-admin/iam?project=multi-arch-docker) to the cloud 
build service account `tbd@cloudbuild.gserviceaccount.com`:

* `Compute Admin`
* `Service Account User`
* `IAP-secured Tunnel User`
* `Secret Manager Secret Accessor`

To determine the cloud build service account:

```bash
PROJECT_NUMBER=$(gcloud projects list --filter=multi-arch-docker --format="value(PROJECT_NUMBER)")
SERVICE_ACCOUNT="$PROJECT_NUMBER@cloudbuild.gserviceaccount.com"
echo $SERVICE_ACCOUNT
```

## Creating the VM

We need to create an `arm64` VM, and do some manual installation steps.  These steps are documented below:

### Creating Debian Instance

In the [GCP Console - VM Instances](https://console.cloud.google.com/compute/instances?project=multi-arch-docker),
use **Create Instance**:

* Name: builder-arm64-2cpu
* Zone: us-central1-a
* Series: T2A
* Machine Type: t2a-standard-2 (experimentation shows that 2 CPUs is sufficient to handle multi-arch builds)
* OS: Debian 11
* Service Account: `builder@multi-arch-docker.iam.gserviceaccount.com`
* Disk: 40G, SSD persistent disk

### Environment Variables

Define some environment variables for use in subsequent commands:

```bash
INSTANCE_NAME=builder-arm64-2cpu
ZONE=us-central1-a
```

### Login

Login and then make yourself `root` since all subsequent commands need to run as `root` (this makes life easier than
having to `sudo` everything):

```bash
# From Mac
gcloud compute ssh --zone "us-central1-a" $INSTANCE_NAME --project multi-arch-docker --tunnel-through-iap

# On VM
sudo su -
```

You may get a warning to install `numpy` for better performance:

```bash
$(gcloud info --format="value(basic.python_location)") -m pip install numpy
```

You may need to prefix the above `gcloud compute ssh` command with `CLOUDSDK_PYTHON_SITEPACKAGES=1` if the
warnings don't go away.

### Install Docker

* Following [debian install instructions](https://docs.docker.com/engine/install/debian/).

```bash
apt-get install --yes ca-certificates curl gnupg lsb-release make
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install --yes docker-ce docker-ce-cli containerd.io docker-compose-plugin

# To test
docker run hello-world
```

### Configure Docker Access

```bash
gcloud auth --quiet configure-docker us-docker.pkg.dev
```

### SSH Access For Root

To allow root login and port forwarding, change these lines to `yes` in `/etc/ssh/sshd_config`:

```
PermitRootLogin yes
AllowTcpForwarding yes
```

Restart ssh

```
service ssh reload
```

From mac:

Test using IAP:

```
gcloud compute ssh --zone "us-central1-a" root@$INSTANCE_NAME --project multi-arch-docker --tunnel-through-iap
```

### Port Forwarding

We can combine Identity Aware Proxy (IAP, see above) with forwarding local the Docker port over `ssh` to allow a Google Cloud
Build to access the VM.  First we need to enable `tcp` on the machine using the localhost address:

* [Docker Daemon](https://docs.docker.com/engine/reference/commandline/dockerd/#daemon-socket-option) - About `tcp://`

By default, listening on the `tcp` socket isn't turned on.  To turn it on, add an override file to specify an alternate
`ExecStart` command (to the default, found in `/lib/systemd/system/docker.service`):

```bash
mkdir -p /etc/systemd/system/docker.service.d
cat << EOF > /etc/systemd/system/docker.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H fd:// -H tcp://0.0.0.0:2375 --containerd=/run/containerd/containerd.sock
EOF
```

```bash
# To restart, reload daemon and restart docker:
systemctl daemon-reload
systemctl restart docker.service

# Check status
systemctl status docker
systemctl is-enabled docker

# Validate
docker -H tcp://0.0.0.0:2375 ps
netstat -tulpn | grep dockerd # should show '0 :::2375' as "Local Address"
```

Test port forwarding on Mac IAP:

```bash
gcloud compute ssh --zone $ZONE $INSTANCE_NAME --tunnel-through-iap --project multi-arch-docker -- -L 2375:0.0.0.0:2375 -N

# -f to put in background
gcloud compute ssh --zone $ZONE $INSTANCE_NAME --tunnel-through-iap --project multi-arch-docker -- -L 2375:0.0.0.0:2375 -N -f
```

Create a context on Mac and a builder that uses that context:

```bash
docker context create arm_node_tunnel --docker "host=tcp://127.0.0.1:2375"
docker buildx create --use --name remote-arm-tunnel --platform linux/arm64 arm_node_tunnel
```

To list current context/builders:

```bash
docker context ls
docker buildx ls
```

Test using the remote docker:

```bash
cd multi-arch-docker
BUILDER=remote-arm-tunnel PLATFORMS=linux/arm64 TAG_MODIFIER="arm64-seed-remote" make buildx-publish-runtime
```

Run `top` on the VM and you should see processes pop up as Docker does its work.

## Cloud Build

To test a cloud build, make sure the desired VM is set in the `Makefile`:

```text
ARM64_VM ?= "builder-arm64-2cpu"
```

Then, to run a build:

```bash
make cloud-build
```

Cross your fingers and hope the IAM, Cloud Build, Docker VM stars align!

## Clean Up

To start/stop your VM:

```bash
make start-vm
make stop-vm
```

## Appendix

### Delete SSH keys

To manually delete (or add) `ssh` keys added to the metadata, you can do so in the 
[GCP Console](https://console.cloud.google.com/compute/metadata?project=multi-arch-docker&tab=sshkeys).
