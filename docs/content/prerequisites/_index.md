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
PostgreSQL, Vault, NATS, and MCE all require it. On the management cluster **OpenShift Data Foundation (ODF)** or
 **LVM Storage (LVMS)** can be installed before deploying NICo. 
 
 > ODF is recommended for production environments.

```bash
# Mark the LVMS StorageClass as default after creating an LVMCluster
oc patch storageclass <lvms-class-name> \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```


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

| Plane | NICo segment | Requirements |
|---|---|---|
| Out-of-band / management | `Underlay` | Reachable from the management cluster; Redfish BMC on AI Factory nodes and switches; `nico-dhcp` serves the BMCs and DPU OOB |
| Provisioning / host in-band | `HostInband` · `Admin` | Boot segment for the host OS during discovery and OS install. DHCP served by `nico-dhcp` on `HostInband` (zero-DPU), or by the DPU on the `Admin` overlay. A DHCP relay to the `nico-dhcp` VIP is required when the segment is L3-separated from the management cluster |
| Tenant | `Tenant` | North–south tenant fabric; NICo programs the VPC/VNI automatically after allocation |

> The GPU **compute fabrics** — Ethernet East–West (RoCE), InfiniBand, and
> NVLink — must be pre-built. NICo isolates them per tenant via HBN, UFM, and
> NMX-C, but does not configure the underlying switches.

## Software

### OpenShift

- **Management cluster:** OpenShift 4.22 or later
- **Workload cluster:** OpenShift 4.22 or later (installed by NICo)

### Cluster operators

The management cluster requires the OLM operators listed under
[Architecture → OLM operators](../overview/#olm-operators-prerequisites):
cert-manager, Crunchy PostgreSQL, RHBK, External Secrets Operator, MetalLB and
NMState for NICo and RMS; **ODF or LVM Storage (LVMS)** for the default
StorageClass; and **MultiCluster Engine (MCE)** for OpenShift provisioning
(Assisted Installer / Agent) and HostedControlPlanes.

The DSX AI Factory `prereqs` chart installs the NICo/RMS operators. Install
storage (ODF or LVMS) and MCE separately from OperatorHub beforehand.

### Red Hat subscriptions

The following subscriptions are required:

- Red Hat OpenShift Container Platform (management and workload clusters)
- Red Hat Enterprise Linux (for AI Factory compute nodes)
- Access to `registry.access.redhat.com` (UBI images for container builds)
- RHSM organization ID and activation key for container image builds

### Required tools

| Tool | Version | Purpose |
|---|---|---|
| `oc` / `kubectl` | ≥ 4.22 | Cluster management |
| `helm` | **4.x** | Chart installation (Helm 4 required — the kustomize post-renderer plugin uses the Helm 4 post-renderer protocol; Helm 3 fails to load it) |
| `make` | — | Drives the deployment workflow (Makefile targets) |
| `kustomize` | — | Post-render patches applied during Helm install |
| `python3` | 3.x | Helper scripts (preflight checks, route patching) |
| `jq` | — | JSON processing in the deploy scripts |
| `git`, `curl`, `ssh-keygen` | — | Repository access and credential/certificate helpers |
| `podman` | optional | Running the containerised CLI wrappers (`nico-admin-cli`, `nicocli`); not needed if you use the native CLI binaries |
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
