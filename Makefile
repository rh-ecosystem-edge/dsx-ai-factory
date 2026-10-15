# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Deployment Makefile for Red Hat build of DSX AI Factory.
# Manages the lifecycle of NICo and RMS on an OpenShift management cluster.
#
# Quick start:
#   cp deploy.env.example deploy.env   # fill in site-specific values
#   make check-prereqs
#   make deploy-all-cloud
#   make deploy-all-site SITE=<name>
#   make deploy-site-agent SITE_NAME=<name>

.PHONY: help check-prereqs
.PHONY: deploy-prereqs deploy-cloud-infra deploy-cloud deploy-all-cloud
.PHONY: patch-keycloak-route bootstrap-org
.PHONY: deploy-site-infra vault-init vault-admin-cert ensure-ssh-host-key deploy-site
.PHONY: deploy-site-agent deploy-rms
.PHONY: new-site patch-ovn-gateway deploy-dataplane-vip
.PHONY: verify-prereqs-deployed verify-infra-deployed verify-core-deployed verify-dataplane-vip
.PHONY: status undeploy

# =============================================================================
# Variables — override in deploy.env or on the command line
# =============================================================================

# Load site-specific configuration (git-ignored)
-include deploy.env

# Image registry for DSX AI Factory images
IMAGE_REGISTRY ?= ghcr.io/rh-ecosystem-edge/dsx-ai-factory
IMAGE_TAG      ?= latest

# Upstream chart paths (git submodules)
UPSTREAM      := components/infra-controller
RMS_UPSTREAM  := components/nv-rms

NICO_REST_CHART       := $(UPSTREAM)/helm/rest/nico-rest
NICO_CORE_CHART       := $(UPSTREAM)/helm
NICO_SITE_AGENT_CHART := $(UPSTREAM)/helm/rest/nico-rest-site-agent

# TODO: cloud-infra and site-infra charts are not yet present in this repo.
# They will be ported from ncp-dsx-nico-deploy in a follow-up.
CLOUD_INFRA_CHART := charts/cloud-infra
SITE_INFRA_CHART  := charts/site-infra

# Values files — place site-specific overrides in charts/values/
NICO_CORE_VALUES      := charts/values/nico-core.yaml
NICO_REST_VALUES      := charts/values/nico-rest.yaml
SITE_AGENT_VALUES     := charts/values/nico-rest-site-agent.yaml

# Site selection. Set SITE= in deploy.env or on the CLI.
# Per-site values files follow the naming convention charts/values/nico-core-<SITE>.yaml.
SITE          ?=
SITE_VALUES   ?= $(if $(SITE),charts/values/nico-core-$(SITE).yaml,$(NICO_CORE_VALUES))
PREREQS_VALUES   ?= $(if $(SITE),charts/values/prereqs-$(SITE).yaml)
SITE_INFRA_VALUES ?= $(if $(SITE),charts/values/infra-site-$(SITE).yaml)

# Data-plane MetalLB VIP (provisioning network). Resolved per site from deploy.env:
#   DATAPLANE_VIP_MYSITE=172.16.10.100
#   DATAPLANE_POOL_MYSITE=172.16.10.100-172.16.10.110
#   DATAPLANE_NIC_MYSITE=ens1f0
#   DATAPLANE_NODE_IP_MYSITE=172.16.10.2
toupper = $(shell echo $(1) | tr a-z A-Z)
DATAPLANE_VIP     ?= $(DATAPLANE_VIP_$(call toupper,$(SITE)))
DATAPLANE_POOL    ?= $(DATAPLANE_POOL_$(call toupper,$(SITE)))
DATAPLANE_NIC     ?= $(DATAPLANE_NIC_$(call toupper,$(SITE)))
DATAPLANE_NODE_IP ?= $(DATAPLANE_NODE_IP_$(call toupper,$(SITE)))

MLB_ANN := externalService.annotations.metallb\.universe\.tf/loadBalancerIPs
DATAPLANE_VIP_SET := \
  $(if $(DATAPLANE_VIP),\
    --set-string 'nico-api.$(MLB_ANN)=$(DATAPLANE_VIP)' \
    --set-string 'nico-api.certificate.ipAddresses[0]=$(DATAPLANE_VIP)' \
    --set-string 'nico-pxe.$(MLB_ANN)=$(DATAPLANE_VIP)' \
    --set-string 'unbound.$(MLB_ANN)=$(DATAPLANE_VIP)' \
    --set-string 'nico-dhcp.$(MLB_ANN)=$(DATAPLANE_VIP)' \
    --set 'nico-api.externalService.annotations.metallb\.universe\.tf/allow-shared-ip=nico-site-vip' \
    --set 'nico-pxe.externalService.annotations.metallb\.universe\.tf/allow-shared-ip=nico-site-vip' \
    --set 'unbound.externalService.annotations.metallb\.universe\.tf/allow-shared-ip=nico-site-vip' \
    --set 'nico-dhcp.externalService.annotations.metallb\.universe\.tf/allow-shared-ip=nico-site-vip' \
    --set-string 'unbound.localData[0].addresses[0]=$(DATAPLANE_VIP)' \
    --set-string 'unbound.localData[1].addresses[0]=$(DATAPLANE_VIP)' \
    --set-string 'nico-dhcp.config.kea.hookParameters.nameservers=$(DATAPLANE_VIP)' \
    --set-string 'nico-dhcp.config.kea.hookParameters.provisioningServer=$(DATAPLANE_VIP)')

DATAPLANE_INFRA_SET := \
  $(if $(DATAPLANE_VIP),--set 'metallb.enabled=true') \
  $(if $(DATAPLANE_POOL),--set-string 'metallb.addresses[0]=$(DATAPLANE_POOL)') \
  $(if $(DATAPLANE_NIC),--set-string 'metallb.interfaces[0]=$(DATAPLANE_NIC)' \
    --set-string 'nodeNetwork.enabled=true' \
    --set-string 'nodeNetwork.interface=$(DATAPLANE_NIC)') \
  $(if $(DATAPLANE_NODE_IP),--set-string 'nodeNetwork.address=$(DATAPLANE_NODE_IP)')

