# Red Hat build of DSX AI Factory

This repository hosts the midstream artifacts for Red Hat to build and ship the
[NVIDIA DSX AI Factory](https://www.nvidia.com/en-us/data-center/products/ai-factory/)
components.

## Components

| Component | Upstream Source | Documentation |
|-----------|----------------|---------------|
| NVIDIA Infra Controller (NICo) | [dsx-ai-factory/infra-controller](https://github.com/dsx-ai-factory/infra-controller) | [docs.nvidia.com/infra-controller](https://docs.nvidia.com/infra-controller) |
| NVIDIA Rack Management Service (RMS) | [dsx-ai-factory/nv-rms](https://github.com/dsx-ai-factory/nv-rms) | [docs.nvidia.com/rms](https://docs.nvidia.com/rms) |
| NVSentinel | [NVIDIA/NVSentinel](https://github.com/NVIDIA/NVSentinel) | [docs.nvidia.com/nvsentinel](https://docs.nvidia.com/nvsentinel) |
| NVIDIA Fleet Intelligence Agent | [dsx-ai-factory/fleet-intelligence-agent](https://github.com/dsx-ai-factory/fleet-intelligence-agent) | [docs.nvidia.com/fleet-intel](https://docs.nvidia.com/fleet-intel) |
| NVIDIA Health Validation | [dsx-ai-factory/health-validation](https://github.com/dsx-ai-factory/health-validation) | [docs.nvidia.com/health-validation](https://docs.nvidia.com/health-validation) |
| NVIDIA GPU Operator | [NVIDIA/gpu-operator](https://github.com/NVIDIA/gpu-operator) | [docs.nvidia.com/.../openshift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html) |
| NVIDIA Network Operator | [Mellanox/network-operator](https://github.com/Mellanox/network-operator) | [docs.nvidia.com/networking](https://docs.nvidia.com/networking/display/kubernetes2641/index.html) |

Each component lives under [`components/`](components/) as a Git submodule pinned to the
latest upstream release tag.

## Artifacts

Container images and Helm charts are published under the
[`ghcr.io/rh-ecosystem-edge/dsx-ai-factory`](https://github.com/orgs/rh-ecosystem-edge/packages)
namespace.

## Documentation

Full documentation is published at the project's
[GitHub Pages site](https://rh-ecosystem-edge.github.io/dsx-ai-factory), generated with
[Hugo](https://gohugo.io) from the [`docs/`](docs/) directory.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
