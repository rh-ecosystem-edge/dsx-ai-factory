# Patches for nico

`components/nico` is in **patch state** — the submodule points to
`https://github.com/rh-ecosystem-edge/infra-controller` at tag
`v2.5.0-pr-ocp-v1` (commit `5a8745f44`), which is
`dsx-ai-factory/infra-controller@v2.5.0-pr` plus one integration commit
(`041e5b44b`, merged via PR #2 on the fork).

`watch-upstream.yml` monitors `dsx-ai-factory/infra-controller` for a new
release tag and opens a PR when one is detected.

## Active patches (1 squash commit, not yet submitted upstream)

The single commit on top of `v2.5.0-pr` bundles several previously-separate
efforts:

- OpenShift Helm/securityContext compatibility fixes (continuation of the
  patch set previously tracked against the `fabiendupont/nvidia-infra-controller`
  fork: conditional site-config mount, flow Namespace guard, REST API
  caBundle, containerSecurityContext hardening across `nico-dhcp`,
  `nico-pxe`, `nico-dns`, `nico-bmc-proxy`, `nico-ntp`,
  `nico-hardware-health`, `nico-dsx-exchange-consumer`, `nico-rest-db`
  migration job PGSSLMODE, `nico-api` migration job pg_isready/backoffLimit).
- PostgreSQL TLS support (Go code in `rest-api/db/pkg/db`, `cmd/migrations`).
- External DPF / capability-selector integration (`crates/dpf`,
  `crates/api-core/src/dpf_services.rs`).
- Hosted OpenShift DPU agent chart (`bluefield/charts/nico-dpu-agent`).
- New OpenShift Helm value presets
  (`helm-prereqs/values/nico-{core,flow,rest}-openshift.yaml`).

| Commit | Summary |
|--------|---------|
| `041e5b44b` | Integrate OpenShift NICo and external DPF for RH next |
| `5a8745f44` | Merge pull request #2 from rh-ecosystem-edge/integration/initial-upstream-pr |

- **Prior upstream PR**: https://github.com/dsx-ai-factory/infra-controller/pull/4372
  (covered only the original Helm-only subset of these fixes against an
  older base; **needs review** to determine whether it still applies as-is or
  must be split/superseded, since this commit also carries unrelated PG
  TLS/DPF/DPU-agent work that was never part of that PR).
- **Fork tag**: `rh-ecosystem-edge/infra-controller@v2.5.0-pr-ocp-v1`

## Resolving

1. Submit patches upstream to `dsx-ai-factory/infra-controller` (reconciling
   with PR #4372 as needed) and record PR URLs above.
2. When merged and a new release tag is available, merge the `watch-upstream.yml` PR.
3. Delete this file and `patches/infra-controller/`.
4. Remove `"components/infra-controller"` from `matchDepNames` in `renovate.json`.