DATAPLANE_PREREQS_SET := \
  $(if $(DATAPLANE_VIP),--set 'metallb.enabled=true' --set 'nmstate.enabled=true')

# Vault topology: auto-detected from schedulable node count (ha=>=3, standalone otherwise).
# Force with VAULT_MODE=ha or VAULT_MODE=standalone.
NODE_COUNT = $(shell _n=$$(oc get nodes -o json 2>/dev/null | \
  jq '[.items[] | select((.spec.unschedulable != true) and \
  (([.spec.taints[]? | select(.effect=="NoSchedule" or .effect=="NoExecute")] | length) == 0))] | length' 2>/dev/null); \
  [ -n "$$_n" ] && echo "$$_n" || echo "1")
VAULT_MODE ?= $(if $(filter-out 0 1 2,$(NODE_COUNT)),ha,standalone)
CRC_VAULT_OVERRIDES := --set vault.server.ha.enabled=false \
  --set vault.server.standalone.enabled=true \
  --set-string 'vault.server.standalone.config=listener "tcp" { address = "[::]:8200"\n tls_cert_file = "/vault/userconfig/vault-tls/tls.crt"\n tls_key_file = "/vault/userconfig/vault-tls/tls.key"\n tls_client_ca_file = "/vault/userconfig/vault-tls/ca.crt"\n}\nstorage "file" { path = "/vault/data" }\ndisable_mlock = true'
VAULT_OVERRIDES = $(if $(filter standalone,$(VAULT_MODE)),$(CRC_VAULT_OVERRIDES),)

# Cluster ingress domain (auto-detected)
CLUSTER_DOMAIN ?= $(shell oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}' 2>/dev/null)

# Kustomize post-renderer (Helm 4 required)
POST_RENDERER_DIR := $(CURDIR)/scripts/kustomize-post-renderer
POST_RENDERER     := kustomize-post-renderer
export PATH       := $(POST_RENDERER_DIR):$(PATH)
CLOUD_KUSTOMIZE   := $(CURDIR)/scripts/kustomize/nico-rest
SITE_KUSTOMIZE    := $(CURDIR)/scripts/kustomize/nico-core

# Keycloak and REST API URLs
KC_URL  := https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN)
API_URL := https://nico-rest-api-nico-rest.$(CLUSTER_DOMAIN)

# Admin cert output directory
ADMIN_CERT_DIR := $(HOME)/.nico

# Keycloak client secret — generated once per make session
KEYCLOAK_CLIENT_SECRET ?= $(shell \
  _s=$$(oc get secret nico-rest-keycloak-client -n nico-rest \
    -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d 2>/dev/null); \
  if [ -n "$$_s" ]; then echo "$$_s"; else openssl rand -base64 32; fi)

# Site registration
SITE_NAME        ?=
SITE_DESCRIPTION ?= Managed by Helm

# =============================================================================
# Help
# =============================================================================

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	  /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-28s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Site variables (set in deploy.env or on the CLI):"
	@echo "  SITE=<name>          select per-site values (charts/values/nico-core-<name>.yaml)"
	@echo "  DATAPLANE_VIP=<ip>   MetalLB VIP for provisioning services"
	@echo "  VAULT_MODE=ha|standalone  override Vault topology detection"

.DEFAULT_GOAL := help

# =============================================================================
# Prerequisites
# =============================================================================

check-prereqs: ## Verify required tools and cluster connectivity
	@echo "=== Checking required tools ===" && \
	MISSING=0; \
	for bin in oc helm kustomize python3 git curl jq ssh-keygen; do \
		if command -v $$bin >/dev/null 2>&1; then \
			echo "  [OK]      $$bin ($$(command -v $$bin))"; \
		else \
			echo "  [MISSING] $$bin"; \
			MISSING=1; \
		fi; \
	done; \
	if python3 -c "import yaml" >/dev/null 2>&1; then \
		echo "  [OK]      python3 module: yaml (pyyaml)"; \
	else \
		echo "  [MISSING] python3 module: yaml (pyyaml)"; \
		echo "            install with: pip3 install --user --break-system-packages pyyaml"; \
		MISSING=1; \
	fi; \
	if command -v helm >/dev/null 2>&1; then \
		HELM_MAJOR=$$(helm version --short 2>/dev/null | sed -n 's/^v\([0-9][0-9]*\)\..*/\1/p'); \
		if [ "$$HELM_MAJOR" != "4" ]; then \
			echo "  [MISSING] Helm 4.x required (found $${HELM_MAJOR:-unknown}.x)"; \
			echo "            The kustomize post-renderer uses postrenderer/v1 (Helm 4 only)."; \
			echo "            Helm 3 breaks all helm commands once the plugin is installed."; \
			MISSING=1; \
		else \
			echo "  [OK]      helm $$(helm version --short)"; \
			if helm plugin list 2>/dev/null | grep -q '^kustomize-post-renderer[[:space:]]'; then \
				echo "  [OK]      helm plugin: kustomize-post-renderer"; \
			elif helm plugin install "$(POST_RENDERER_DIR)" >/dev/null 2>&1; then \
				echo "  [OK]      helm plugin: kustomize-post-renderer (just installed)"; \
			else \
				echo "  [MISSING] helm plugin: kustomize-post-renderer"; \
				echo "            install with: helm plugin install $(POST_RENDERER_DIR)"; \
				MISSING=1; \
			fi; \
		fi; \
	fi; \
	if oc whoami >/dev/null 2>&1; then \
		echo "  [OK]      oc logged in to $$(oc whoami --show-server 2>/dev/null)"; \
		SC=$$(oc get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null); \
		if [ -n "$$SC" ]; then \
			echo "  [OK]      default StorageClass: $$SC"; \
		else \
			echo "  [MISSING] no default StorageClass — PG, Vault, NATS PVCs will fail"; \
			MISSING=1; \
		fi; \
	else \
		echo "  [MISSING] oc not logged in"; \
		MISSING=1; \
	fi; \
	echo ""; \
	if [ $$MISSING -eq 1 ]; then \
		echo "One or more prerequisites are missing."; exit 1; \
	else \
		echo "All prerequisites satisfied."; \
	fi

