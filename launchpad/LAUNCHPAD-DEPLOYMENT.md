# LaunchPad GB300 NVL72 — NICo + DPF Zero Trust Deployment Guide

Deployment procedure and manual steps for running NICo with DPF Zero Trust
DPU provisioning on the LaunchPad GB300 NVL72 environment (tray-6/tray-7,
real BlueField-3 hardware). Covers what's automated, what needs a human,
and every workaround required to get there — written after first reaching
all 4 DPU services `Ready`/`Success` on 2026-11-26.

---

## Architecture summary

NICo owns DPU provisioning instead of DPF (`[dpf] enabled = true` in NICo's
site config). DPF still owns the platform (operator, HostedControlPlane),
but reconciles whatever `DPUDeployment`/`DPUFlavor`/`DPUServiceTemplate`
objects NICo creates, rather than creating its own. This requires
`NICO_ENABLED=true` on the openshift-dpf automation side too, so DPF doesn't
create a competing deployment.

4 DPU-side services are mandatory and run **on the DPU itself**:
`nico-dpu-agent`, `nico-dhcp-server`, `nico-fmds`, `nico-otelcol`. These are
**not** part of NICo's normal chart set — they ship via DPF's
`DPUServiceTemplate` mechanism, configured per-service in
`charts/values/generated/nico-core-launchpad.yaml` under
`[dpf.services.<name>]`.

DPF's `DPUServiceTemplate` CRD requires `spec.helmChart.source.repoURL` to
start with `https://` or `oci://` (**not** `http://` — rejected at
Kubernetes admission time), and has **no** field for custom CA trust or
registry credentials. The default NGC registries
(`helm.ngc.nvidia.com/.../carbide-dev`, `nvcr.io/.../carbide-dev`) return
HTTP 403 without an entitlement this environment doesn't have, so the 4
charts and their images need a different, reachable source.

**Chart source:** `oci://ghcr.io/szigmon/nico-dpf-fixed-charts` — public
GHCR packages, one per service, real CA-trusted TLS. See
[Why GHCR, not quay or a self-hosted repo](#why-ghcr-not-quay-or-a-self-hosted-repo)
below for why.

**Image source:** `quay.io/szigmon/nico` (multiple services share one repo,
distinguished by tag) — these are pre-built, already-working images
recovered from an earlier lab run, not rebuilt from source for this
deployment.

DPF itself runs OpenShift GitOps (ArgoCD) under the hood — in the
`openshift-gitops` namespace, **not** a namespace literally called
`argocd`. Before creating the ArgoCD `Application` that actually deploys
each service, DPF's own controller does a **native pre-check**: it fetches
the chart's `index.yaml` directly to validate the `DPUServiceTemplate`. That
pre-check is what fails on an untrusted/self-signed cert, and it happens
**before** ArgoCD ever gets involved — which is why getting a
properly-trusted cert for the chart source matters regardless of ArgoCD.

---

## Important: which NICo Core image this was validated against

`make deploy-site` doesn't currently pass `IMAGE_TAG`, so the Core chart
silently falls back to the placeholder `v0.0.1` tag — which, as of
2026-11-26, resolves to a `nico-core` build from **2026-10-22**
(`ghcr.io/rh-ecosystem-edge/dsx-ai-factory/infra-controller-core:v0.0.1`,
commit `5b5089df0`). This predates PR #2 (the main NICo+external-DPF
integration work, merged 2026-11-12) and PR #3. Everything in this guide
was validated against that Oct 22 binary — it proves the configuration and
chart-delivery approach works, **not** that PR #2/#3 or the combined
`openshift-dpf` automation PR specifically work, since that code wasn't
running. To actually exercise those, rebuild and push a `nico-core` image
from the intended branch/commit and set `global.image.repository`/tag
accordingly, or pass `IMAGE_TAG` explicitly to `deploy-site`.

## Prerequisites (must already be true before deploying)

