---
title: "Registering a site and deploying NICo"
weight: 5
---
This is the step the whole stack has been building up to. Everything before it:
the operators, Keycloak, PostgreSQL, the cloud REST API, Vault, etc. was
infrastructure. Here, NICo the *application* finally runs on the **site tier**,
right next to the hardware, and is then connected back to the cloud so the cloud
can drive work onto it.

So far there are two worlds that don't know about each other yet:

[NICo tiers](/images/nico-two-tiers.png)

- The **cloud** plane. The REST API, Keycloak, Temporal (`nico-rest`), and
- The **site** plane. NICo Core, DHCP, PXE, DNS, all running next to the hardware
  (`nico-system`).

**Step 1** brings up the site plane; **Step 2** is the handshake that connects the two.

## Step 1 — Deploy NICo Core (the site tier)
////////////////////////////////////////////////////////

NICo Core runs in the `nico-system` namespace. The `make deploy-site` command 
installs the upstream **`nico` umbrella chart**: Core and all the site workloads:
`nico-api`, `nico-dhcp`, `nico-dns`, `nico-pxe`, the BMC proxy, hardware-health, 
`unbound`, and the SSH console. These are the pods that actually talk to the baremetal servers.

[NICo deploy site](/images/deploy-site.png)


### Two values files. Your rack described in text

`deploy-site` layers **two** values files, and this is a deliberate safety
design:

1. **`charts/values/nico-core.yaml`** (base). It turns the right components on and
   off for OpenShift and ships with **`siteConfig` disabled on purpose**, so a
   bare deploy never brings up a half-configured site.
2. **`charts/values/nico-core-<site>.yaml`** (per-site overlay). It carries the
   real thing: the **network segments** (OOB/BMC, admin, host-inband) and the
   **resource pools** the Core API needs to start.

Create your per-site file from the documented template and fill it in:

```bash
cp charts/values/nico-core-site-example.yaml charts/values/nico-core-<site>.yaml
# Edit the lines marked EDIT: your [networks.*] segments and [pools.*].
# At minimum the Core API needs one [pools.*] and one [networks.admin]
# segment — it will not start otherwise.
```
Then deploy:

```bash
make deploy-site SITE=<site>
```
`SITE` selects `charts/values/nico-core-<SITE>.yaml`, layered on top of the base.
The target also creates an OpenShift **passthrough route** for the gRPC API
(`nico-api-grpc`), which lets `nico-admin-cli` connect from outside the cluster.

After this command, Core is up, it has its pools and networks, a **Vault-issued
identity** (cert from the `vault-nico-issuer` ClusterIssuer), and it is
reachable. The site is alive — it just isn't connected to the cloud yet.

## Step 2 — Register the site and deploy the site-agent

The **site-agent** is the component that lives on the site cluster and **dials
out to the cloud**, so the cloud can drive Temporal workflows down onto the site.
Because the connection is initiated **site → cloud**, a single central cloud can
manage many remote sites even when it has no inbound access to them.

[NICo deploy site agent](/images/deploy-site-agent.png)

```bash
make deploy-site-agent SITE_NAME=<site>
```
This is more than a `helm install`. The target:

1. **Authenticates to Keycloak** as the `ncx-service` client (realm `nico`) and
   gets a token.
2. **Creates a Site** via the REST API. This is
   the first time a named `Site` exists. Everything before was org, provider,
   and tenant. The API returns two things: a **Site UUID** and a one-time
   **registration token (OTP)**.
3. **Deploys `nico-rest-site-agent`** with `CLUSTER_ID` and the Temporal
   subscribe namespace.

From there the agent subscribes to the **Temporal namespace** created for that
site. The cloud enqueues a workflow on that namespace, the agent picks it up and
executes it **locally**, next to the hardware.

### Choosing `SITE_NAME`

`SITE_NAME` is just a human-readable label that identifies this site/rack within
your org (`ncx`). It does **not** have to match any switch, VLAN, or
`[networks.*]` name in your site config. It is independent, and you choose it.
Pick something descriptive and stable; don't use the `my-site` placeholder from the 
example. Using the **same name** as your `SITE` overlay keeps "cloud site" and "cluster" 
aligned and avoids confusion.

The target is **idempotent**. So, if the site already exists it is reused (the create
call returns *already exists* and the agent is (re)deployed against it), so it is
safe to re-run.

To deploy the agent against a site that already has a UUID (reuse, no create):

```bash
make deploy-site-agent SITE_ID=<uuid>
```

## Step 3 — Deploy RMS

Deploy the Rack Management Service for switch and PDU lifecycle management:

```bash
make deploy-rms
```

RMS runs in `nico-system`.

## Step 4 — Verify

```bash
# All Core + site-agent pods Running (nico-api/-pxe/-dns/-dhcp/unbound/-flow/…)
oc get pods -n nico-system

# MetalLB LoadBalancer services carry your site VIPs
oc get svc -n nico-system | grep LoadBalancer

# The Core identity cert is issued by Vault PKI
oc get certificate -n nico-system          # vault-nico-issuer-backed certs → Ready

# The gRPC passthrough route exists (created by deploy-site)
oc get route nico-api-grpc -n nico-system
```

Cross-namespace status in one shot:

```bash
make status
```
### Liveness check against the Core API

Issue a short-lived admin client cert from Vault PKI and talk to the Core gRPC
API through the route with `nico-admin-cli`:

```bash
make vault-admin-cert      # issues the admin client cert via the Vault PKI role
# then run nico-admin-cli against the nico-api-grpc route
```
## How it fits together

```text
    tenant
      │
nico-rest  (enqueues a workflow)
      │
   Temporal           (namespace = site UUID)
      │
  site-agent          (the bridge — dials out, site → cloud)
      │  gRPC mTLS :1079
      ▼
  nico-api (Core)  ──►  DHCP / PXE / DNS / BMC proxy  ──►  hardware
```

## Next steps

With NICo Core, the site-agent, and RMS running, the site is connected and ready
to point at real hardware. Proceed to [Deploying RHEL](../02-rhel/) to provision
the first AI Factory compute nodes.