# =============================================================================
# Helm dependency build
# =============================================================================

helm-dep-build: ## Build Helm chart dependencies
	git submodule update --init --recursive
	helm repo add temporal https://go.temporal.io/helm-charts --force-update
	helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
	helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update
	helm repo update >/dev/null
	helm dependency build $(CLOUD_INFRA_CHART)/
	helm dependency build $(SITE_INFRA_CHART)/

# =============================================================================
# Deploy — OLM prerequisite operators
# =============================================================================

deploy-prereqs: ## Install OLM prerequisite operators (cert-manager, PG, Keycloak, MetalLB, ESO, NMState)
	helm upgrade --install -n default dsx-ai-factory-prereqs \
		charts/prereqs/ \
		$(if $(PREREQS_VALUES),-f $(PREREQS_VALUES)) \
		$(DATAPLANE_PREREQS_SET) \
		--wait --timeout 15m

# =============================================================================
# Deploy — Cloud profile (Temporal, Keycloak, Crunchy PG cloud, NICo REST)
# =============================================================================

deploy-cloud-infra: helm-dep-build ## Deploy cloud infrastructure (Temporal, Keycloak, Crunchy PG)
	helm upgrade --install -n nico-rest nico-rest-infra \
		$(CLOUD_INFRA_CHART)/ \
		--create-namespace --wait --timeout 10m \
		$(if $(KEYCLOAK_CLIENT_SECRET),--set nico-rest-common.secrets.keycloakClientSecret.value="$(KEYCLOAK_CLIENT_SECRET)") \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)

deploy-cloud: ## Deploy NICo REST API services
	helm upgrade --install -n nico-rest nico-rest \
		$(NICO_REST_CHART) --wait --timeout 10m \
		-f $(NICO_REST_VALUES) \
		--set nico-rest-api.config.keycloak.externalBaseURL=https://keycloak-rhbk-operator.$(CLUSTER_DOMAIN) \
		--set nico-rest-common.secrets.keycloakClientSecret.value="$(KEYCLOAK_CLIENT_SECRET)" \
		--set global.image.repository="$(IMAGE_REGISTRY)" \
		--set global.image.tag="$(IMAGE_TAG)" \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(CLOUD_KUSTOMIZE)

deploy-all-cloud: deploy-prereqs deploy-cloud-infra deploy-cloud ## Deploy all cloud components, patch Keycloak route, and bootstrap org
	$(MAKE) patch-keycloak-route
	$(MAKE) bootstrap-org
	@echo "✅ Cloud deployment complete!"

patch-keycloak-route: ## Inject cluster CA into Keycloak route (required after deploy-cloud-infra)
	@echo "=== Patching Keycloak route with CA certificate ===" && \
	CA=$$(oc get secret nico-root-ca-secret -n cert-manager \
		-o jsonpath='{.data.tls\.crt}' | base64 -d) && \
	oc patch route keycloak -n rhbk-operator \
		--type merge -p "$$(jq -n --arg ca "$$CA" '{"spec":{"tls":{"destinationCACertificate":$$ca}}}')"
	@echo "=== Keycloak route patched ==="

bootstrap-org: ## Create Infrastructure Provider and default Tenant via NICo REST API
	@echo "=== Bootstrapping NICo organization ===" && \
	_ADMIN_USER=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
		-o jsonpath='{.data.username}' | base64 -d) && \
	_ADMIN_PASS=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
		-o jsonpath='{.data.password}' | base64 -d) && \
	_ADMIN_TOKEN=$$(curl -sk -X POST "$(KC_URL)/realms/master/protocol/openid-connect/token" \
		-d grant_type=password -d client_id=admin-cli \
		-d "username=$$_ADMIN_USER" -d "password=$$_ADMIN_PASS" | jq -r .access_token) && \
	_CLIENT_UUID=$$(curl -sk -H "Authorization: Bearer $$_ADMIN_TOKEN" \
		"$(KC_URL)/admin/realms/nico/clients?clientId=ncx-service" | jq -r '.[0].id') && \
	_CLIENT_SECRET=$$(curl -sk -H "Authorization: Bearer $$_ADMIN_TOKEN" \
		"$(KC_URL)/admin/realms/nico/clients/$$_CLIENT_UUID" | jq -r .secret) && \
	TOKEN=$$(curl -sk -X POST "$(KC_URL)/realms/nico/protocol/openid-connect/token" \
		--data-urlencode "grant_type=client_credentials" \
		--data-urlencode "client_id=ncx-service" \
		--data-urlencode "client_secret=$$_CLIENT_SECRET" \
		| jq -r .access_token) && \
	{ [ -n "$$TOKEN" ] && [ "$$TOKEN" != null ] || { echo "ERROR: failed to acquire token"; exit 1; }; } && \
	curl -sk -H "Authorization: Bearer $$TOKEN" \
		"$(API_URL)/v2/org/ncx/nico/infrastructure-provider/current" | jq . && \
	curl -sk -H "Authorization: Bearer $$TOKEN" \
		"$(API_URL)/v2/org/ncx/nico/tenant/current" | jq .
	@echo "=== Organization bootstrapped ==="

# =============================================================================
# Deploy — Site profile (Vault, NATS, Crunchy PG site, NICo Core)
# =============================================================================

