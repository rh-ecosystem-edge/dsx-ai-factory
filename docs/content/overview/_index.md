---
title: "Architecture"
weight: 1
description: "Two-cluster model, NICo and RMS components, provisioning flow"
---

## Overview

The Red Hat build of DSX AI Factory integrates NVIDIA hardware with Red Hat
Enterprise Linux and OpenShift to deliver a validated AI infrastructure platform.
The solution follows a two-cluster model: a **management cluster** that controls
the AI Factory infrastructure, and the **AI Factory nodes** that run AI workloads.

## Cluster model

![Architecture - Cluster model](/images/architecture-cluster-model.svg)

## Components

### Management cluster components

**NVIDIA Infra Controller (NICo)** is an NVIDIA open-source suite of microservices for zero-trust lifecycle management of bare-metal servers. It automates hardware discovery, firmware validation, DPU provisioning, and per-tenant network isolation. It enables cloud providers and infrastructure operators to operate an AI Factory infrastructure.

**NICo** handles everything from the initial Redfish discovery through hardware enumeration and validation (using ephemeral Scout agents), promoting nodes to a ready state, allocating them, and finally pushing the OS via PXE. NICo leverages BlueField DPUs — or even standard zero-DPU hosts — to create an isolation boundary between the infrastructure provider and the tenants that share the infrastructure, which lets us deploy RHEL and bare-metal OpenShift clusters securely and automatically.

On the management cluster, **NICo** manages the full lifecycle of bare-metal
AI Factory nodes:

- **Discovery** — nodes boot into the Scout OS via PXE/iPXE and are discovered
  by NICo, which validates hardware inventory against the expected configuration
- **ZTP** — NICo's DHCP service (ISC Kea) hands out addresses and PXE/iPXE boot
  options; `nico-api` applies BIOS settings over Redfish and the
  `preingestion-manager` brings firmware to the required baseline before OS install
- **Provisioning** — NICo installs RHEL or RHCOS on validated nodes using
  qcow-imager and pushes the workload cluster ignition
- **Machine validation** — each node undergoes hardware attestation before
  being admitted to the workload cluster

**Rack Management Service (RMS)** provides rack-level infrastructure management:

- Switch firmware updates and configuration via NVUE
- PDU power control and monitoring
- Hardware inventory for switches and rack-level components

### OLM operators (prerequisites)

| Operator | Purpose |
|---|---|
| cert-manager | TLS certificate management for NICo mTLS |
| Crunchy PostgreSQL | Database backend for NICo and RMS |
| RHBK (Keycloak) | SSO / OIDC for NICo REST API and UI |
| External Secrets Operator | Integration with Vault or other secret stores |
| MetalLB | Load-balancer VIPs for NICo provisioning services |
| NMState | Host network configuration on management nodes |
| ODF or LVM Storage (LVMS) | Default StorageClass for the NICo, Vault, and PostgreSQL PVCs |
| MultiCluster Engine (MCE) | OpenShift provisioning (Assisted Installer / Agent) and HostedControlPlanes (HyperShift) |

> cert-manager, Crunchy PostgreSQL, RHBK and External Secrets Operator are
> required by NICo and RMS themselves. MetalLB and NMState provide the
> provisioning network. Storage (ODF or LVMS) backs the PVCs. MultiCluster
> Engine (MCE) is required for the OpenShift provisioning phase.

### Network planes

NICo models host connectivity as a set of **network segments**. The table maps
the operational planes to NICo's segment names:

| Plane (operational) | NICo segment(s) | Purpose | On it |
|---|---|---|---|
| **Out-of-band / management** | `Underlay` | Redfish to host/DPU BMCs and switch NVUE; DHCP for BMCs and DPU OOB | NICo & RMS ↔ BMCs, switches, DPUs |
| **Provisioning / host in-band** | `HostInband` (zero-DPU) · `Admin` (DPU overlay) | DHCP + PXE/iPXE boot and the host OS address during discovery and OS install | NICo ↔ AI Factory host OS |
| **Tenant** | `Tenant` | North–south tenant traffic after allocation; NICo programs the VPC/VNI automatically | AI Factory nodes ↔ tenant network |

