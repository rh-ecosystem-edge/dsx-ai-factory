---
title: "Deploying site infrastructure and Vault"
weight: 3
---

The site infrastructure layer runs in the `nico-system` namespace and provides
the secrets management, messaging, and database services for NICo Core:
HashiCorp Vault HA (3-node Raft), NATS, and a Crunchy PostgreSQL site database.

> **Vault initialization (`make vault-init`) must complete before NICo Core is
> deployed.** NICo Core requests certificates from Vault at startup and will
> crash-loop if Vault is absent or sealed.

## Step 1 — Deploy site infrastructure

```bash
make deploy-site-infra
```

This runs:
```bash
helm upgrade --install -n nico-system nico-site-infra \
  charts/site-infra/ \
  --create-namespace --timeout 15m \
  --post-renderer scripts/deploy/kustomize-post-renderer
```

The chart creates:

| Resource | Purpose |
|---|---|
| Vault StatefulSet (3 replicas) | HA Raft cluster for PKI and secrets |
| NATS | Messaging bus for NICo internal events |
| Crunchy PG cluster (site) | NICo Core database (`nico` DB, site schema) |
| ESO ExternalSecrets | Vault credentials injection |
| Vault TLS certificates | mTLS between Vault nodes (via cert-manager) |

Wait for the Vault pods to reach `Running`:

```bash
oc get pods -n nico-system -l app.kubernetes.io/name=vault
```

All three pods (`vault-0`, `vault-1`, `vault-2`) must be running before
proceeding. They will show as `Running` but **sealed** until `vault-init` runs.

## Step 2 — Initialize Vault (one-time)

Vault initialization is a **one-time operation per cluster**. It:
1. Initializes the Raft cluster (1-of-1 key shares for simplicity)
2. Stores the unseal key and root token in a Kubernetes Secret
3. Restarts and auto-unseals all Vault replicas
4. Enables the PKI secrets engine (`nicoca`) and creates the NICo CA
5. Configures AppRole auth for NICo services
6. Creates the KV secrets engine for BMC credentials

```bash
make vault-init
```

> **This is idempotent** — if Vault is already initialized, `vault-init` only
> unseals sealed replicas and skips the rest. Safe to re-run after pod restarts.

### Seed BMC credentials

After Vault is initialized, seed the default BMC credentials that NICo uses
when a machine does not have per-machine credentials registered:

```bash
NS=nico-system
V=vault-0
RT=$(oc get secret vault-unseal-secret -n $NS \
  -o jsonpath='{.data.root-token}' | base64 -d)

# Default BMC credentials (applied to all machines without per-machine override)
oc exec $V -n $NS -- sh -c "
  VAULT_TOKEN=$RT VAULT_ADDR=https://vault.$NS:8200 VAULT_CACERT=/tmp/ca-bundle.pem \
  vault kv put secrets/machines/bmc/site/root \
    username=<bmc-username> \
    password=<bmc-password>"
```

> **The `secrets/machines/bmc/site/root` path is required.** NICo's
> site-explorer will fail to authenticate to BMCs if this secret is absent.
> Per-machine credentials can be added later at
> `secrets/machines/bmc/site/<serial-number>`.

## Step 3 — Issue nico-admin-cli client certificate

`nico-admin-cli` connects to NICo Core over mTLS. Issue a short-lived (24h)
client certificate from Vault:

```bash
make vault-admin-cert
```

This writes three files to `~/.config/nico/`:
- `admin-tls.crt` — client leaf certificate
- `admin-tls.key` — private key (mode 600)
- `admin-ca.crt` — issuing CA certificate

The command also prints the full `nico-admin-cli` invocation with the correct
`--api-url`, `--client-cert-path`, `--client-key-path`, and
`--forge-root-ca-path` flags. **Copy and save this output** — the wrapper
script at `scripts/cli/nico-admin-cli` reads these files automatically.

> **Re-run `make vault-admin-cert` every 24 hours** or when the certificate
> expires. The `scripts/cli/nico-admin-cli` wrapper will show a TLS error
> when the certificate has expired.

## Verify

```bash
# Vault cluster status
oc exec vault-0 -n nico-system -- \
  vault status -tls-skip-verify -format=json | python3 -m json.tool

# NATS
oc get pods -n nico-system -l app.kubernetes.io/name=nats

# Site PostgreSQL
oc get pods -n nico-system -l postgresql.cnpg.io/cluster
```

All should show `Running` / `Ready` before proceeding.

## Next steps

Proceed to [Deploying NICo Core](../04-nico-core/) to install the NICo
site-plane services.