deploy-site-infra: helm-dep-build ## Deploy site infrastructure (Vault, NATS, Crunchy PG)
	@echo "=== Vault topology: $(VAULT_MODE) ($(NODE_COUNT) schedulable nodes) ==="
	helm upgrade --install -n nico-system nico-site-infra \
		$(SITE_INFRA_CHART)/ \
		--create-namespace --timeout 15m \
		$(if $(SITE_INFRA_VALUES),-f $(SITE_INFRA_VALUES)) \
		$(DATAPLANE_INFRA_SET) \
		$(VAULT_OVERRIDES)

vault-init: ## Initialize Vault PKI, AppRole, and KV secrets (one-time per cluster)
	@echo "=== Initializing Vault (one-time) ===" && \
	NS=nico-system && \
	V=vault-0 && \
	echo "Waiting for Vault pod..." && \
	until oc get pod $$V -n $$NS -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do sleep 5; done && \
	if oc exec $$V -n $$NS -- vault status -tls-skip-verify -format=json 2>/dev/null | grep -q '"initialized".*true'; then \
		echo "Vault already initialized" && \
		if oc exec $$V -n $$NS -- vault status -tls-skip-verify -format=json 2>/dev/null | grep -q '"sealed".*true'; then \
			echo "Unsealing..." && \
			UK=$$(oc get secret vault-unseal-secret -n $$NS -o jsonpath='{.data.unseal-key}' | base64 -d) && \
			oc exec $$V -n $$NS -- vault operator unseal -tls-skip-verify "$$UK"; \
		fi && \
		RT=$$(oc get secret vault-unseal-secret -n $$NS -o jsonpath='{.data.root-token}' | base64 -d); \
	else \
		echo "Initializing Vault..." && \
		INIT=$$(oc exec $$V -n $$NS -- vault operator init -tls-skip-verify -key-shares=1 -key-threshold=1 -format=json) && \
		UK=$$(echo "$$INIT" | python3 -c "import json,sys; print(json.load(sys.stdin)['unseal_keys_b64'][0])") && \
		RT=$$(echo "$$INIT" | python3 -c "import json,sys; print(json.load(sys.stdin)['root_token'])") && \
		echo "Unsealing..." && \
		oc exec $$V -n $$NS -- vault operator unseal -tls-skip-verify "$$UK" && \
		oc create secret generic vault-unseal-secret -n $$NS \
			--from-literal=unseal-key="$$UK" --from-literal=root-token="$$RT" --from-literal=token="$$RT" \
			--dry-run=client -o yaml | oc apply -f - && \
		echo "Restarting Vault for postStart auto-unseal..." && \
		oc delete pod $$V -n $$NS && sleep 10 && \
		until oc exec $$V -n $$NS -- vault status -tls-skip-verify -format=json 2>/dev/null | grep -q '"sealed".*false'; do sleep 5; done; \
	fi && \
	echo "Unsealing all Raft replicas..." && \
	UK=$$(oc get secret vault-unseal-secret -n $$NS -o jsonpath='{.data.unseal-key}' | base64 -d) && \
	for pod in $$(oc get pods -n $$NS -l app.kubernetes.io/name=vault -o jsonpath='{.items[*].metadata.name}'); do \
		if oc exec $$pod -n $$NS -- vault status -tls-skip-verify -format=json 2>/dev/null | grep -q '"sealed".*true'; then \
			echo "Unsealing $$pod..." && \
			oc exec $$pod -n $$NS -- vault operator unseal -tls-skip-verify "$$UK" >/dev/null; \
		fi; \
	done && \
	echo "=== Configuring Vault ===" && \
	oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true && \
		vault secrets enable -path=secrets kv-v2 2>/dev/null || true && \
		printf '{\"UsernamePassword\":{\"username\":\"root\",\"password\":\"0penBmc\"}}' | vault kv put secrets/machines/all_dpus/factory_default/bmc-metadata-items/root - && \
		printf '{\"UsernamePassword\":{\"username\":\"\",\"password\":\"bluefield\"}}' | vault kv put secrets/machines/all_dpus/factory_default/uefi-metadata-items/auth - && \
		printf '{\"UsernamePassword\":{\"username\":\"root\",\"password\":\"0penBmc\"}}' | vault kv put secrets/machines/bmc/site/root - && \
		printf '{\"UsernamePassword\":{\"username\":\"\",\"password\":\"bluefield\"}}' | vault kv put secrets/machines/all_dpus/site_default/uefi-metadata-items/auth - && \
		printf '{\"UsernamePassword\":{\"username\":\"\",\"password\":\"bluefield\"}}' | vault kv put secrets/machines/all_hosts/site_default/uefi-metadata-items/auth - && \
		vault secrets enable -path=nicoca pki 2>/dev/null || true && \
		vault secrets tune -max-lease-ttl=87600h nicoca" && \
	echo "Importing CA into Vault PKI..." && \
	CA_CERT=$$(oc get secret nico-root-ca-secret -n cert-manager -o jsonpath='{.data.tls\.crt}' | base64 -d) && \
	CA_KEY=$$(oc get secret nico-root-ca-secret -n cert-manager -o jsonpath='{.data.tls\.key}' | base64 -d) && \
	echo "$$CA_CERT" > /tmp/vault-ca-bundle.pem && echo "$$CA_KEY" >> /tmp/vault-ca-bundle.pem && \
	_VBUNDLE=$$(mktemp) && umask 077 && \
	echo "$$CA_CERT" > $$_VBUNDLE && echo "$$CA_KEY" >> $$_VBUNDLE && \
	{ oc cp $$_VBUNDLE $$NS/$$V:/tmp/ca-bundle.pem -c vault; _cp=$$?; rm -f $$_VBUNDLE; [ $$_cp -eq 0 ]; } && \
	oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true && \
		vault write nicoca/config/ca pem_bundle=@/tmp/ca-bundle.pem && \
		vault write nicoca/roles/nico-cluster allow_any_name=true allowed_uri_sans='spiffe://*' max_ttl=720h ttl=720h key_type=ec key_bits=256 require_cn=false use_csr_common_name=true && \
		vault write nicoca/roles/nico-cli-client allow_any_name=true enforce_hostnames=false client_flag=true server_flag=false max_ttl=24h ttl=1h key_type=ec key_bits=256 ou=nico-cli-client && \
		vault auth enable kubernetes 2>/dev/null || true && \
		vault write auth/kubernetes/config kubernetes_host=https://\$$KUBERNETES_SERVICE_HOST:\$$KUBERNETES_SERVICE_PORT && \
		echo 'path \"nicoca/sign/nico-cluster\" { capabilities = [\"create\", \"update\"] }' | vault policy write cert-manager-nico-policy - && \
		vault write auth/kubernetes/role/cert-manager-nico-issuer bound_service_account_names=cert-manager-vault-nicoca-issuer bound_service_account_namespaces=cert-manager policies=cert-manager-nico-policy ttl=1h && \
		echo 'path \"nicoca*\" { capabilities = [\"read\", \"list\"] } path \"nicoca/sign/nico-cluster\" { capabilities = [\"create\", \"update\"] } path \"nicoca/issue/nico-cluster\" { capabilities = [\"create\", \"update\"] } path \"secrets/data/*\" { capabilities = [\"read\", \"list\"] } path \"secrets/data/machines*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] } path \"secrets/data/machines/*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] } path \"secrets/metadata/machines/*\" { capabilities = [\"delete\"] } path \"secrets/destroy/machines/*\" { capabilities = [\"delete\"] } path \"secrets/data/ufm/*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] } path \"secrets/data/nmxm/*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] } path \"secrets/data/bgp/*\" { capabilities = [\"create\", \"read\", \"patch\", \"list\", \"update\", \"delete\"] }' | vault policy write nico-vault-policy - && \
		vault write auth/kubernetes/role/nico-api bound_service_account_names=nico-api bound_service_account_namespaces=nico-system policies=nico-vault-policy ttl=1h && \
		vault auth enable approle 2>/dev/null || true && \
		vault write auth/approle/role/nico token_policies=nico-vault-policy token_ttl=1h token_max_ttl=4h" && \
	echo "Creating AppRole credentials..." && \
	ROLE_ID=$$(oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true; vault read -field=role_id auth/approle/role/nico/role-id") && \
	SECRET_ID=$$(oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true; vault write -f -field=secret_id auth/approle/role/nico/secret-id") && \
	oc patch secret nico-vault-approle-tokens -n $$NS --type=merge \
		-p "{\"stringData\":{\"VAULT_ROLE_ID\":\"$$ROLE_ID\",\"VAULT_SECRET_ID\":\"$$SECRET_ID\"}}" && \
	echo "Creating Flow PSM/NSM tokens..." && \
	PSM_TOKEN=$$(oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true; \
		echo 'path \"secrets/data/psm/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] } path \"secrets/metadata/psm/*\" { capabilities = [\"read\",\"list\",\"delete\"] } path \"nicoca/sign/nico-cluster\" { capabilities = [\"create\",\"update\"] }' | vault policy write psm-vault-policy - >/dev/null && \
		vault token create -orphan -policy=psm-vault-policy -period=24h -field=token") && \
	NSM_TOKEN=$$(oc exec $$V -n $$NS -- sh -c "export VAULT_TOKEN=$$RT VAULT_SKIP_VERIFY=true; \
		echo 'path \"secrets/data/nsm/*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\"] } path \"secrets/metadata/nsm/*\" { capabilities = [\"read\",\"list\",\"delete\"] } path \"nicoca/sign/nico-cluster\" { capabilities = [\"create\",\"update\"] }' | vault policy write nsm-vault-policy - >/dev/null && \
		vault token create -orphan -policy=nsm-vault-policy -period=24h -field=token") && \
	oc create secret generic psm-vault-token -n $$NS --from-literal=token="$$PSM_TOKEN" --dry-run=client -o yaml | oc apply -f - && \
	oc create secret generic nsm-vault-token -n $$NS --from-literal=token="$$NSM_TOKEN" --dry-run=client -o yaml | oc apply -f - && \
	echo "Creating cert-manager Vault SA and ClusterIssuer..." && \
	oc create sa cert-manager-vault-nicoca-issuer -n cert-manager --dry-run=client -o yaml | oc apply -f - && \
	echo '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"vault-nicoca-issuer-token","namespace":"cert-manager","annotations":{"kubernetes.io/service-account.name":"cert-manager-vault-nicoca-issuer"}},"type":"kubernetes.io/service-account-token"}' | oc apply -f - && \
	CA_B64=$$(oc get secret nico-root-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}') && \
	echo "{\"apiVersion\":\"cert-manager.io/v1\",\"kind\":\"ClusterIssuer\",\"metadata\":{\"name\":\"vault-nico-issuer\"},\"spec\":{\"vault\":{\"path\":\"nicoca/sign/nico-cluster\",\"server\":\"https://vault.nico-system.svc:8200\",\"caBundle\":\"$$CA_B64\",\"auth\":{\"kubernetes\":{\"role\":\"cert-manager-nico-issuer\",\"mountPath\":\"/v1/auth/kubernetes\",\"secretRef\":{\"name\":\"vault-nicoca-issuer-token\",\"key\":\"token\"}}}}}}" | oc apply -f - && \
	echo "=== Vault fully configured ==="

vault-admin-cert: ## Issue a 24h nico-admin-cli client certificate from Vault (re-run when expired)
	@echo "=== Issuing nico-admin-cli client certificate ===" && \
	NS=nico-system && V=vault-0 && \
	RT=$$(oc get secret vault-unseal-secret -n $$NS -o jsonpath='{.data.root-token}' | base64 -d) && \
	mkdir -p "$(ADMIN_CERT_DIR)" && \
	CERT_JSON=$$(oc exec $$V -n $$NS -c vault -- sh -c " \
		VAULT_ADDR=https://vault.nico-system:8200 \
		VAULT_CACERT=/tmp/ca-bundle.pem \
		VAULT_TOKEN=$$RT \
		vault write -format=json nicoca/issue/nico-cli-client common_name=nico-admin ttl=24h") && \
	echo "$$CERT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d['certificate'])" > $(ADMIN_CERT_DIR)/admin-tls.crt && \
	echo "$$CERT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d['private_key'])" > $(ADMIN_CERT_DIR)/admin-tls.key && \
	echo "$$CERT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print(d['issuing_ca'])" > $(ADMIN_CERT_DIR)/admin-ca.crt && \
	chmod 600 $(ADMIN_CERT_DIR)/admin-tls.key && \
	echo "Certificate written to $(ADMIN_CERT_DIR)/admin-tls.{crt,key,ca.crt} (valid 24h)" && \
	echo "" && \
	echo "To use nico-admin-cli from this workstation:" && \
	echo "  nico-admin-cli --api-url https://nico-api-grpc-nico-system.$(CLUSTER_DOMAIN) \\" && \
	echo "    --client-cert-path $(ADMIN_CERT_DIR)/admin-tls.crt \\" && \
	echo "    --client-key-path  $(ADMIN_CERT_DIR)/admin-tls.key \\" && \
	echo "    --forge-root-ca-path $(ADMIN_CERT_DIR)/admin-ca.crt \\" && \
	echo "    <subcommand>"

ensure-ssh-host-key:
	@oc get secret ssh-host-key -n nico-system >/dev/null 2>&1 || ( \
		TMPDIR=$$(mktemp -d) && \
		trap "rm -rf $$TMPDIR" EXIT && \
		ssh-keygen -t ed25519 -N "" -f "$$TMPDIR/ssh_host_ed25519_key" -q && \
		oc create namespace nico-system --dry-run=client -o yaml | oc apply -f - && \
		oc create secret generic ssh-host-key -n nico-system \
			--from-file=ssh_host_ed25519_key="$$TMPDIR/ssh_host_ed25519_key" \
			--from-file=ssh_host_ed25519_key_pub="$$TMPDIR/ssh_host_ed25519_key.pub" \
	)

deploy-site: ensure-ssh-host-key ## Deploy NICo Core (use SITE= to select per-site values)
	helm upgrade --install -n nico-system nico-core \
		$(NICO_CORE_CHART) --wait --timeout 10m \
		-f $(NICO_CORE_VALUES) -f $(SITE_VALUES) \
		--set global.image.repository="$(IMAGE_REGISTRY)/infra-controller-core" \
		--set global.image.tag="$(IMAGE_TAG)" \
		--set 'nico-api.certificate.extraDnsNames[0]=carbide-api.forge' \
		--set 'nico-api.certificate.extraDnsNames[1]=nico-api-grpc-nico-system.$(CLUSTER_DOMAIN)' \
		$(DATAPLANE_VIP_SET) \
		--post-renderer $(POST_RENDERER) --post-renderer-args $(SITE_KUSTOMIZE)
	@oc get route nico-api-grpc -n nico-system >/dev/null 2>&1 || \
		oc create route passthrough nico-api-grpc --service=nico-api --port=grpc -n nico-system

deploy-all-site: deploy-site-infra vault-init deploy-site ## Deploy all site components in sequence

deploy-site-agent: ## Register a site and deploy the REST site-agent (SITE_NAME=<name> or SITE_ID=<uuid>)
ifndef SITE_ID
ifndef SITE_NAME
	$(error Usage: make deploy-site-agent SITE_NAME=<name>  or  make deploy-site-agent SITE_ID=<existing-uuid>)
endif
endif
	@SITE_ID_VAL="$(SITE_ID)"; \
	if [ -z "$$SITE_ID_VAL" ]; then \
		echo "=== Acquiring service-account token ===" && \
		_ADMIN_USER=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
			-o jsonpath='{.data.username}' | base64 -d) && \
		_ADMIN_PASS=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
			-o jsonpath='{.data.password}' | base64 -d) && \
		_ADMIN_TOKEN=$$(curl -sk -X POST "$(KC_URL)/realms/master/protocol/openid-connect/token" \
			-d grant_type=password -d client_id=admin-cli \
			-d "username=$$_ADMIN_USER" -d "password=$$_ADMIN_PASS" | jq -r .access_token) && \
		_CLIENT_UUID=$$(curl -sk -H "Authorization: Bearer $$_ADMIN_TOKEN" \
			"$(KC_URL)/admin/realms/nico/clients?clientId=ncx-service" | jq -r '.[0].id') && \
		_CLIENT_SECRET=$$(curl -sk -H "Authorization: Bearer $$_ADMIN_TOKEN" \
			"$(KC_URL)/admin/realms/nico/clients/$$_CLIENT_UUID" | jq -r .secret) && \
		TOKEN=$$(curl -sk -X POST "$(KC_URL)/realms/nico/protocol/openid-connect/token" \
			--data-urlencode "grant_type=client_credentials" \
			--data-urlencode "client_id=ncx-service" \
			--data-urlencode "client_secret=$$_CLIENT_SECRET" | jq -r .access_token) && \
		{ [ -n "$$TOKEN" ] && [ "$$TOKEN" != null ] || { echo "ERROR: failed to acquire token"; exit 1; }; } && \
		echo "=== Creating site: $(SITE_NAME) ===" && \
		SITE_JSON=$$(curl -sk -X POST -H "Authorization: Bearer $$TOKEN" \
			-H "Content-Type: application/json" \
			-d "{\"name\":\"$(SITE_NAME)\",\"description\":\"$(SITE_DESCRIPTION)\"}" \
			"$(API_URL)/v2/org/ncx/nico/site") && \
		SITE_ID_VAL=$$(echo "$$SITE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])") && \
		OTP=$$(echo "$$SITE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['registrationToken'])") && \
		echo "Site ID: $$SITE_ID_VAL" && \
		oc create namespace nico-system 2>/dev/null || true && \
		CA_CERT=$$(oc get secret nico-root-ca-secret -n cert-manager \
			-o jsonpath='{.data.ca\.crt}' | base64 -d) && \
		oc delete secret site-registration -n nico-system 2>/dev/null || true && \
		oc create secret generic site-registration -n nico-system \
			--from-literal=site-uuid="$$SITE_ID_VAL" \
			--from-literal=otp="$$OTP" \
			--from-literal=creds-url=https://nico-rest-site-manager.nico-rest:8100/v1/sitecreds \
			--from-literal=cacert="$$CA_CERT"; \
	fi && \
	echo "=== Deploying site-agent ===" && \
	helm upgrade --install -n nico-system nico-rest-site-agent \
		$(NICO_SITE_AGENT_CHART) --wait --timeout 5m \
		-f $(SITE_AGENT_VALUES) \
		--set global.image.repository="$(IMAGE_REGISTRY)" \
		--set global.image.tag="$(IMAGE_TAG)" \
		--set envConfig.CLUSTER_ID=$$SITE_ID_VAL \
		--set envConfig.TEMPORAL_SUBSCRIBE_NAMESPACE=$$SITE_ID_VAL \
		--set bootstrap.enabled=true

