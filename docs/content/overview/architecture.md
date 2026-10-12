---
title: "Architecture"
weight: 1
---

## Overview

The Red Hat build of DSX AI Factory integrates NVIDIA hardware with Red Hat
Enterprise Linux and OpenShift to deliver a validated AI infrastructure platform.
The solution follows a two-cluster model: a **management cluster** that controls
the AI Factory infrastructure, and the **AI Factory nodes** that run AI workloads.

## Cluster model

```
┌───────────────────────────────────────────────────────────────┐
│                    Management Cluster                         │
│                                                               │
│  ┌─────────────────────┐   ┌───────────────────────────────┐  │
│  │  NICo (Infra        │   │  RMS (Rack Management         │  │
│  │  Controller)        │   │  Service)                     │  │
│  │                     │   │                               │  │
│  │  • Bare-metal       │   │  • Switch fabric config       │  │
│  │    provisioning     │   │  • Firmware updates           │  │
│  │  • ZTP / DHCP       │   │  • Power management           │  │
│  │  • Machine          │   │  • Hardware inventory         │  │
│  │    validation       │   │                               │  │
│  └─────────┬───────────┘   └──────────────┬────────────────┘  │
│            │ Redfish / iPXE               │ NVUE / Redfish    │
└────────────┼──────────────────────────────┼───────────────────┘
             │ Provisioning network         │ Management network
┌────────────┼──────────────────────────────┼───────────────────┐
│            │    DSX AI Factory Nodes      │                   │
│  ┌─────────▼──────────────────────────────▼────────────────┐  │
│  │  NVIDIA GPU / DPU Nodes     NVIDIA Spectrum-X Switches  │  │
│  │  (bare-metal, RHEL/OCP)     (network fabric)            │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

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

1. **Prerequisites** — install OLM operators on the management cluster
2. **Deploy DSX AI Factory** — install the `dsx-ai-factory` Helm chart
3. **Deploy RHEL** — NICo provisions RHEL on AI Factory compute nodes
4. **Deploy OpenShift** — install OpenShift on the provisioned nodes

See the [Deployment](../deployment/) section for step-by-step instructions.
