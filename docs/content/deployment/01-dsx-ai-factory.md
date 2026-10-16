---
title: "Deploying DSX AI Factory"
weight: 1
---

This section covers the installation of NVIDIA Infra Controller (NICo) and
Rack Management Service (RMS) on the management cluster using Helm.

## Step 1 — Install prerequisite operators

The `prereqs` chart installs the OLM operators that NICo and RMS depend on.

```bash
helm install dsx-ai-factory-prereqs \
  oci://ghcr.io/rh-ecosystem-edge/dsx-ai-factory/charts/dsx-ai-factory-prereqs \
  --version 0.1.0 \
  --namespace nico-system \
  --create-namespace \
  --wait
```

The chart installs cert-manager, Crunchy PostgreSQL, RHBK, MetalLB, External
Secrets Operator, and NMState via OLM subscriptions, then waits for each
operator's CRDs to be established.

> **Note:** If the post-install hooks time out due to a MetalLB webhook
> initialization race, reinstall with `--no-hooks` and run the readiness
> checks manually:
> ```bash
> helm install dsx-ai-factory-prereqs ... --no-hooks
> oc wait --for=condition=Established crd/metallbs.metallb.io --timeout=5m
> oc wait --for=condition=Established crd/nmstates.nmstate.io --timeout=5m
> ```

## Step 2 — Configure values

Create a `values.yaml` with site-specific configuration. The required fields
depend on your network topology:

```yaml
nico:
  nico-dhcp:
    # DHCP range for the provisioning network (Kea subnet4 format)
    config:
      kea:
        subnet4:
          - subnet: "<provisioning-network-cidr>"   # e.g. 172.16.10.0/24
            pools:
              - "<pool-start>-<pool-end>"            # e.g. 172.16.10.100-172.16.10.200

  nico-api:
    # Database host: Crunchy PGO creates <cluster-name>-primary service
    database:
      host: nico-site-pg-primary.nico-system.svc
      name: nico

rack-manager:
  apiServer:
    database:
      host: rms-pg-primary.nico-system.svc
      name: rms
```

Refer to the upstream chart values for the full list of configurable options:
- [NICo chart values](https://github.com/dsx-ai-factory/infra-controller/blob/main/helm/values.yaml)
- [RMS chart values](https://github.com/dsx-ai-factory/nv-rms/blob/main/helm/values.yaml)

## Step 3 — Install the DSX AI Factory chart

```bash
helm install dsx-ai-factory \
  oci://ghcr.io/rh-ecosystem-edge/dsx-ai-factory/charts/dsx-ai-factory \
  --version 0.1.0 \
  --namespace nico-system \
  --values values.yaml \
  --wait
```

## Step 4 — Configure MetalLB VIPs for provisioning services

NICo's provisioning services must be reachable by AI Factory nodes over the
provisioning network via **MetalLB LoadBalancer IPs**. OpenShift Routes cannot
carry UDP traffic, so DHCP (port 67) and DNS (port 53) require LoadBalancer
services — MetalLB is the mechanism.

Each service gets a LoadBalancer IP from a pool you allocate on the provisioning
network:

| Service | Port | Protocol | Purpose |
|---|---|---|---|
| `nico-api` | 443 | TCP | Core gRPC API; IP SAN in the TLS certificate |
| `nico-pxe` | 8080 | TCP | iPXE server and boot artifact serving |
| `unbound` | 53 | UDP+TCP | DNS for the `.forge` provisioning zone |
| `nico-dhcp` | 67 | UDP | DHCP for AI Factory nodes |
| `nico-ssh-console-rs` | 2222 | TCP | SSH console access to bare-metal nodes |

All four services share a single VIP using MetalLB's `allow-shared-ip`
annotation. Create an `IPAddressPool` and `L2Advertisement` in the
`metallb-system` namespace:

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: nico-provisioning
  namespace: metallb-system
spec:
  addresses:
    - <provisioning-network-vip>/32   # e.g. 192.168.10.100/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: nico-provisioning
  namespace: metallb-system
spec:
  ipAddressPools:
    - nico-provisioning
  # Restrict advertisement to the provisioning network interface
  interfaces:
    - <provisioning-nic>              # e.g. ens1f0
```

```bash
oc apply -f metallb-provisioning.yaml
```

> **OVN gateway requirement:** With OpenShift's default shared-gateway OVN
> mode, VIP traffic on a secondary NIC is silently dropped unless local-gateway
> mode is enabled. Patch the cluster network operator if not already set at
> install time:
> ```bash
> oc patch network.operator cluster --type merge \
>   -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'
> oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes
> ```

> **DHCP relay:** DHCP relay is required when the provisioning VLAN is
> L3-separated from the management cluster. See
> [Network prerequisites](../00-network-prerequisites/#dhcp-relay) for the
> full relay configuration and the conditions under which it can be omitted.

Once the pool is created, set the `loadBalancerIP` for each service in your
`values.yaml`:

```yaml
nico:
  nico-api:
    service:
      loadBalancerIP: <provisioning-network-vip>
      annotations:
        metallb.universe.tf/allow-shared-ip: nico-provisioning
  nico-pxe:
    service:
      loadBalancerIP: <provisioning-network-vip>
      annotations:
        metallb.universe.tf/allow-shared-ip: nico-provisioning
  unbound:
    service:
      loadBalancerIP: <provisioning-network-vip>
      annotations:
        metallb.universe.tf/allow-shared-ip: nico-provisioning
  nico-dhcp:
    service:
      loadBalancerIP: <provisioning-network-vip>
      annotations:
        metallb.universe.tf/allow-shared-ip: nico-provisioning
```

Verify the VIPs are assigned and reachable from a host on the provisioning network:

```bash
VIP=<provisioning-network-vip>
nc -vz $VIP 443          # NICo Core API
nc -vz $VIP 8080         # PXE server
dig @$VIP example.local  # DNS
```

## Step 5 — Verify the installation

```bash
# Check all pods are running
oc get pods -n nico-system

# Verify NICo REST API is healthy (port 8388, not the gRPC VIP port 443)
oc port-forward -n nico-system svc/nico-rest-api 8388:8388 &
curl -k https://localhost:8388/api/v1/health

# Verify RMS pods are running
oc get pods -n nico-system -l app.kubernetes.io/name=rack-manager
```

## Next steps

With NICo and RMS running, proceed to:
- [Deploying RHEL](../02-rhel/) — provision RHEL on AI Factory compute nodes
- [Deploying OpenShift](../03-openshift/) — install OpenShift on the nodes