deploy-rms: ## Deploy Rack Management Service (RMS)
	helm upgrade --install -n nico-system rms \
		$(RMS_UPSTREAM)/helm \
		--wait --timeout 10m \
		--set global.image.tag="$(IMAGE_TAG)"

# =============================================================================
# Site scaffolding
# =============================================================================

new-site: ## Create per-site values files scaffold (SITE=<name> required)
	@[ -n "$(SITE)" ] || { echo "ERROR: SITE required, e.g. make new-site SITE=mysite"; exit 1; }
	@[ ! -f charts/values/nico-core-$(SITE).yaml ] || \
		{ echo "ERROR: charts/values/nico-core-$(SITE).yaml already exists"; exit 1; }
	@mkdir -p charts/values
	@cp charts/values/nico-core-example.yaml charts/values/nico-core-$(SITE).yaml 2>/dev/null || \
		{ echo "# Site values for $(SITE) — fill in siteConfig, DHCP subnets, and DNS" > charts/values/nico-core-$(SITE).yaml; }
	@echo "✓ Created charts/values/nico-core-$(SITE).yaml"
	@echo ""
	@echo "Add to deploy.env:"
	@echo "  SITE=$(SITE)"
	@echo "  DATAPLANE_VIP_$(shell echo $(SITE) | tr a-z A-Z)=<your-vip>"
	@echo "  DATAPLANE_POOL_$(shell echo $(SITE) | tr a-z A-Z)=<vip>/<prefix>"
	@echo "  DATAPLANE_NIC_$(shell echo $(SITE) | tr a-z A-Z)=<provisioning-nic>"
	@echo "  DATAPLANE_NODE_IP_$(shell echo $(SITE) | tr a-z A-Z)=<node-ip-on-provisioning-vlan>"
	@echo ""
	@echo "Then: make deploy-dataplane-vip SITE=$(SITE)"

