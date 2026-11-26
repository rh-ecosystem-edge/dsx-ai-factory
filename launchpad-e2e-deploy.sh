#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# LaunchPad GB300 NVL72 — full NICo + DPF Zero Trust e2e deploy, in order.
#
# Must be run with `oc` already logged into the LaunchPad SNO (not from a
# sandbox without cluster network access — this cannot be driven remotely).
#
# Prerequisites assumed already in place (not redone by this script):
#   - DPF Zero Trust platform already installed (dpf-operator-system exists,
#     NICO_ENABLED=true set on the openshift-dpf side)
#   - DHCP relay configured on both CSL switches (server-group nico-dhcp -> VIP)
#   - MetalLB per-service VIPs reachable on 172.16.3.0/24
#   - The 4 DPU-service charts are public on GHCR (ghcr.io/szigmon/nico-dpf-fixed-charts) —
#     see launchpad/LAUNCHPAD-DEPLOYMENT.md if they ever need to be republished.
#
# Usage: ./launchpad-e2e-deploy.sh

set -euo pipefail
cd "$(dirname "$0")"

echo "=== 0. Sanity: cluster reachable, in the right context ==="
oc whoami
oc get ns dpf-operator-system >/dev/null || { echo "dpf-operator-system namespace missing — DPF platform must be installed first"; exit 1; }

echo
echo "=== 1. Deploy prerequisites (OLM operators, ClusterIssuers, ESO) ==="
# METALLB_MODE=dpf is required here too (defaults to "standalone" otherwise),
# so this skips installing a redundant MetalLB that would conflict with DPF's.
make deploy-prereqs SITE=launchpad METALLB_MODE=dpf

echo
echo "=== 2. Deploy site infra + Vault init + NICo Core (site=launchpad) ==="
make deploy-all-site SITE=launchpad METALLB_MODE=dpf

echo
echo "=== 3. Verify NICo Core is healthy ==="
oc get pods -n nico-system
oc wait --for=condition=Ready pod -l app.kubernetes.io/name=nico-api -n nico-system --timeout=300s

echo
echo "=== 4. Verify DPF sees NICo's services/DPU objects ==="
oc get dpuservice -A || true
oc get dpu -A || true

echo
echo "=== Done. Remaining steps are NOT automated by this script and need an explicit decision: ==="
echo "  - Confirm dnsmasq ignore rules + nico-dhcp MAC allowlist (launchpad-dpf-network-config.md Components 1 & 4)"
echo "  - Confirm Vault BMC credentials seeded (Component 6)"
echo "  - Expected-machine registration for tray-6/tray-7 (Component 5) is NOT run here —"
echo "    it can trigger a real tray power-cycle, run it deliberately, not as part of this script."
