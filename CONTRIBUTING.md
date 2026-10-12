# Contributing

## Repository layout

```
components/   Git submodules, one per NVIDIA component (pinned to release tags)
charts/       Helm charts, one subdirectory per component
docs/         Hugo documentation site
patches/      Temporary patches pending upstream merge, one subdirectory per component
scripts/      Build, release, and submodule update helpers
.github/
  workflows/  CI/CD pipelines
```

## Git workflow

### Upstream-first policy

We adopt upstream code as-is whenever possible. When a change is needed:

1. Open an issue and pull request in the upstream project.
2. While the PR is pending, maintain a fork and apply the change as a patch under
   `patches/<component>/`.
3. Once the upstream PR merges, remove the patch and update the submodule pin to a
   release tag that includes the fix.

### Entering patch state

When a fix is needed before it lands upstream:

1. Open an issue and PR in the upstream project.
2. Point the submodule to your fork branch:
   ```bash
   git -C components/<component> remote add fork https://github.com/<org>/<fork>
   git -C components/<component> fetch fork
   git -C components/<component> checkout fork/<branch>
   git add components/<component>
   git commit -s -m "components/<component>: point to fork pending upstream PR"
   ```
3. Export the patch and document it:
   ```bash
   mkdir -p patches/<component>
   git -C components/<component> format-patch -1 <commit> -o ../../patches/<component>/
   cp patches/PATCHES.md.template patches/<component>/PATCHES.md
   # Edit patches/<component>/PATCHES.md to fill in the upstream PR URL and description
   git add patches/<component>/
   git commit -s -m "patches/<component>: track <NNN>-description"
   ```
4. Disable Renovate for this submodule by adding `"components/<component>"` to
   the `matchDepNames` list in the patch-state rule in `renovate.json`:
   ```bash
   # Edit renovate.json: add "components/<component>" to the disabled matchDepNames array
   git add renovate.json
   git commit -s -m "renovate: disable <component> while in patch state"
   ```

`watch-upstream.yml` will now monitor the upstream repo weekly and open a PR
when a new release tag appears that may include the fix.

### Resolving a patch

When `watch-upstream.yml` opens a patch-resolution PR:

1. Verify all patches in `patches/<component>/PATCHES.md` are included in the
   new upstream tag (check upstream PR merge status).
2. Merge the resolution PR.
3. Remove the patch files:
   ```bash
   rm -rf patches/<component>/
   git add patches/<component>/
   git commit -s -m "patches/<component>: resolved in <upstream-tag>"
   ```
4. Re-enable Renovate by removing `"components/<component>"` from `matchDepNames`
   in `renovate.json`.

### Updating a submodule (normal state)

Renovate opens update PRs automatically. To update manually:

```bash
git -C components/<component> fetch --tags
git -C components/<component> checkout <new-tag>
git -C components/<component> submodule update --init --recursive
git add components/<component>
git commit -s -m "components/<component>: update to <new-tag>"
```

### Release branches

Releases follow the `YY.MM` naming convention (e.g., `26.10`). Each release branch is
cut from `main` and tagged as `vYY.MM.0`, `vYY.MM.1`, etc. for patch releases.

```
main          development, tracks latest upstream releases
YY.MM         Red Hat release branch (e.g., 26.10)
vYY.MM.0      release tag on the release branch
```

Cherry-pick policy: fixes land on `main` first, then are cherry-picked onto the active
release branch.

## Commit requirements

- All commits must be signed off: `git commit -s`
- Follow the `<scope>: <summary>` commit message style, where `<scope>` is the component
  name or area (e.g., `components/nico`, `charts`, `docs`, `ci`).

## Helm charts

The `charts/dsx-ai-factory/` umbrella chart depends on component charts
published as OCI artifacts to GHCR by the release pipeline. To work with
the chart locally before a release has been published, push the component
charts manually:

```bash
helm registry login ghcr.io -u <github-user> -p <token>
for path in \
  components/infra-controller/helm \
  components/infra-controller/helm/rest/nico-rest \
  components/nv-rms/helm; do
  helm dependency build "$path" 2>/dev/null || true
  pkg=$(helm package "$path" --destination /tmp/ | awk '{print $NF}')
  helm push "$pkg" oci://ghcr.io/rh-ecosystem-edge/dsx-ai-factory/charts
done
helm dependency update charts/dsx-ai-factory/
```

## CI pipelines

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `watch-upstream.yml` | Weekly (Monday 08:00 UTC) | Opens a PR when an upstream tag advances past a patch-state fork |
| `watch-base-image.yml` | Daily | Auto-commits a UBI digest bump when the base image changes |
| `build.yml` | Pull request | Builds container images, lints Helm charts |
| `release.yml` | Push to `YY.MM` branch | Publishes images to GHCR, deploys Hugo docs |

Renovate opens submodule update PRs automatically for components in normal state (not in patch state).