# =============================================================================
# Networking
# =============================================================================

patch-ovn-gateway: ## Enable OVN local-gateway mode for secondary-NIC MetalLB VIPs
	@echo "=== Patching OVN gateway config (routingViaHost + ipForwarding) ==="
	@oc patch network.operator cluster --type merge \
		-p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost":true,"ipForwarding":"Global"}}}}}'
	@echo "Waiting for ovnkube-node rollout..."
	@oc rollout status daemonset/ovnkube-node -n openshift-ovn-kubernetes --timeout=10m || \
		{ echo "⚠ Still rolling out"; true; }
	@echo "✓ OVN gateway patched"

deploy-dataplane-vip: ## Enable MetalLB data-plane VIPs for a site (SITE= required)
	@[ -n "$(SITE)" ] || { echo "ERROR: SITE required"; exit 1; }
	@[ -n "$(DATAPLANE_VIP)" ] || { echo "ERROR: DATAPLANE_VIP required"; exit 1; }
	@[ -n "$(DATAPLANE_POOL)" ] || { echo "ERROR: DATAPLANE_POOL required"; exit 1; }
	@[ -n "$(DATAPLANE_NIC)" ] || { echo "ERROR: DATAPLANE_NIC required"; exit 1; }
	@[ -n "$(DATAPLANE_NODE_IP)" ] || { echo "ERROR: DATAPLANE_NODE_IP required"; exit 1; }
	@echo "=== Step 1/3: Prerequisites (MetalLB + NMState operators) ==="
	$(MAKE) deploy-prereqs SITE=$(SITE)
	$(MAKE) verify-prereqs-deployed
	@echo "=== Step 2/3: Site infrastructure ==="
	$(MAKE) deploy-site-infra SITE=$(SITE)
	$(MAKE) verify-infra-deployed
	@echo "=== Step 3/3: NICo Core ==="
	$(MAKE) deploy-site SITE=$(SITE)
	$(MAKE) verify-core-deployed
	@echo "=== All stages deployed — run: make verify-dataplane-vip ==="

