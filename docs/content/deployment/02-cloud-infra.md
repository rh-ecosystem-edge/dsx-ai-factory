---
title: "Deploying cloud infrastructure"
weight: 2
---

The cloud infrastructure layer runs in the `nico-rest` namespace and provides
the database, authentication, and workflow services that NICo depends on:
Crunchy PostgreSQL (four databases), RHBK Keycloak, Temporal, OpenShift Routes,
and ESO ExternalSecrets.

> **This step must complete — including the post-install steps — before
> deploying NICo Core.** NICo Core connects to these services at startup and
> will crash-loop if they are absent.

## Step 1 — Deploy cloud infrastructure

```bash
make deploy-cloud-infra
```

This runs:
```bash
helm upgrade --install -n nico-rest nico-rest-infra \
  charts/cloud-infra/ \
  --create-namespace --wait --timeout 10m \
  --post-renderer scripts/deploy/kustomize-post-renderer
```

The chart creates:

| Resource | Namespace | Purpose |
|---|---|---|
| Crunchy PG cluster | `nico-rest` | Four databases: `nico`, `temporal`, `temporal_visibility`, `keycloak` |
| RHBK Keycloak instance | `rhbk-operator` | SSO / OIDC for NICo REST API and UI |
| RHBK Keycloak realm | `rhbk-operator` | `nico` realm with preconfigured clients |
| Temporal server | `nico-rest` | Durable workflow orchestration |
| OpenShift Routes | `nico-rest` | REST API and Keycloak external access |
| ESO ExternalSecrets | `nico-rest` | Keycloak client secret injection |

Verify all pods are running before proceeding:

```bash
oc get pods -n nico-rest
oc get pods -n rhbk-operator
```

## Step 2 — Patch Keycloak route

The Keycloak Route is backed by the RHBK operator's self-signed certificate.
OpenShift's router cannot verify it without the CA — the route returns HTTP 503
until the CA is injected:

```bash
make patch-keycloak-route
```

This reads the `nico-root-ca-secret` from the `cert-manager` namespace and
patches the Keycloak Route's `destinationCACertificate` field. Verify:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')
curl -sk https://keycloak-rhbk-operator.${CLUSTER_DOMAIN}/realms/nico \
  | python3 -m json.tool | grep realm
```

You should see `"realm": "nico"`.

## Step 3 — Bootstrap the organization

NICo requires an **Infrastructure Provider** and a default **Tenant** to be
created before any machines can be onboarded. This is a one-time bootstrap:

```bash
make bootstrap-org
```

This fetches a Keycloak admin token, retrieves the `ncx-service` OIDC client
secret, obtains a Bearer token for the NICo REST API, and calls the
`/v2/org/ncx/nico/infrastructure-provider` endpoint to create the provider and
tenant.

> **If `bootstrap-org` fails with a token error**, check that `patch-keycloak-route`
> completed successfully. A 503 from the Keycloak route is the most common cause.

## Step 4 — Deploy NICo REST plane

The NICo REST plane is the operator-facing API layer (machine registration,
instance management, site management):

```bash
make deploy-cloud
```

This installs the upstream `nico-rest` chart into the `nico-rest` namespace
using `charts/values/nico-rest.yaml` as the image override file.

Verify:

```bash
oc get pods -n nico-rest
oc port-forward -n nico-rest svc/nico-rest-api 8388:8388 &
curl -sk https://localhost:8388/api/v1/health
```

Or run all four steps in sequence:

```bash
make deploy-all-cloud
```

## Next steps

Proceed to [Deploying site infrastructure and Vault](../03-vault/) to set up
the site-plane dependencies before deploying NICo Core.
