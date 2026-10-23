---
title: "Deploying site infrastructure and Vault"
weight: 4
---

This is the **site tier**: the controller that runs next to the hardware.
Where the cloud tier is the shared central API, the
site tier is what actually talks to the machines in one datacenter.

The site infrastructure layer runs in the `nico-system` namespace and provides
the secrets management, messaging, and database services for NICo Core.

This page covers the **backbone of state and secrets** that the site depends on,
laid down before NICo Core itself:

- **HashiCorp Vault** is the secrets store and the site's certificate authority (PKI).
- **Crunchy PostgreSQL** (`nico-site-pg`) holds the persistent state for the site plane.
- **NATS** is the messaging bus for NICo's internal events.

![NICo site infrastructure](/images/site-infra.png)

Like the cloud infra step, this layer carries no network configuration yet. Your
VIPs, subnets, and `nico-dhcp` settings enter later, in the `deploy-site` step
with your own `nico-core` values. Here we only lay the plumbing.

The site comes up in three steps, in this order:

```
deploy-site-infra   →   vault-init   →   deploy-site
(Vault, PG, NATS)       (init/unseal,     (NICo Core, with
                         PKI, auth)        your network config)
```

> **Vault starts sealed, and this is expected.** After `deploy-site-infra` the
> Vault pods are `Running` and sealed: the infrastructure
> is in place, but the init and unseal ceremony has not happened yet. `vault-init`
> (Step 2) brings it to life. Do not deploy NICo Core until `vault-init` has
> completed, because Core requests certificates from Vault at startup and will
> crash-loop if Vault is absent or sealed.

## Step 1 — Deploy site infrastructure

```bash
make deploy-site-infra
```

This runs:
```bash
helm upgrade --install -n nico-system nico-site-infra \
  charts/site-infra/ \
  --create-namespace --timeout 15m
```
The Vault topology adapts to the cluster: a 3-node Raft HA cluster on a
multi-node cluster.

The chart creates:

| Resource | Purpose |
|---|---|
| Vault StatefulSet | HA Raft cluster for PKI and secrets |
| NATS | Messaging bus for NICo internal events |
| Crunchy PG cluster (`nico-site-pg`) | Site-plane databases (`nico`, and Flow's `flow`, `psm`, `nsm`) |
| `site-issuer` ClusterIssuer | cert-manager CA issuer that mints Vault's own TLS certs |
| Vault TLS certificates | Server and Raft mTLS certs for Vault, via cert-manager |
| ESO ExternalSecrets | Database and Vault credential wiring |

Wait for the Vault pods to reach `Running`:

```bash
oc get pods -n nico-system -l app.kubernetes.io/name=vault
```

All three pods (`vault-0`, `vault-1`, `vault-2`) must be running before
proceeding. They will show as `Running` but **sealed** until `vault-init` runs.

## Step 2 — Initialize Vault (one-time)

In the previous step Vault came up sealed and empty, so it cannot do anything
yet. `vault-init` is the one-time command that turns Vault into NICo's root of
trust for the site.

![Vault init](/images/vault-init.png)

```bash
make vault-init
```
It does four things:

1. **Initializes and unseals Vault.** A fresh Vault generates an unseal key and a
   root token. 
2. **Seeds the hardware credential store.** The KV engine (`secrets/`) is loaded
   with the factory-default credentials NICo uses to log into machines over
   Redfish: the default BMC and DPU usernames and passwords.
3. **Sets up the PKI engine (`nicoca`), the big one.** The same root CA created at
   the very start of the deployment is imported into Vault, so Vault becomes the
   online certificate authority for the site. Two roles are defined: `nico-cluster`,
   which issues the mTLS certificates every NICo service uses to talk to each other,
   and `nico-cli-client`, which issues short-lived client certs for the admin CLI.
   cert-manager still issues the cloud-tier certs and Vault's own TLS, because
   Vault cannot sign the certificate it needs in order to boot.
4. **Wires up authentication.** Kubernetes auth and an AppRole are configured so
   NICo Core and the Flow components can log into Vault to read their secrets and
   request certificates. 

After this, Vault is alive, unsealed, and fully configured: it holds the hardware
credentials, it is the CA signing all the service certs, and NICo knows how to
authenticate to it. Once the `vault-nico-issuer` ClusterIssuer is `Ready`, the
later `deploy-site` step can issue each NICo component (`nico-api`, `nico-pxe`,
and so on) its mTLS certificate automatically.

> **This is idempotent.** If Vault is already initialized, `vault-init` only
> unseals any sealed replicas and skips the rest, so it is safe to re-run after
> pod restarts.

### Override the default hardware credentials

`vault-init` seeds factory defaults (for example BMC `root` / `0penBmc`) so the
site works out of the box in a lab. For a real deployment, overwrite the default
site BMC credentials with your own before onboarding hardware:

```bash
NS=nico-system
V=vault-0
RT=$(oc get secret vault-unseal-secret -n $NS \
  -o jsonpath='{.data.root-token}' | base64 -d)

oc exec $V -n $NS -c vault -- sh -c "
  export VAULT_TOKEN=$RT VAULT_SKIP_VERIFY=true
  printf '{\"UsernamePassword\":{\"username\":\"<bmc-username>\",\"password\":\"<bmc-password>\"}}' \
    | vault kv put secrets/machines/bmc/site/root -"
```

> **The `secrets/machines/bmc/site/root` path is the site-wide default** applied
> to any machine without a per-machine override. NICo's
> site-explorer will fail to authenticate to BMCs if this secret is absent.
> Per-machine credentials can be added later under `secrets/machines/bmc/site/<serial-number>`.

## Step 3 — Connect with nico-admin-cli (mTLS)

`nico-admin-cli` is the administrative client for NICo Core. It talks to the
`nico-api` service over a **mutual-TLS gRPC** connection: the CLI runs on your
workstation and connects to the `nico-api` Pod through the `nico-api-grpc`
passthrough Route. Because the Route is passthrough, the TLS handshake happens
end to end between the CLI and the Pod, so the client certificate reaches
`nico-api` intact.

The `scripts/cli/nico-admin-cli` wrapper runs the CLI from a container image, so
you do not need to install the binary locally. You only provide two things: the
mTLS material and the API endpoint.

### Issue the mTLS material

Issue a short-lived (24h) client certificate from Vault:

```bash
make vault-admin-cert
```

This writes three files to `~/.nico/`:

- `admin-tls.crt` is the client leaf certificate (your identity).
- `admin-tls.key` is the private key (mode 600).
- `admin-ca.crt` is the CA that verifies the `nico-api` server certificate.

### Run the CLI

Point `API_URL` at the `nico-api` gRPC endpoint and run any subcommand through
the wrapper:

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')

API_URL=https://nico-api-grpc-nico-system.${CLUSTER_DOMAIN} \
  scripts/cli/nico-admin-cli expected-machine show
```

The `API_URL` host must match a SAN on the `nico-api` serving certificate, which
is why the Route host (added as a SAN by `deploy-site`) is used here.

> **Re-run `make vault-admin-cert` every 24 hours** or when the certificate
> expires. An expired certificate shows up as a TLS error from the CLI.

## Verify

```bash
# Vault cluster status (should report sealed: false, initialized: true)
oc exec vault-0 -n nico-system -- \
  vault status -tls-skip-verify -format=json | python3 -m json.tool

# NATS
oc get pods -n nico-system -l app.kubernetes.io/name=nats

# Site PostgreSQL
oc get postgrescluster nico-site-pg -n nico-system
oc get pods -n nico-system \
  -l postgres-operator.crunchydata.com/cluster=nico-site-pg

# Secrets and PKI wiring
oc get externalsecrets -n nico-system
oc get clusterissuer site-issuer vault-nico-issuer
oc get certificate -n nico-system
```

Vault should report `sealed: false`, the Postgres and NATS pods should be
`Running`, and both ClusterIssuers should be `Ready` before proceeding.

## Next steps

With Vault unsealed and acting as the site CA, proceed to
[Deploying NICo Core](../04-nico-core/), the `deploy-site` step that finally
installs NICo itself, this time with your network configuration.