verify-prereqs-deployed:
	@oc get crd ipaddresspools.metallb.io >/dev/null || { echo "✗ MetalLB CRD missing"; exit 1; }
	@oc get crd nmstates.nmstate.io >/dev/null || { echo "✗ NMState CRD missing"; exit 1; }
	@echo "✓ Prerequisites present"

verify-infra-deployed:
	@oc get metallb -n metallb-system >/dev/null || { echo "✗ MetalLB CR missing"; exit 1; }
	@oc get ipaddresspool -n metallb-system >/dev/null || { echo "✗ IPAddressPool missing"; exit 1; }
	@echo "✓ Infrastructure deployed"

verify-core-deployed:
	@oc get svc nico-api -n nico-system >/dev/null || { echo "✗ nico-api service missing"; exit 1; }
	@echo "✓ NICo Core deployed"

verify-dataplane-vip: ## Check MetalLB VIP assignment and OVN gateway config
	@echo "=== LoadBalancer services ==="
	@oc get svc -n nico-system 2>/dev/null | grep -E "NAME|LoadBalancer" || echo "  (none)"
	@echo "=== NodeNetworkConfigurationPolicy ==="
	@oc get nncp 2>/dev/null || echo "  (none)"
	@echo "=== MetalLB pool + advertisement ==="
	@oc get ipaddresspool,l2advertisement -n metallb-system 2>/dev/null || echo "  (none)"
	@echo "=== OVN gateway ==="
	@oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}{"\n"}' 2>/dev/null || true
	@echo ""
	@echo "Manual check (from a host ON the provisioning VLAN):"
	@echo "  nc -vz <VIP> 443   # nico-api gRPC"
	@echo "  nc -vz <VIP> 8080  # nico-pxe"
	@echo "  dig @<VIP> nico.local  # DNS"

