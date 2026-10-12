---
title: "Prerequisites"
weight: 2
---

Before deploying the Red Hat build of DSX AI Factory, ensure the following
hardware, software, and network requirements are met.

## Hardware

### Management cluster

A dedicated OpenShift cluster to host NICo and RMS. Minimum configuration:

| Role | Count | Specs |
|---|---|---|
| Control plane | 3 | 8 vCPU, 32 GiB RAM, 120 GiB disk |
| Worker (optional) | 2+ | 8 vCPU, 32 GiB RAM, 120 GiB disk |

A compact 3-node cluster (control plane doubling as workers) is supported for
evaluation deployments.

### DSX AI Factory nodes

NVIDIA DSX AI Factory hardware. Refer to the
[NVIDIA Infra Controller documentation](https://docs.nvidia.com/infra-controller)
for the validated hardware bill of materials.

### Network

| Network | Requirements |
|---|---|
| Provisioning | L2 segment reachable from management cluster; DHCP managed by NICo |
| Management (OOB) | Reachable from management cluster; Redfish BMC on AI Factory nodes and switches |
| Workload | RoCE/InfiniBand fabric for GPUDirect RDMA |

## Software

### OpenShift

- **Management cluster:** OpenShift 4.18 or later
- **Workload cluster:** OpenShift 4.18 or later (installed by NICo)

### Red Hat subscriptions

The following subscriptions are required:

- Red Hat OpenShift Container Platform
- Red Hat Enterprise Linux (for AI Factory compute nodes)
- Access to `registry.access.redhat.com` (UBI images for container builds)
- RHSM organization ID and activation key for container image builds

### Required tools

| Tool | Version | Purpose |
|---|---|---|
| `oc` / `kubectl` | ≥ 4.18 | Cluster management |
| `helm` | ≥ 3.15 | Chart installation |
| GitHub account | — | Access to `ghcr.io/rh-ecosystem-edge/dsx-ai-factory` |

## Access to container images

Images are published to `ghcr.io/rh-ecosystem-edge/dsx-ai-factory`. Log in
before installing the Helm chart:

```bash
podman login ghcr.io
```

or create an image pull secret in the target namespace:

```bash
oc create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<token> \
  -n dsx-ai-factory
```
