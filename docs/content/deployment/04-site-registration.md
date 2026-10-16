---
title: "Registering a site and deploying NICo"
weight: 4
---

With Vault initialised and the cloud infrastructure running, deploy NICo Core
on the management cluster, register the first site, and bring up the REST
site-agent that bridges the cloud REST plane to the site Core plane.

## Step 1 — Deploy NICo Core

NICo Core runs in the `nico-system` namespace. The `SITE` variable selects
which per-site values overlay (`charts/values/infra-site-<SITE>.yaml`) is
applied on top of the base `charts/values/nico-core.yaml`.

```bash
make deploy-site SITE=<site-name>
```

This deploys all Core services: `nico-api`, `nico-dhcp`, `nico-pxe`,
`nico-dns`, `nico-flow`, `nico-ntp`, `nico-bmc-proxy`, and the hardware
health monitor.

## Step 2 — Register the site and deploy the site-agent

The REST site-agent connects the cloud-plane REST API (`nico-rest-api` in
`nico-rest`) to the site-plane Core API (`nico-api` in `nico-system`).
**Without this step**, `nico-rest-api` cannot communicate with `nico-api` and
no machines can be onboarded.

```bash
make deploy-site-agent SITE_NAME=<site-name>
```

This creates a site record in NICo's database (via the REST API) and deploys
`nico-rest-site-agent` in `nico-system`.

To register a site with an explicit ID:

```bash
make deploy-site-agent SITE_NAME=<site-name> SITE_ID=<uuid>
```

## Step 3 — Deploy RMS

Deploy the Rack Management Service for switch and PDU lifecycle management:

```bash
make deploy-rms
```

RMS runs in `nico-system`.

## Step 4 — Verify all three namespaces

```bash
make status
```

This shows pod status across all three namespaces (`nico-rest`, `nico-system`,
`rhbk-operator`). All pods should reach `Running` or `Completed` before
proceeding to hardware onboarding.

## Next steps

With NICo Core, the site-agent, and RMS running, proceed to
[Deploying RHEL](../05-rhel/) to provision the first AI Factory compute nodes.
