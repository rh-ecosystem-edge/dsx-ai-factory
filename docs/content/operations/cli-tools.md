---
title: "CLI tools"
weight: 1
---

Both CLI tools ship as containerised wrappers in `scripts/cli/`. They use the
images already built and published by this repository — no local Go or Rust
toolchain required. Podman is preferred; Docker is used if Podman is not found.
Override with `CONTAINER_RUNTIME=docker`.

## nico-admin-cli

Manages the NICo **site plane**: machine registration, instance allocation,
maintenance mode, and day-2 operations on `nico-api`.

### Setup (one-time)

Issue a client certificate from Vault using `make vault-admin-cert` (valid 24
hours, re-run when expired). The certificate and CA are written to
`~/.config/nico/`:

```
~/.config/nico/
  nico-root-ca.crt     CA that signed the nico-api server cert
  nico-admin-cli.crt   admin client leaf cert
  nico-admin-cli.key   admin client private key
```

Find the `nico-api` endpoint — the passthrough route created by `make deploy-site`:

```bash
oc get route nico-api-grpc -n nico-system -o jsonpath='{.spec.host}'
```

Set `API_URL` to the route host on port 1079:

```bash
export API_URL=https://$(oc get route nico-api-grpc -n nico-system \
  -o jsonpath='{.spec.host}'):1079
```

For local development without a DNS-resolvable SAN, use `NICO_ADMIN_CLI_ADD_HOST`
to map the SAN onto a port-forward:

```bash
# Terminal 1
oc port-forward -n nico-system svc/nico-api 1079:1079

# Terminal 2
export API_URL=https://nico-api.nico-system.svc.cluster.local:1079
export NICO_ADMIN_CLI_ADD_HOST=nico-api.nico-system.svc.cluster.local:127.0.0.1
```

### Usage

```bash
# Run via wrapper (auto-mounts ~/.config/nico/)
API_URL=https://... scripts/cli/nico-admin-cli machine show
API_URL=https://... scripts/cli/nico-admin-cli expected-machine show
API_URL=https://... scripts/cli/nico-admin-cli instance show
```

### Install to PATH

```bash
ln -s "$(pwd)/scripts/cli/nico-admin-cli" ~/.local/bin/nico-admin-cli
# then:
API_URL=https://... nico-admin-cli machine show
```

---

## nicocli

Manages the NICo **REST plane**: operating system definitions, instance types,
site management, and tenant operations via the REST API.

### Setup (one-time)

Save the OCP ingress CA so `nicocli` can verify the Keycloak and REST API TLS
certificates:

```bash
oc get secret router-ca -n openshift-ingress-operator \
  -o jsonpath='{.data.tls\.crt}' | base64 -d \
  > ~/.config/nico/ocp-ingress-ca.crt
```

### Usage

With `KUBECONFIG` set, the wrapper auto-detects the Keycloak URL and REST API
URL from the cluster and fetches the OIDC client secret from the Keycloak admin
API:

```bash
KUBECONFIG=~/.kube/config scripts/cli/nicocli machine list
KUBECONFIG=~/.kube/config scripts/cli/nicocli operating-system create \
  --name rhcos-worker
```

To skip cluster auto-detection, set the URLs explicitly:

```bash
export NICO_KC_URL=https://keycloak-rhbk-operator.<cluster-domain>
export NICO_BASE_URL=https://nico-rest-api-nico-rest.<cluster-domain>
export NICO_CLIENT_SECRET=<secret>
scripts/cli/nicocli machine list
```

### Install to PATH

```bash
ln -s "$(pwd)/scripts/cli/nicocli" ~/.local/bin/nicocli
KUBECONFIG=~/.kube/config nicocli machine list
```
