# Red Hat build of DSX AI Factory — Agent Guide

This repository hosts the midstream artifacts for Red Hat to build and ship
the NVIDIA DSX AI Factory components.

## Components

Components fall into two categories:

**Built from source** — tracked as git submodules under `components/`, pinned to
upstream release tags. Renovate opens bump PRs automatically (unless in patch state).

| Directory | Component | Upstream |
|-----------|-----------|---------|
| `components/infra-controller` | NVIDIA Infra Controller (NICo) | [dsx-ai-factory/infra-controller](https://github.com/dsx-ai-factory/infra-controller) |
| `components/nv-rms` | NVIDIA Rack Management Service (RMS) | [dsx-ai-factory/nv-rms](https://github.com/dsx-ai-factory/nv-rms) |
| `components/nvsentinel` | NVSentinel | [NVIDIA/NVSentinel](https://github.com/NVIDIA/NVSentinel) |
| `components/fia` | NVIDIA Fleet Intelligence Agent | [dsx-ai-factory/fleet-intelligence-agent](https://github.com/dsx-ai-factory/fleet-intelligence-agent) |

**Deployed via OLM** — OpenShift-certified operators consumed from Red Hat's
OperatorHub. No submodule; referenced by OLM `Subscription` manifests in the
Helm charts.

| Component | OLM package |
|-----------|-------------|
| NVIDIA GPU Operator | `gpu-operator-certified` |
| NVIDIA Network Operator | `nvidia-network-operator` |

## Repository layout

```
components/       Git submodules, one per component (pinned to release tags)
charts/           Helm charts, one subdirectory per component
docs/             Hugo documentation site (staging for Red Hat docs)
patches/          Temporary patches pending upstream merge
scripts/          Build, release, and helper scripts
.github/
  workflows/      CI/CD pipelines
```

## Git workflow

### Normal state

Submodules point to official upstream release tags. Renovate tracks new tags
and opens PRs weekly. To update manually:

```bash
git -C components/<name> fetch --tags
git -C components/<name> checkout <new-tag>
git add components/<name>
git commit -s -m "components/<name>: update to <new-tag>"
```

### Patch state

When a fix is needed before it lands upstream, the submodule points to a fork.
The patch state is signalled by a non-empty `patches/<component>/PATCHES.md`.

When a component enters patch state:
1. Point the submodule to the fork branch.
2. Export the patch to `patches/<component>/` and fill in `PATCHES.md`.
3. Add `"components/<name>"` to the disabled `matchDepNames` list in `renovate.json`.

`watch-upstream.yml` runs weekly and opens a PR when the upstream releases a
tag that may include the fix. After merging:
1. Remove `patches/<component>/`.
2. Remove the entry from `renovate.json`'s disabled list.

See `CONTRIBUTING.md` for full step-by-step instructions.

### Release branches

```
main        development, tracks latest upstream releases
YY.MM       Red Hat release branch (e.g. 26.10)
vYY.MM.0    release tag on the release branch
```

Fixes land on `main` first, then are cherry-picked onto the active release branch.

## Commit requirements

- All commits must be signed off: `git commit -s`
- Commit message style: `<scope>: <summary>`
  - Scope examples: `components/nico`, `charts`, `docs`, `ci`, `patches/rms`

## CI/CD

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `watch-upstream.yml` | Weekly (Mon 08:00 UTC) | Opens PR when upstream tag advances past a patched fork |
| `watch-base-image.yml` | Daily | Bumps UBI base image digest when it changes |
| `build.yml` | Pull request | Builds container images, lints Helm charts |
| `release.yml` | Push to `YY.MM` branch | Publishes images to GHCR, deploys Hugo docs |

Renovate opens submodule update PRs for components in normal state (not patch state).

## Artifacts

- Container images and Helm charts: `ghcr.io/rh-ecosystem-edge/dsx-ai-factory`
- Documentation: https://rh-ecosystem-edge.github.io/dsx-ai-factory

## Documentation

`docs/` is a Hugo staging site for content that will eventually be contributed
to official Red Hat documentation. It documents deploying the full AI Factory
stack for end users — not this repository's internals.

Deployment journey covered:
1. Overview & Architecture
2. Prerequisites
3. Deploying DSX AI Factory (NVIDIA components via operators/Helm)
4. Deploying RHEL
5. Deploying OpenShift
6. Operations
7. Troubleshooting

Hugo layout: bare Hugo (no external theme), Red Hat styling (`#ee0000`),
sticky TOC sidebar with scrollspy. Templates are in `docs/layouts/`.
Content stubs are in `docs/content/` — all marked `draft: true` except
section indexes and the landing page.
