# DPF Zero Trust + NICo — Full From-Scratch Deployment

Everything needed to go from an empty OpenShift cluster to the state
reached on LaunchPad on 2026-11-26 (all 4 DPU services `Ready`/`Success`).
Combines the `openshift-dpf` platform-bootstrap automation with NICo's own
deploy (`launchpad/LAUNCHPAD-DEPLOYMENT.md`), in the order NVIDIA's own
integration design doc specifies
(`openshift-dpf/docs/nico-dpf-integration.md`).

**Read `LAUNCHPAD-DEPLOYMENT.md` first** — it covers the NICo-specific
architecture, workarounds, and manual steps in depth. This doc is the
missing piece before it: how to get the DPF platform itself installed in
NICo-integration mode in the first place.

---

## Stage 0 — Prerequisites

- An OpenShift cluster with cluster-admin access (SNO is fine — this is
  what LaunchPad uses)
- The `openshift-dpf` automation repo, branch with `NICO_ENABLED` support
  (`szigmon/openshift-dpf-official:feat/nico-zero-trust-combined`, PR #510)
- The `dsx-ai-factory` repo (this one), branch `feat/metallb-combined`
  (PR #20) — has NICo's Helm charts, values overlays, and the Launchpad
  site config already wired
- DHCP relay configured on the site's switches pointing at NICo's future
  `nico-dhcp` VIP (see `LAUNCHPAD-DEPLOYMENT.md`'s DHCP relay section — do
  this before DPU provisioning starts, order doesn't matter relative to
  the platform install itself)
- Real BMC credentials and network details for the target DPU hardware

---

## Stage 1 — DPF platform bootstrap (automated, `openshift-dpf`)

This is **NVIDIA's documented deployment sequence** for NICo-integration
mode, steps 1–2 (full doc: `docs/nico-dpf-integration.md` in that repo):

```bash
git clone <openshift-dpf fork/branch> openshift-dpf-nico
cd openshift-dpf-nico
# Configure .env:
#   DPF_DEPLOYMENT_MODE=zero-trust
#   NICO_ENABLED=true
#   NICO_DPU_DEPLOYMENT_NAME=nico-deployment-v2   # must match NICo's config exactly
#   (plus the usual Zero Trust settings: BFB registry, shared DPU BMC password, pull secrets)

make all-zt
```

**What this does in NICo mode** (per the design doc, and different from
standalone mode): installs the DPF operator, CRDs, `DPFOperatorConfig`,
BFB registry config, `DPUCluster`, and HCP provisioner — but **skips**
creating static DPU inventory, the BFB/flavor, and the `DPUDeployment`
itself, and **stops before hosted-cluster creation**. All of that is left
for NICo to create, by design — this is the ownership split.

**Don't run `make deploy-hosted-cluster` yet** — it needs NICo's
`DPUDeployment` to exist first (Stage 3).

---

## Stage 2 — NICo deploy (`dsx-ai-factory`)

Full detail in `LAUNCHPAD-DEPLOYMENT.md`. Summary:

```bash
cd dsx-ai-factory-nico-next
./launchpad-e2e-deploy.sh
```

Which runs: prerequisites (`METALLB_MODE=dpf` — required on **both** this
and the next target, see the gotcha in `LAUNCHPAD-DEPLOYMENT.md`) →
site-infra → `vault-init` → NICo Core deploy with
`charts/values/generated/nico-core-launchpad.yaml` (which has
`[dpf] enabled = true`, `deployment_name = "nico-deployment-v2"` matching
Stage 1's `NICO_DPU_DEPLOYMENT_NAME`, and the 4 `[dpf.services.*]` blocks
pointing at the public GHCR chart packages).

NICo's own startup now creates its `DPUDeployment`(s) — actually **two**,
`nico-deployment-v2` and `nico-deployment-v2-g` (generic BF3 + GB200/GB300-
class variant — this is intentional NICo behavior, not something to
suppress, see `dpf-nico-combined-prs-e2e-test-plan.md` §3a for the full
explanation), the BFB, flavor, and all 4 `DPUServiceTemplate`/
`DPUServiceConfiguration` objects per variant.

**Verify before continuing to Stage 3:**
```bash
oc get dpuservicetemplate -n dpf-operator-system \
  -o custom-columns=NAME:.metadata.name,RECONCILED:'.status.conditions[?(@.type=="DPUServiceTemplateReconciled")].reason'
oc get dpudeployment -n dpf-operator-system
```
All templates `Reconciled: Success`, both NICo DPUDeployments present.

---

## Stage 3 — Resume DPF automation (hosted cluster + authorization)

Back in the `openshift-dpf` checkout, now that NICo's `DPUDeployment`
exists:

```bash
make deploy-hosted-cluster
# wait for the hosted cluster API to come up, then:
make deploy-dpu-services
```

`deploy-hosted-cluster`'s HCP provisioner reads the `NICO_DPU_DEPLOYMENT_NAME`
you set in Stage 1 as its `dpuDeploymentRef` and creates the hosted
control plane against NICo's deployment (not a DPF-owned one).
`deploy-dpu-services` in NICo mode only applies the hosted-cluster DPF
authorization — it does **not** recreate NICo's service resources (NICo
already owns and created those in Stage 2).

---

## Stage 4 — Manual steps (not automated by either repo)

All covered in detail in `LAUNCHPAD-DEPLOYMENT.md`:

1. **GHCR package visibility** — the 4 DPU-service charts must be public
   (`ghcr.io/szigmon/nico-dpf-fixed-charts/*`), or rebuild/republish your
   own set and point `nico-core-launchpad.yaml` at them.
2. **nico-dhcp MAC allowlist** — recommended defense-in-depth, exact patch
   script included.
3. **Vault BMC credential seeding** — needs the real site BMC passwords,
   deliberately manual.
4. **Expected-machine registration** (point of no return — can power-cycle
   real tray hardware) — only after 1–3 above are confirmed, with a human
   watching.

---

## Known open gap (from NVIDIA's own design doc — read before claiming "done")

`docs/nico-dpf-integration.md` states explicitly: *"this ownership split
has not yet passed an end-to-end test with an x86 worker already installed
by OpenShift... A supported NICo mode for adopting an externally
provisioned host... is required before this integration is considered safe
to deploy end to end. DPU readiness alone does not close this gap."*

Concretely: if the x86 host NICo is meant to manage already has OpenShift
installed on it (vs. being freshly discovered), NICo's `WaitingForDiscovery`
→ `WaitingForCleanup` path can request a destructive storage wipe against
that already-running worker. This has bitten real runs before (see
`dpf-nico-lab-workarounds-and-prs.md`, step 20: `nico-api` was scaled to
zero specifically to stop this from happening to an adopted host). Do not
assume DPU `Ready`/`Operational` alone means the host-adoption side is
safe — check the host's own NICo lifecycle state before letting it proceed
past `WaitingForDiscovery`.

---

## Quick reference — what each repo owns

| Concern | Owner | Repo |
|---|---|---|
| DPF operator, CRDs, `DPFOperatorConfig`, BFB registry, HCP provisioner | DPF automation | `openshift-dpf` |
| DPU inventory, BFB, DPUFlavor, `DPUDeployment`, DPUServiceTemplates | NICo | `dsx-ai-factory` (NICo config) |
| Hosted cluster creation, hosted-cluster DPF authorization | DPF automation (after NICo's deployment exists) | `openshift-dpf` |
| DPU/DPUService reconciliation | DPF controllers | (runtime, not either repo) |
| Chart hosting for the 4 DPU services | Neither — external, public GHCR | `ghcr.io/szigmon/nico-dpf-fixed-charts` |