> The GPU **compute fabrics** — Ethernet East–West (RoCE), InfiniBand, and
> NVLink — are isolated per tenant by NICo via HBN, UFM, and NMX-C respectively.
> They are not part of the DHCP-served segments above.

## Deployment sequence

1. **[Network prerequisites](../deployment/00-network-prerequisites/)** — provision VLANs and MetalLB VIPs on the ToR switch and management cluster
2. **[Prerequisites chart](../deployment/01-dsx-ai-factory/)** — install OLM operators (cert-manager, Crunchy PostgreSQL, RHBK, MetalLB, ESO, NMState)
3. **[Cloud infrastructure](../deployment/02-cloud-infra/)** — deploy Temporal, Keycloak, and Crunchy PG cloud databases (`nico-rest` namespace)
4. **[Vault and site infrastructure](../deployment/03-vault/)** — deploy Vault HA, NATS, and Crunchy PG site database; initialize Vault PKI and AppRole (`nico-system` namespace)
5. **[NICo Core and site registration](../deployment/04-site-registration/)** — deploy NICo Core, register the site, deploy REST site-agent and RMS
6. **[Deploy RHEL](../deployment/05-rhel/)** — NICo provisions RHEL on AI Factory bare-metal nodes
7. **[Deploy OpenShift](../deployment/06-openshift/)** — install OpenShift worker nodes on provisioned hardware

See the [Deployment](../deployment/) section for step-by-step instructions.

## Further reading