- DPF Zero Trust platform installed (`dpf-operator-system` namespace
  exists, standalone `dpudeployment`/`flavor-zt` objects present from the
  platform install — these are DPF's own, pre-existing, and
  `nico-deployment-v2`/NICo's own flavor must never collide with them)
- `NICO_ENABLED=true` set on the openshift-dpf automation side
  (`NICO_DPU_DEPLOYMENT_NAME=nico-deployment-v2`, matching the deployment
  name NICo's own TOML config uses)
- DHCP relay configured on both CSL switches (`sn5600-csl-01`/`-02`) —
  `server-group` pointing at NICo's `nico-dhcp` MetalLB VIP (`172.16.3.251`
  in this environment). **Two separate pieces of config are required**, not
  one — see [DHCP relay](#dhcp-relay-two-pieces-of-config-not-one) below.
- MetalLB per-service VIPs for `nico-api`/`nico-dhcp`/`nico-dns`/`nico-pxe`
  reachable on the same subnet as the DPU p0 interfaces
  (`172.16.3.0/24` in this environment)
- The 4 GHCR packages under `ghcr.io/szigmon/nico-dpf-fixed-charts` are
  **public** (see [Manual step: GHCR visibility](#manual-step-ghcr-package-visibility))

---

## Deploy procedure

```bash
cd dsx-ai-factory-nico-next
./launchpad-e2e-deploy.sh
```

This runs, in order: prerequisites (`METALLB_MODE=dpf` — see
[the METALLB_MODE gotcha](#gotcha-metallb_mode-must-be-passed-to-both-targets)) →
site-infra → `vault-init` → NICo Core deploy with
`charts/values/generated/nico-core-launchpad.yaml` → health check → report
DPF/DPU object state.

It deliberately does **not** run the expected-machine registration step —
see [Manual step: expected-machine registration](#manual-step-expected-machine-registration-point-of-no-return).

### If `nico-core` is already deployed and just needs the values update

```bash
export PATH="$(pwd)/scripts/kustomize-post-renderer:$PATH"
helm upgrade nico-core components/infra-controller/helm -n nico-system \
  --reuse-values -f charts/values/generated/nico-core-launchpad.yaml \
  --post-renderer kustomize-post-renderer --wait --timeout 8m
```

`--reuse-values` is important — it preserves whatever `--set` flags an
earlier deploy used (e.g. certificate DNS names, image registry overrides)
that aren't captured in the values files themselves.

**Run this detached if going over SSH through a proxy** (Pomerium-style
bastion access can drop idle sessions mid-upgrade):

```bash
nohup helm upgrade ... > /tmp/nico-core-upgrade.log 2>&1 < /dev/null & disown
```

then poll `/tmp/nico-core-upgrade.log` from a fresh connection.

### Verify it worked

```bash
oc get dpuservicetemplate -n dpf-operator-system \
  -o custom-columns=NAME:.metadata.name,RECONCILED:'.status.conditions[?(@.type=="DPUServiceTemplateReconciled")].reason'

oc get applications.argoproj.io -n dpf-operator-system | grep carbide

oc get dpuservice -A | grep -E 'dhcp-server|dpu-agent|fmds|otelcol'
```

All 4 templates should show `Reconciled: Success`, 8 ArgoCD Applications
(2 per service — per-flavor variants) should show `Synced`/`Healthy`, and 8
`DPUService` objects should show `READY=True PHASE=Success`.

---

## Manual steps

### Manual step: GHCR package visibility

New GHCR packages default to **private**. DPF's chart-fetch mechanism has
no authentication option, so these must be public:

```bash
gh api --method PATCH "/user/packages/container/nico-dpf-fixed-charts%2Fnico-dpu-agent" -f visibility=public
gh api --method PATCH "/user/packages/container/nico-dpf-fixed-charts%2Fnico-dhcp-server" -f visibility=public
gh api --method PATCH "/user/packages/container/nico-dpf-fixed-charts%2Fnico-fmds" -f visibility=public
gh api --method PATCH "/user/packages/container/nico-dpf-fixed-charts%2Fnico-otelcol" -f visibility=public
```

If `gh api` returns 404 despite being logged in as the right account, it's
almost always a token-scope issue (`write:packages`/`delete:packages`
missing) — either `gh auth refresh -s write:packages,delete:packages`, or
use the web UI directly: each package's Settings page → Danger Zone →
Change visibility → Public → confirm by typing the package name.
Visibility changes can take a minute or two to propagate — if a check right
after changing it still shows `private`, wait and recheck before assuming
it failed.

### Manual step: nico-dhcp MAC allowlist

Restricts `nico-dhcp`'s Kea server to only answer known DPU p0 MACs — not
strictly required (dnsmasq doesn't conflict on this bastion, see above),
but recommended defense-in-depth before expected-machine registration.
`nico-dhcp-config`'s actual key is `kea_config.json` (not `kea-dhcp4.conf`,
despite some older docs referencing that name):

```bash
oc get configmap nico-dhcp-config -n nico-system -o json > /tmp/current-kea-config.json
python3 - <<'PYEOF'
import json
with open("/tmp/current-kea-config.json") as f:
    cm = json.load(f)
kea = json.loads(cm["data"]["kea_config.json"])
kea["Dhcp4"]["client-classes"] = [{
    "name": "known-dpus",
    "test": "substring(hexstring(pkt4.mac,':'),0,17) == 'e0:9d:73:87:03:70' or substring(hexstring(pkt4.mac,':'),0,17) == 'e0:9d:73:86:d4:52'",
    "only-if-required": False
}]
kea["Dhcp4"]["subnet4"][0]["pools"][0]["client-class"] = "known-dpus"
kea["Dhcp4"]["subnet4"][0]["reservations"] = [
    {"hw-address": "e0:9d:73:87:03:70", "ip-address": "172.16.3.240", "hostname": "tray-6-dpu"},
    {"hw-address": "e0:9d:73:86:d4:52", "ip-address": "172.16.3.241", "hostname": "tray-7-dpu"}
]
cm["data"]["kea_config.json"] = json.dumps(kea)
with open("/tmp/patched-kea-config.json", "w") as f:
    json.dump(cm, f)
PYEOF
oc apply -f /tmp/patched-kea-config.json
oc rollout restart deployment/nico-dhcp -n nico-system
oc rollout status deployment/nico-dhcp -n nico-system --timeout=90s
```

Applied and verified live on 2026-11-26 — `nico-dhcp` came back healthy
with the allowlist active.

### Manual step: Vault BMC credential seeding (not yet done)

`secrets/machines/bmc/` only has a generic `site/root` entry as of
2026-11-26 — none of the 8 per-MAC credentials (4 DPU + 4 host, tray-6/7)
are seeded. This needs the real site BMC passwords and is deliberately left
for a human to do, not automated:

```bash
export VAULT_NS=nico-system
export VAULT_POD=vault-0
VAULT_TOKEN=$(oc get secret vault-unseal-secret -n $VAULT_NS -o jsonpath='{.data.root-token}' | base64 -d)

for MAC in "e0:9d:73:87:03:85" "E0:9D:73:87:03:85" \
           "e0:9d:73:86:d4:67" "E0:9D:73:86:D4:67"; do
  oc exec $VAULT_POD -n $VAULT_NS -- sh -c \
    "export VAULT_TOKEN=$VAULT_TOKEN VAULT_SKIP_VERIFY=true && \
     printf '{\"UsernamePassword\":{\"username\":\"root\",\"password\":\"<REAL_DPU_BMC_PASSWORD>\"}}' \
     | vault kv put secrets/machines/bmc/$MAC/root -"
done
# Repeat with the host BMC MACs/credentials (admin user, host BMC password).
```

Replace `<REAL_DPU_BMC_PASSWORD>` with the actual site credential — never
commit a real password into this file or any script.

### Manual step: expected-machine registration (point of no return)

Registering `compute-tray-6-dpu`/`compute-tray-7-dpu` and their host BMCs
via `POST /v2/org/ncx/nico/expected-machine` can trigger an **automatic
power-cycle of the real tray hardware**. Never run this as part of an
automated script. Confirm, before running it:

1. The 8 `DPUService` objects are `Ready`/`Success` (this deployment guide,
   above)
2. `nico-dhcp`'s Kea config has the MAC allowlist + `.240`/`.241`
   reservations for the two DPU p0 MACs
3. Vault has all 8 BMC MAC credentials seeded
   (`secrets/machines/bmc/<mac>/root`)

Exact payloads are in the site's network-config runbook (DPU + host BMC
registrations with real serials/MACs/IPs) — not duplicated here since they
contain site-specific hardware identifiers.

---

## Workarounds and fixes applied (and why)

### The original failure

`nico-api` was `CrashLoopBackOff` for 22+ hours:
```
DPUServiceTemplate.svc.dpu.nvidia.com "carbide-dhcp-server" is invalid:
spec.helmChart.source.version: Invalid value: "": should be at least 1 chars long
```
Root cause: `[dpf] enabled = true` was set, but none of the 4
`[dpf.services.*]` blocks had explicit `helm_version`/image overrides. The
Rust default (`COMPILE_TIME_HELM_VERSION`, baked in by NVIDIA's internal
CI) is empty when the image is built outside that pipeline.

**Fix:** explicit `helm_repo_url`/`helm_chart`/`helm_version`/
`docker_repo_url`/`docker_image_tag` for all 4 services in
`nico-core-launchpad.yaml`. This alone fixed the crash loop.

### Gotcha: `METALLB_MODE` must be passed to both targets

`make deploy-prereqs` and `make deploy-all-site` are separate `make`
invocations. `METALLB_MODE` defaults to `standalone` — if it's only passed
to `deploy-all-site`, `deploy-prereqs` installs a redundant MetalLB that
conflicts with DPF's. Pass `METALLB_MODE=dpf` to **both**.

### Why GHCR, not quay or a self-hosted repo

Three approaches were tried, in this order:

1. **Self-hosted in-cluster chart repo** (plain nginx + ConfigMap, recreating
   a pattern that worked on an earlier lab cluster). Charts recovered from
   an Nov 8 cluster backup, repo deployed, confirmed serving correctly —
   but DPF's native pre-check rejected the fresh self-signed TLS cert
   (`x509: certificate signed by unknown authority`). NVIDIA documents an
   official fix for this
   (`DPFOperatorConfig.spec.provisioningController.customCASecretName`),
   and it worked when tested — but it's a change to DPF's own operator
   config, which this project deliberately avoids (DPF's config is tested
   as-is by the DPF Red Hat team; the whole point of the NICo integration
   is to change what NICo owns, not what DPF owns).
2. **quay.io** (`quay.io/szigmon/nico`, already used for images). Pushing a
   *new* chart as its own repo path failed with a clean 401 — the
   available credentials can write to the existing `nico` repo but can't
   auto-create new ones. Fixable (pre-create repos via the quay web UI, or
   grant the robot account org-level "create repository" rights) but not
   done.
3. **GHCR** (`ghcr.io/<user>/<new-path>`) — auto-creates a package on first
   push under a personal namespace, no pre-creation step. Confirmed working
   immediately. Real CA-trusted cert, so DPF's pre-check passes with zero
   DPF-side configuration. This is what's actually deployed.

If quay's permissions are ever fixed, the charts could move there with no
functional difference — GHCR won on registry *permissions*, not on any
property of the chart content itself.

### `nico-dpu-agent` chart fix — ported upstream, not just worked around

The Nov 8 lab-proven `nico-dpu-agent` chart (`0.1.11`) has a feature
(`xplaneMaintenance`, Spectrum-X maintenance socket access) that was never
merged back into the committed chart source in
`rh-ecosystem-edge/infra-controller` (`bluefield/charts/nico-dpu-agent`,
still at `0.1.5` there). The committed chart had the container-level
`volumeMounts` for this feature already wired in `daemonset.yaml`, but the
pod-level `hostPath` volumes backing them were missing entirely, and
`values.yaml`/`values.schema.json` had no default/schema for it — meaning
enabling the feature as committed would render a broken DaemonSet. Fixed
in <https://github.com/rh-ecosystem-edge/infra-controller/pull/3> (open,
unmerged as of this writing). This PR doesn't affect what's actually
deployed on LaunchPad — the deploy uses the already-verified lab-proven
chart (now published on GHCR) directly, independent of whether PR #3
merges.

**Not touched, deliberately:** `nico-dhcp-server` and `nico-fmds`'s
committed chart source is already *ahead* of what was lab-tested (newer
VPC-NAD templates, untested here). `nico-otelcol`'s committed chart has an
entire `puntStatsHelper` sidecar feature the lab build never had. Porting
either "forward" would introduce untested behavior — left alone.

### dnsmasq: verified, not needed

The network-config runbook describes a DPU-MAC ignore-rule requirement for
dnsmasq (to prevent it answering DHCP for DPU p0 interfaces instead of
NICo's own DHCP). On this bastion, verified unnecessary: dnsmasq's
`dhcp-range`s only cover `172.16.0.x`/`172.16.2.x`, it's bound to
`bind-interfaces` + explicit `listen-address` (`127.0.0.1`, `172.17.0.1`,
`172.16.0.1` — nothing on `172.16.3.0/24`), and the DHCP relay unicasts
directly to NICo's VIP (`172.16.3.251`), which dnsmasq never listens on.
There's no path for dnsmasq to ever see or answer a DPU DHCP request here.
Re-verify if dnsmasq's config changes.

### DHCP relay: two pieces of config, not one

Configuring `nv set service dhcp-relay INBAND server-group ...
upstream-interface ... downstream-interface ...` is not sufficient on its
own. A separate toggle is also required:

```bash
nv set service dhcp-relay INBAND agent state enabled
nv config apply
```

Without it, the relay config exists but doesn't actually relay anything.
Check `nv show service dhcp-relay INBAND` for both the `server-group`/
interface config **and** the `agent > state` field.

### SSH/Pomerium session drops kill unguarded remote processes

Long-running remote commands (helm upgrades with multi-minute `--wait`
timeouts) can be killed mid-flight if the SSH session drops (observed with
this bastion's Pomerium-based access). Always run long commands detached:

```bash
nohup <command> > /tmp/output.log 2>&1 < /dev/null & disown
```

then poll the log file from a fresh connection — never rely on a single
SSH session staying open for more than a couple of minutes.

### Helm release stuck in `pending-upgrade` after a killed process

If an upgrade gets killed mid-flight (session drop, manual interrupt), the
Helm release can get stuck in `pending-upgrade`, blocking any further
`helm upgrade` with `another operation ... is in progress`. Fix:

```bash
helm rollback nico-core <last-known-good-revision> -n nico-system
```

`helm history nico-core -n nico-system` shows which revision was last
actually `deployed`. A release in plain `failed` status (not
`pending-upgrade`) does **not** need this — `helm upgrade` can proceed
directly from `failed`.
