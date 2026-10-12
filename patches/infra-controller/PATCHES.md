# Patches for nico

`components/nico` is in **patch state** — the submodule points to
`https://github.com/fabiendupont/nvidia-infra-controller` at branch
`fix/openshift-compatibility` (tip `5cf087e7c`), which contains 12 Helm chart
OpenShift compatibility fixes on top of `dsx-ai-factory/infra-controller@main`.

`watch-upstream.yml` monitors `dsx-ai-factory/infra-controller` for a new
release tag and opens a PR when one is detected.

## Active patches (12 commits, not yet submitted upstream)

All patches are Helm chart fixes required for OpenShift compatibility. They are
logically one set and will be submitted as a single PR (or a small set of PRs)
against `dsx-ai-factory/infra-controller`.

| Commit | Summary |
|--------|---------|
| `5cf087e` | fix(helm): conditional site-config mount, flow Namespace guard, REST API caBundle |
| `5138d32` | fix(helm): extend containerSecurityContext to nico-bmc-proxy, nico-flow, nico-ntp |
| `b058ade` | docs(helm): standardize OpenShift podSecurityContext override guidance |
| `6e3ccd6` | ci(helm): assert nico-rest pod securityContext stays overridable |
| `5192b52` | fix(helm): harden Core container securityContext with allowPrivilegeEscalation |
| `ff87a67` | fix(helm/nico-rest): make pod securityContext configurable across services |
| `61b4ab6` | fix(helm/nico-dhcp): add emptyDir volumes for Kea runtime directories |
| `be269ec` | fix(helm/nico-rest-db): add configurable PGSSLMODE to migration job |
| `f1a0dac` | fix(helm/nico-rest-db): add imagePullPolicy to wait-for-postgres init container |
| `b26dcc0` | fix(helm/nico-api): add pg_isready init container and backoffLimit to migration job |
| `6a03f5b` | fix(helm): make database secret username key configurable |
| `5e5b338` | fix(helm): make container securityContext configurable across all service charts |

- **Upstream PR**: https://github.com/dsx-ai-factory/infra-controller/pull/4372 (open)
- **Fork branch**: `fabiendupont/nvidia-infra-controller@fix/openshift-compatibility`

## Resolving

1. Submit patches upstream to `dsx-ai-factory/infra-controller` and record PR URLs above.
2. When merged and a new release tag is available, merge the `watch-upstream.yml` PR.
3. Delete this file and `patches/infra-controller/`.
4. Remove `"components/nico"` from `matchDepNames` in `renovate.json`.
