# Patches for rms

`components/nv-rms` is in **patch state** — the submodule points to
`https://github.com/fabiendupont/nv-rms` at branch `feature/db-credential-secret-keys`,
which contains all patches below stacked on `dsx-ai-factory/nv-rms@main`.

`watch-upstream.yml` monitors `dsx-ai-factory/nv-rms` for a new release tag
and opens a PR when one is detected.

## Active patches

### feat(helm): configurable external DB credential secret keys
- **Upstream PR**: https://github.com/dsx-ai-factory/nv-rms/pull/30 (open)
- **Fork branch**: `fabiendupont/nv-rms@feature/db-credential-secret-keys`
- **Description**: Configurable external DB credential secret keys in Helm chart

### feat(helm): optional chart-owned firmware PVC
- **Upstream PR**: https://github.com/dsx-ai-factory/nv-rms/pull/31 (open)
- **Fork branch**: `fabiendupont/nv-rms@feature/firmware-pvc-creation`
- **Description**: Optional chart-owned firmware PVC; storageClass `"-"` sentinel disables dynamic provisioning

## Merged upstream (included in main, pending release tag)

### fix(test): correct inventory-profile regex escaping in config.toml assertions
- **Upstream PR**: https://github.com/dsx-ai-factory/nv-rms/pull/32 (merged)
- **Description**: Already in `dsx-ai-factory/nv-rms@main`; will be in next release tag

## Resolving

When `watch-upstream.yml` opens a resolution PR:
1. Verify PRs #30 and #31 are included in the new upstream tag.
2. Merge the PR (submodule URL switches back to `dsx-ai-factory/nv-rms`).
3. Delete this file and `patches/nv-rms/`.
4. Remove `"components/nv-rms"` from `matchDepNames` in `renovate.json`.
