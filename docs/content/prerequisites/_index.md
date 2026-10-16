---
title: "Prerequisites"
weight: 2
description: "Hardware, software, network, and subscription requirements"
---

Before deploying the Red Hat build of DSX AI Factory, ensure the following
hardware, software, and network requirements are met.

## Hardware

### Management cluster

A dedicated OpenShift cluster to host NICo and RMS. The cluster must have a
dynamic RWO storage provisioner set as the default StorageClass — the
PostgreSQL, Vault, NATS, and Temporal PVCs all require it. On bare-metal
clusters, install **LVM Storage (LVMS)** before deploying:

```bash
# Mark the LVMS StorageClass as default after creating an LVMCluster
oc patch storageclass <lvms-class-name> \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

**OpenShift Data Foundation (ODF)** is also supported for multi-node HA storage.

#### NICo component sizing

| Component | CPU request | Memory request | Notes |
|---|---|---|---|
| nico-rest-api | 100m | 128 Mi | |
| nico-rest-cloud-worker | 100m | 128 Mi | |
| nico-rest-site-worker | 100m | 128 Mi | |
| nico-rest-site-manager | 50m | 64 Mi | |
| nico-rest-cert-manager | 50m | 64 Mi | |
| Temporal (4 services) | ~600m | ~1.4 Gi | Spikes during startup |
| Crunchy PostgreSQL (3 instances) | ~600m | ~1.3 Gi | No resource limits set |
| Keycloak (RHBK) | ~500m | ~768 Mi | JVM — memory hungry |
| cert-manager, Crunchy PGO, RHBK operator | ~350m | ~896 Mi | OLM operators |
| **NICo workload total** | **~2.5 vCPU** | **~4.8 GiB** | |

#### Node topology options

NICo adds approximately **2.5 vCPU and 4.8 GiB** on top of OpenShift's own
platform requirements. Refer to the official OpenShift documentation for the
baseline cluster requirements for each topology:

| Topology | OpenShift minimum | With NICo | Recommended for |
|---|---|---|---|
| [Single Node OpenShift (SNO)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_on_a_single_node/index) | 8 vCPU / 16 GiB / 120 GiB | 16 vCPU / 32 GiB | Evaluation |
| [Compact 3-node](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-agent-based-installer) | 4 vCPU / 16 GiB per node | 8 vCPU / 16 GiB per node | Production |

The 3 PostgreSQL instances have no resource limits and compete for memory under
pressure — provision headroom beyond the minimum.

**Disk:** 120 GiB per node minimum. See
[OpenShift storage requirements](https://docs.redhat.com/en/documentation/openshift_container_platform/4.22/html/storage/index)
for detailed guidance.

### DSX AI Factory nodes

NVIDIA DSX AI Factory hardware. Refer to the
[NVIDIA Infra Controller hardware prerequisites](https://docs.nvidia.com/infra-controller/documentation/getting-started/prerequisites/hardware)
for the validated hardware bill of materials.

### Network

| Network | Requirements |
|---|---|
| Provisioning | L2 segment reachable from management cluster; DHCP managed by NICo |
| Management (OOB) | Reachable from management cluster; Redfish BMC on AI Factory nodes and switches |
| Workload | RoCE/InfiniBand fabric for GPUDirect RDMA |

## Software

### OpenShift

- **Management cluster:** OpenShift 4.22 or later
- **Workload cluster:** OpenShift 4.22 or later (installed by NICo)

### Red Hat subscriptions

The following subscriptions are required:

- Red Hat OpenShift Container Platform
- Red Hat Enterprise Linux (for AI Factory compute nodes)
- Access to `registry.access.redhat.com` (UBI images for container builds)
- RHSM organization ID and activation key for container image builds

### Required tools

| Tool | Version | Purpose |
|---|---|---|
| `oc` / `kubectl` | ≥ 4.22 | Cluster management |
| `helm` | **4.x** | Chart installation (Helm 4 required — the kustomize post-renderer plugin uses the Helm 4 post-renderer protocol; Helm 3 fails to load it) |
| GitHub account | — | Access to `ghcr.io/rh-ecosystem-edge/dsx-ai-factory` |

## Namespaces

The deployment uses three namespaces on the management cluster:

| Namespace | Contents |
|---|---|
| `nico-rest` | REST API (`nico-rest-api`), Temporal, Crunchy PG (cloud), Keycloak routes, ESO secrets |
| `nico-system` | NICo Core (`nico-api`), Vault HA, NATS, Crunchy PG (site), REST site-agent, RMS |
| `rhbk-operator` | RHBK Keycloak operator and Keycloak instance |

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
  -n nico-system
```