- [NICo overview and components](https://docs.nvidia.com/infra-controller/documentation/architecture/overview-and-components)
- [NICo Day 0/1/2 lifecycle](https://docs.nvidia.com/infra-controller/documentation/overview/day-0-day-1-day-2-lifecycle)
- [NICo managed host state machine](https://docs.nvidia.com/infra-controller/documentation/architecture/state-machines/managed-host)
- [RMS architecture](https://docs.nvidia.com/rms/documentation/architecture/external-view)

## NICo service reference

NICo is composed of several services that each own a specific part of the
provisioning protocol.

| Service | Layer | Role |
|---|---|---|
| `nico-api` (`carbide-api`) | Core | Central gRPC API and state machine engine; owns all machine state transitions; answers DHCP and PXE queries from other services |
| `nico-dhcp` | Site | ISC Kea-based DHCP server; hands out IP leases for BMC boot and PXE boot URLs; calls `nico-api` on every DHCP DISCOVER |
| `nico-pxe` | Site | HTTP server for iPXE binaries and boot scripts; calls `nico-api` to determine which boot image to serve per client |
| `nico-dns` / `unbound` | Site | DNS for the provisioning zone; resolves NICo service hostnames during boot |
| `site-explorer` | Site | Background loop that probes BMC endpoints via Redfish and creates `explored_endpoint` records |
| `preingestion-manager` | Site | Manages BMC reset, NTP configuration, and firmware upgrades before a node enters the provisioning flow |
| `nico-rest-api` | REST | REST API server for operator-facing operations (machine registration, instance management) |
| `nico-rest-site-manager` | REST | Manages site-level resources (segments, VPCs, subnets) via the REST API |
| `nico-rest-site-agent` | REST | Site-agent (codename *Elektra*) bridging the cloud REST plane to the site Core: receives Temporal workflow tasks, relays them to `nico-api` over mTLS gRPC, and carries network and storage configuration to the site |
| `nico-rest-workflow` | REST | Temporal workflow worker; orchestrates multi-step provisioning operations (OS install, reprovisioning) |
| `nico-rest-cert-manager` | REST | Issues and rotates mTLS credentials for site components |
| `nico-rest-db` | REST | Database migration runner for the REST-plane PostgreSQL schema |

## Scout discovery OS

The Scout discovery OS is served by `nico-pxe` and is the first thing that
boots on an AI Factory node. It consists of three blobs:

| Boot blob | Role |
|---|---|
| `ipxe.efi` | iPXE UEFI loader with an embedded chainload script pointing at `nico-pxe` |
| `scout.efi` | Minimal UKI; downloads and measures the Scout rootfs before booting into it |
| `scout.squashfs` | Scout rootfs containing the `forge-scout` hardware enumeration agent |

`forge-scout` enumerates the node's hardware inventory (CPUs, GPUs, NICs,
memory, storage) and reports it to `nico-api` via mTLS gRPC. This callback
triggers BOM validation and advances the node through the provisioning state
machine.

## Provisioning flow

The diagram below traces the full arc end to end. It begins when a machine is registered — the operator tells NICo to expect a server with a given BMC. NICo's Site Explorer reaches that BMC over Redfish, fully out of band, and performs the initial hardware discovery.

NICo then power-cycles the host and PXE-boots it into Scout, an ephemeral agent that enumerates the hardware, securely wipes the disks, reports the full inventory back, and runs machine validation tests. As Scout verifies the host identity, NICo promotes the temporary predicted ID into a stable host ID.

Once validation passes, the node reaches `Ready`: clean, validated, and parked in the pool. This completes the NICo bare-metal lifecycle.

The NICo cloud tier then handles provisioning. The operator defines capacity with an InstanceType, allocates it to a tenant, and attaches a flat VPC. Creating an Instance binds the tenant's network to the physical hardware and triggers an iPXE boot into the OpenShift or RHEL artifacts. For OpenShift, the Red Hat Assisted Installer takes over: NICo boots the discovery agent (an RHCOS live image), the node registers as an Agent, and a NodePool joins it to the HostedCluster as an operational worker node.

The result is two clean layers: NICo delivers networked, validated bare metal, and OpenShift builds on top.

![Provisioning sequence diagram](/images/provisioning-flow.png)


## Provisioning Diagram

![Provisioning sequence diagram](/images/provisioning-rhel-sequence.svg)

The flow is the same for every operating system up to OS install — the divergence is only at the final step, where NICo boots the OS-specific installer

1. **Registration & approval** — the operator registers each host in the Expected Machines table (BMC MAC, chassis serial, factory BMC credentials) and approves it for Measured Boot. Only registered machines are ingested.
2. **BMC discovery** — the host BMC obtains its IP (from `nico-dhcp`, or a fixed `bmc_ip_address` added in the Expected Machine table). In the diagram, the node powers on; in this case `nico-dhcp` assigns an IP to the BMC and forwards the MAC information to `nico-api` which matches it against the Expected Machines table and returns an address **only for a registered machine**. 
3. **Redfish discovery** — `site-explorer` probes the BMC over Redfish with the factory credentials, collects the first hardware inventory snapshot, and **optionally** rotates the BMC password to the site-wide credential.
4. **Preingestion** — before pairing, NICo runs a preingestion state machine against each discovered BMC endpoint (host and DPU): it checks the BMC clock is within the allowed drift of site time (resetting the BMC if not) and upgrades host firmware that is below the minimum version required for ingestion.
5. **DPU & host init** — for hosts with a managed DPU, NICo sets Secure Boot and installs the DPU OS (BFB). `nico-api` then configures BIOS and boot order via Redfish and PXE-boots the host into **Scout** (served by `nico-pxe`), which enumerates the hardware and reports back.
6. **Validation** — `nico-api` checks the reported inventory against the expected SKU; if hardware validation is enabled, Scout runs the validation tests (GPU, CPU, memory, storage). NICo finalises the stable host ID and applies UEFI lockdown.
7. **Ready** — the host enters the available pool, ready for an instance to be assigned.
8. **OS provisioning** — when an instance is assigned, `nico-rest-workflow` orchestrates network and storage config via `nico-rest-site-agent`, then boots the OS-specific installer:
   - **RHEL**: `qcow-imager.efi` writes a RHEL qcow2 image to disk
   - **OpenShift**: NICo iPXE-boots the Red Hat Assisted Installer discovery agent; the node registers as an Agent and a NodePool joins it to the HostedCluster (see [Deploying OpenShift](../deployment/03-openshift/))