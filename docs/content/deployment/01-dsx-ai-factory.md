---
title: "Deploying DSX AI Factory"
weight: 2
---

This section guides you through deploying the Red Hat build of DSX AI Factory
on an OpenShift management cluster. The deployment follows a fixed sequence of
Helm releases across three namespaces:

| Namespace | What runs there |
|---|---|
| `nico-rest` | NICo REST plane, Temporal, Keycloak RHBK, Crunchy PG (cloud) |
| `nico-system` | NICo Core, Vault, NATS, Crunchy PG (site), RMS |
| `rhbk-operator` | Keycloak operator |

The full sequence is automated by the `Makefile` included in this repository.
The steps below walk through each phase in order.

> The `Makefile` also offers `make deploy-dataplane-vip`, a shortcut that runs
> the full site deployment end to end (prerequisites → site infrastructure →
> NICo Core) with the MetalLB VIP pre-wired. See the `Makefile` for the required
> `DATAPLANE_*` variables.

## Before you begin

Run the preflight check to verify the required tools, the kustomize
post-renderer, your cluster login, and a default StorageClass before deploying:

```bash
make check-prereqs
```
Resolve anything it reports as `[MISSING]` before continuing.

## Step 1 — Install prerequisite operators

The `prereqs` chart installs the OLM operators that all subsequent releases
depend on.

```bash
make deploy-prereqs
```

Or directly with Helm:

```bash
helm install dsx-ai-factory-prereqs \
  oci://ghcr.io/rh-ecosystem-edge/dsx-ai-factory/charts/dsx-ai-factory-prereqs \
  --version 0.1.0 \
  --namespace dsx-ai-factory \
  --create-namespace \
  --wait --timeout 15m
```

This installs cert-manager, Crunchy PostgreSQL, RHBK (Keycloak), MetalLB,
External Secrets Operator, and NMState via OLM subscriptions, then waits for
each operator's CRDs to be established.

**If `helm` install times out** (the install has not finished), follow the
post-install hook that waits for the operators — reference it by Job name, since
the pod name is generated:

```bash
oc logs -n dsx-ai-factory job/dsx-ai-factory-prereqs-wait-operators -f
```

> These hook Jobs delete themselves once they succeed, so after a successful
> install you will not see them — a `deployed` release status means the hooks
> completed.

### Verify the prerequisites

Check the Helm release reached `deployed`:

```bash
helm list -n dsx-ai-factory
# NAME                     STATUS     CHART
# dsx-ai-factory-prereqs   deployed   dsx-ai-factory-prereqs-0.1.0
```

Confirm the operators are installed:

```bash
oc get operators
# cert-manager, crunchy-postgres, rhbk-keycloak, external-secrets, metallb, nmstate
```

Confirm the NICo ClusterIssuers are `Ready`:

```bash
oc get clusterissuer
# nico-bootstrap-issuer   True
# nico-rest-ca-issuer     True
```

The root CA itself is a `Certificate`:

```bash
oc get certificate -A | grep nico-root-ca
```

## Step 2 — Configure MetalLB VIPs for provisioning services

NICo's provisioning services must be reachable by AI Factory nodes over the
provisioning network via MetalLB LoadBalancer IPs. OpenShift Routes cannot
carry UDP traffic, so DHCP (port 67) and DNS (port 53) require LoadBalancer
services.

| Service | Port | Protocol | Purpose |
|---|---|---|---|
| `nico-api` | 443 | TCP | Core gRPC API; IP SAN in the TLS certificate |
| `nico-pxe` | 80, 8080 | TCP | iPXE binary and per-client boot script (8080); static discovery-OS artifacts — `scout.squashfs`, `scout.efi`, BFB (80) |
| `unbound` | 53 | UDP+TCP | DNS for the `.forge` provisioning zone |
| `nico-dhcp` | 67 | UDP | DHCP for AI Factory nodes |

> **Optional — `nico-ssh-console-rs` (TCP 2222):** gives admins and tenants SSH
> access to the bare-metal nodes' virtual serial console (Serial-over-LAN, via
> the BMC). It also continuously captures each node's console output (kernel,
> UEFI/BIOS, kernel panics) to log files and can forward them to Loki/Grafana
> through an optional OpenTelemetry sidecar. It is not required for provisioning.

By default, each of the four services receives its own VIP. This avoids
MetalLB `allow-shared-ip` constraints and keeps the DNS and DHCP options
independent. For a legacy single-VIP deployment, set
`DATAPLANE_VIP_MODE=shared` and `DATAPLANE_VIP`.

Set these variables in `deploy.env`:

```bash
SITE=mysite
DATAPLANE_API_VIP=192.0.2.10
DATAPLANE_PXE_VIP=192.0.2.11
DATAPLANE_DNS_VIP=192.0.2.12
DATAPLANE_DHCP_VIP=192.0.2.13
DATAPLANE_POOL=192.0.2.0/28
```

Create an `IPAddressPool` and `L2Advertisement` in the `metallb-system` namespace:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nico-provisioning
  namespace: metallb-system
spec:
  # Only hand out this IP when a Service explicitly requests it (via annotation),
  # so the cluster never auto-assigns the provisioning VIP to an unrelated 
  # LoadBalancer Service.
  autoAssign: false
  addresses:
    - <provisioning-network-vip>/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: nico-provisioning
  namespace: metallb-system
spec:
  ipAddressPools:
    - nico-provisioning
  interfaces:
    - <provisioning-nic>
```
Then, apply the yaml definition to your management cluster:

```bash
$ oc apply -f metallb-provisioning.yaml
```

> **OVN gateway requirement:** Enable local-gateway mode if not already set:
> ```bash
> oc patch network.operator cluster --type merge \
>   -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'
> oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes
> ```

> **DHCP relay:** Required when the provisioning VLAN is L3-separated from the
> management cluster. See
> [Network prerequisites](../00-network-prerequisites/).

## Next steps

**Management cluster deployment** — continue in this order:

1. [Deploying cloud infrastructure](../02-cloud-infra/) — Temporal, Keycloak, Crunchy PG cloud
2. [Deploying site infrastructure and Vault](../03-vault/) — Vault HA, NATS, Crunchy PG site
3. [Registering a site and deploying NICo](../04-site-registration/) — NICo Core, site-agent, RMS

Once the management cluster is fully operational, provision AI Factory compute nodes:

- [Deploying RHEL](../02-rhel/)
- [Deploying OpenShift](../03-openshift/)
