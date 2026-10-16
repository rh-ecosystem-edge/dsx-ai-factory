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

**NVIDIA Infra Controller (NICo)** runs on the management cluster and manages
the full lifecycle of bare-metal AI Factory nodes:

- **Discovery** — nodes boot into the Scout OS via PXE/iPXE and are discovered
  by NICo, which validates hardware inventory against the expected configuration
- **ZTP** — NICo's DHCP service (ISC Kea) hands out addresses and boot options;
  the Scout OS performs BIOS/firmware configuration before OS installation
- **Provisioning** — NICo installs RHEL or RHCOS on validated nodes using
  qcow-imager and pushes the workload cluster ignition
- **Machine validation** — each node undergoes hardware attestation before
  being admitted to the workload cluster

**Rack Management Service (RMS)** provides rack-level infrastructure management:

- Switch firmware updates and configuration via NVUE
- PDU power control and monitoring
- Hardware inventory for switches and rack-level components

### OLM operators (prerequisites)

The following operators must be installed on the management cluster before
deploying NICo and RMS:

| Operator | Purpose |
|---|---|
| cert-manager | TLS certificate management for NICo mTLS |
| Crunchy PostgreSQL | Database backend for NICo and RMS |
| RHBK (Keycloak) | SSO / OIDC for NICo REST API and UI |
| MetalLB | Load-balancer VIPs for NICo services |
| External Secrets Operator | Integration with Vault or other secret stores |
| NMState | Host network configuration on management nodes |

### Network planes

| Network | Purpose | Users |
|---|---|---|
| Provisioning (L2) | PXE boot, DHCP, iPXE, qcow imaging | NICo ↔ AI Factory nodes |
| Management (OOB) | Redfish BMC, switch NVUE API | NICo, RMS ↔ hardware |
| Workload | AI compute traffic, GPUDirect RDMA | AI Factory nodes |

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
| `nico-site-agent` | REST | Relay between the cloud-plane REST workflow engine and the site-plane `nico-api`; carries network and storage configuration to the site |
| `nico-rest-api` | REST | REST API server for operator-facing operations (machine registration, instance management) |
| `nico-rest-site-manager` | REST | Manages site-level resources (segments, VPCs, subnets) via the REST API |
| `nico-rest-site-agent` | REST | Receives workflow tasks from `nico-rest-site-manager` and executes them on the site plane |
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

![Provisioning sequence diagram](/images/provisioning-rhel-sequence.svg)

Steps 1–7 are identical for all operating systems. The divergence happens
at step 8, where NICo boots the OS-specific installer:

1. **BMC IP assignment** — node powers on; `nico-dhcp` assigns a BMC IP lease and calls `nico-api` to record the BMC MAC
2. **Redfish discovery** — `site-explorer` probes the BMC IP via Redfish and records the hardware inventory snapshot
3. **PXE boot entry** — host UEFI sends a DHCP DISCOVER; `nico-dhcp` returns an IP and an HTTP boot URL; host downloads `ipxe.efi` from `nico-pxe`
4. **Scout boot** — `nico-pxe` serves the Scout iPXE script; host boots `scout.efi` → `scout.squashfs`; `forge-scout` enumerates hardware and calls back to `nico-api`
5. **BIOS configuration** — `nico-api` pushes BIOS settings via Redfish (boot order, UEFI, secure boot)
6. **BOM validation** — `nico-api` cross-checks the Scout inventory against the expected SKU; node boots Scout a second time for runtime measurements (GPU health, NIC links)
7. **Node ready** — node enters the `Ready` pool, available for instance assignment
8. **OS provisioning** — when an instance is assigned, `nico-rest-workflow` orchestrates network/storage config via `nico-site-agent`, then boots the OS installer:
   - **RHEL**: `qcow-imager.efi` writes a RHEL qcow2 image to disk
   - **RHCOS**: `InlineIpxe` boots the RHCOS live installer via `coreos-installer`
9. **OS ready** — node boots from disk; PXE override cleared
