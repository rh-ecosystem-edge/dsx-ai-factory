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
  --namespace dsx-ai-factory \
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
    # DHCP range for the provisioning network
    config:
      subnets:
        - subnet: "192.168.1.0/24"
          pools:
            - start: "192.168.1.100"
              end: "192.168.1.200"

  nico-api:
    # Database credentials (from Crunchy PG)
    database:
      host: nico-primary.dsx-ai-factory.svc
      name: nico

rack-manager:
  apiServer:
    database:
      host: rms-primary.dsx-ai-factory.svc
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
  --namespace dsx-ai-factory \
  --values values.yaml \
  --wait
```

## Step 4 — Verify the installation

```bash
# Check all pods are running
oc get pods -n dsx-ai-factory

# Verify NICo API is healthy
oc port-forward -n dsx-ai-factory svc/nico-rest-api 8388:8388 &
curl -k https://localhost:8388/api/v1/health

# Verify RMS API is healthy
oc port-forward -n dsx-ai-factory svc/rack-manager 8801:8801 &
curl http://localhost:8801/healthz
```

## Next steps

With NICo and RMS running, proceed to:
- [Deploying RHEL](../02-rhel/) — provision RHEL on AI Factory compute nodes
- [Deploying OpenShift](../03-openshift/) — install OpenShift on the nodes