# =============================================================================
# Status and cleanup
# =============================================================================

status: ## Show status of all NICo components across all three namespaces
	@echo "=== Operators ===" && \
	echo "cert-manager:  $$(oc get pods -n cert-manager --no-headers 2>&1 | grep -c Running) running" && \
	echo "rhbk-operator: $$(oc get pods -n rhbk-operator --no-headers 2>&1 | grep -c Running) running" && \
	echo "pgo:           $$(oc get pods -n openshift-operators --no-headers 2>&1 | grep pgo | grep -c Running) running" && \
	echo "" && \
	echo "=== Cloud plane (nico-rest) ===" && \
	oc get pods -n nico-rest --no-headers 2>&1 | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' && \
	echo "" && \
	echo "=== Keycloak (rhbk-operator) ===" && \
	oc get pods -n rhbk-operator --no-headers 2>&1 | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' && \
	echo "" && \
	echo "=== Site plane (nico-system) ===" && \
	oc get pods -n nico-system --no-headers 2>/dev/null | \
		awk '{count[$$3]++} END {for (s in count) printf "%s: %d  ", s, count[s]; print ""}' || \
	echo "  (not deployed)" && \
	echo "" && \
	echo "=== REST API ===" && \
	( \
	  _AU=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
	      -o jsonpath='{.data.username}' | base64 -d 2>/dev/null) && \
	  _AP=$$(oc get secret keycloak-admin-secret -n rhbk-operator \
	      -o jsonpath='{.data.password}' | base64 -d 2>/dev/null) && \
	  _AT=$$(curl -sk --connect-timeout 3 --max-time 10 \
	      -X POST "$(KC_URL)/realms/master/protocol/openid-connect/token" \
	      --data-urlencode "grant_type=password" --data-urlencode "client_id=admin-cli" \
	      --data-urlencode "username=$$_AU" --data-urlencode "password=$$_AP" \
	      | jq -r .access_token) && \
	  _CU=$$(curl -sk --connect-timeout 3 --max-time 10 \
	      -H "Authorization: Bearer $$_AT" \
	      "$(KC_URL)/admin/realms/nico/clients?clientId=ncx-service" | jq -r '.[0].id') && \
	  _CS=$$(curl -sk --connect-timeout 3 --max-time 10 \
	      -H "Authorization: Bearer $$_AT" \
	      "$(KC_URL)/admin/realms/nico/clients/$$_CU" | jq -r .secret) && \
	  _TK=$$(curl -sk --connect-timeout 3 --max-time 10 \
	      -X POST "$(KC_URL)/realms/nico/protocol/openid-connect/token" \
	      --data-urlencode "grant_type=client_credentials" \
	      --data-urlencode "client_id=ncx-service" \
	      --data-urlencode "client_secret=$$_CS" | jq -r .access_token) && \
	  [ -n "$$_TK" ] && [ "$$_TK" != null ] && \
	  _SITES=$$(curl -sk --connect-timeout 3 --max-time 10 \
	      -H "Authorization: Bearer $$_TK" \
	      "$(API_URL)/v2/org/ncx/nico/site" \
	      | jq -r '[.[].name] | join(", ")' 2>/dev/null) && \
	  echo "  OK — registered sites: $${_SITES:-none}" \
	) 2>/dev/null || echo "  not reachable from this host"

undeploy: ## Remove all NICo and RMS components (interactive confirmation required)
	@echo "This will delete all NICo and RMS Helm releases, namespaces, and PostgreSQL clusters."
	@read -p "Continue? (yes/no): " CONFIRM && \
	[ "$$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }
	helm uninstall -n nico-system nico-rest-site-agent 2>/dev/null || true
	helm uninstall -n nico-system nico-core 2>/dev/null || true
	helm uninstall -n nico-system nico-site-infra 2>/dev/null || true
	helm uninstall -n nico-system rms 2>/dev/null || true
	helm uninstall -n nico-rest nico-rest 2>/dev/null || true
	helm uninstall -n nico-rest nico-rest-infra 2>/dev/null || true
	helm uninstall -n default dsx-ai-factory-prereqs 2>/dev/null || true
	@echo "Removing PostgreSQL finalizers..."
	@for ns in nico-rest nico-system; do \
		for pg in $$(oc get postgrescluster -n $$ns -o name 2>/dev/null); do \
			oc patch $$pg -n $$ns --type json \
				-p '[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true; \
		done; \
	done
	@oc delete postgrescluster --all -n nico-rest --wait=false 2>/dev/null || true
	@oc delete postgrescluster --all -n nico-system --wait=false 2>/dev/null || true
	@echo "Deleting namespaces..."
	@for ns in nico-rest nico-system rhbk-operator; do \
		oc delete namespace $$ns --wait=false 2>/dev/null || true; \
	done
	@oc delete clusterissuer vault-nico-issuer self-signed-issuer nico-rest-ca-issuer 2>/dev/null || true
	@echo "✓ Undeploy complete"
