# ==============================================================================
# Generic Kubernetes Investigation & Troubleshooting Makefile
# Based on k8s_investigation_commands_generic.md
# ==============================================================================

# ------------------------------------------------------------------------------
# Default Variables (Override from CLI: make <target> CTX=my-ctx NS=my-ns)
# ------------------------------------------------------------------------------
CTX          ?= $(shell kubectl config current-context 2>/dev/null)
NS           ?= default
NODE         ?=
DEPLOYMENT   ?=
POD          ?=
HPA          ?=
RELEASE_NAME ?=
CONFIGMAP    ?=

# Cloud Provider (GCP / GKE) variables
PROJECT_ID   ?=
CLUSTER_NAME ?=
REGION       ?=
NODE_POOL    ?=
REPLICAS     ?= 1

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ------------------------------------------------------------------------------
# Help Target
# ------------------------------------------------------------------------------
.PHONY: help
help: ## Show this help menu
	@echo "========================================================================"
	@echo "  Kubernetes Cluster Investigation & Troubleshooting Toolkit"
	@echo "========================================================================"
	@echo "Current Configuration:"
	@echo "  CTX          = $(if $(CTX),$(CTX),<not set>)"
	@echo "  NS           = $(NS)"
	@echo "  NODE         = $(if $(NODE),$(NODE),<not set>)"
	@echo "  DEPLOYMENT   = $(if $(DEPLOYMENT),$(DEPLOYMENT),<not set>)"
	@echo "  POD          = $(if $(POD),$(POD),<not set>)"
	@echo "  PROJECT_ID   = $(if $(PROJECT_ID),$(PROJECT_ID),<not set>)"
	@echo "  CLUSTER_NAME = $(if $(CLUSTER_NAME),$(CLUSTER_NAME),<not set>)"
	@echo "========================================================================"
	@echo "Usage: make <target> [VARIABLE=value ...]"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}'

# ------------------------------------------------------------------------------
# 1. Cluster & Context Discovery
# ------------------------------------------------------------------------------
.PHONY: contexts namespaces current-context

contexts: ## List all available kubectl contexts
	kubectl config get-contexts

namespaces: ## List all namespaces in cluster (uses CTX)
	@$(call check_ctx)
	kubectl --context=$(CTX) get namespaces

current-context: ## Print the currently active context
	@echo "Active Context: $(CTX)"

# ------------------------------------------------------------------------------
# 2. Node Health, Capacity & Schedulable Headroom
# ------------------------------------------------------------------------------
.PHONY: nodes nodes-top nodes-pressure nodes-capacity nodes-storage node-allocated node-pods

nodes: ## List nodes with OS, kernel, container runtime, and status
	@$(call check_ctx)
	kubectl --context=$(CTX) get nodes -o wide

nodes-top: ## Live CPU & Memory utilization per node
	@$(call check_ctx)
	kubectl --context=$(CTX) top nodes

nodes-pressure: ## Check node conditions (Ready, DiskPressure, MemoryPressure, PIDPressure)
	@$(call check_ctx)
	kubectl --context=$(CTX) get nodes \
	  -o custom-columns=NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status',DISK_PRESSURE:'.status.conditions[?(@.type=="DiskPressure")].status',MEM_PRESSURE:'.status.conditions[?(@.type=="MemoryPressure")].status',PID_PRESSURE:'.status.conditions[?(@.type=="PIDPressure")].status',TRANSITION:'.status.conditions[?(@.type=="DiskPressure")].lastTransitionTime'

nodes-capacity: ## Show node compute capacity vs. allocatable
	@$(call check_ctx)
	kubectl --context=$(CTX) get nodes \
	  -o custom-columns=NAME:.metadata.name,CPU_CAP:.status.capacity.cpu,CPU_ALLOC:.status.allocatable.cpu,MEM_CAP:.status.capacity.memory,MEM_ALLOC:.status.allocatable.memory

nodes-storage: ## Show node ephemeral storage capacity vs. allocatable
	@$(call check_ctx)
	kubectl --context=$(CTX) get nodes \
	  -o custom-columns=NAME:.metadata.name,EPHEM_CAP:.status.capacity.ephemeral-storage,EPHEM_ALLOC:.status.allocatable.ephemeral-storage

node-allocated: ## Show allocated CPU & Memory requests/limits on a node (requires NODE=...)
	@$(call check_ctx)
	@$(call check_var,NODE)
	kubectl --context=$(CTX) describe node $(NODE) | grep -A 15 -E "Allocated resources:"

node-pods: ## List non-terminated pods running on a specific node (requires NODE=...)
	@$(call check_ctx)
	@$(call check_var,NODE)
	kubectl --context=$(CTX) get pods -A --field-selector spec.nodeName=$(NODE)

# ------------------------------------------------------------------------------
# 3. Workload Utilization & Bottleneck Diagnostics
# ------------------------------------------------------------------------------
.PHONY: top-cpu top-mem pods-unhealthy pods-failed pods-restarts pod-last-state hpa hpa-describe workloads events-warning

top-cpu: ## Top pods sorted by CPU usage across all namespaces
	@$(call check_ctx)
	kubectl --context=$(CTX) top pods -A --sort-by=cpu

top-mem: ## Top pods sorted by Memory usage across all namespaces
	@$(call check_ctx)
	kubectl --context=$(CTX) top pods -A --sort-by=memory

pods-unhealthy: ## List all pods not in Running or Completed state
	@$(call check_ctx)
	kubectl --context=$(CTX) get pods -A | grep -v -E "Running|Completed" || echo "All pods are Running or Completed."

pods-failed: ## List all Failed / Evicted pods across all namespaces
	@$(call check_ctx)
	kubectl --context=$(CTX) get pods -A --field-selector=status.phase=Failed

pods-restarts: ## List pods with restarts > 0 sorted by restart count
	@$(call check_ctx)
	kubectl --context=$(CTX) get pods -A --sort-by='.status.containerStatuses[0].restartCount' | grep -v '0\s\+' || echo "No restarted pods found."

pod-last-state: ## Inspect termination reason & exit code of a pod (requires POD=... NS=...)
	@$(call check_ctx)
	@$(call check_var,POD)
	kubectl --context=$(CTX) get pod $(POD) -n $(NS) -o jsonpath='{.status.containerStatuses[*].lastState}'
	@echo ""

hpa: ## List all Horizontal Pod Autoscalers (HPAs)
	@$(call check_ctx)
	kubectl --context=$(CTX) get hpa -A

hpa-describe: ## Describe specific HPA (requires HPA=... NS=...)
	@$(call check_ctx)
	@$(call check_var,HPA)
	kubectl --context=$(CTX) describe hpa $(HPA) -n $(NS)

workloads: ## List all Deployments, StatefulSets, and DaemonSets
	@$(call check_ctx)
	@echo "=== DEPLOYMENTS ==="
	kubectl --context=$(CTX) get deployments -A
	@echo -e "\n=== STATEFULSETS ==="
	kubectl --context=$(CTX) get statefulset -A
	@echo -e "\n=== DAEMONSETS ==="
	kubectl --context=$(CTX) get daemonset -A

events-warning: ## Recent Warning events cluster-wide sorted by timestamp
	@$(call check_ctx)
	kubectl --context=$(CTX) get events -A --field-selector type=Warning --sort-by='.lastTimestamp'

# ------------------------------------------------------------------------------
# 4. Rollout & Scheduling Diagnostics
# ------------------------------------------------------------------------------
.PHONY: rollout-status pod-describe deployment-resources pod-resources rollout-strategy

rollout-status: ## Check deployment rollout status (requires DEPLOYMENT=... NS=...)
	@$(call check_ctx)
	@$(call check_var,DEPLOYMENT)
	kubectl --context=$(CTX) rollout status deployment $(DEPLOYMENT) -n $(NS)

pod-describe: ## Describe a pod to inspect scheduler events (requires POD=... NS=...)
	@$(call check_ctx)
	@$(call check_var,POD)
	kubectl --context=$(CTX) describe pod $(POD) -n $(NS)

deployment-resources: ## Inspect container resource requests/limits of deployment (requires DEPLOYMENT=... NS=...)
	@$(call check_ctx)
	@$(call check_var,DEPLOYMENT)
	kubectl --context=$(CTX) get deployment $(DEPLOYMENT) -n $(NS) -o jsonpath='{.spec.template.spec.containers[*].resources}'
	@echo ""

pod-resources: ## Show resource requests/limits for all containers & sidecars in pod (requires POD=... NS=...)
	@$(call check_ctx)
	@$(call check_var,POD)
	@echo "--- App Containers ---"
	kubectl --context=$(CTX) get pod $(POD) -n $(NS) -o json | jq '.spec.containers[] | {name: .name, resources: .resources}'
	@echo "--- Init / Sidecar Containers ---"
	kubectl --context=$(CTX) get pod $(POD) -n $(NS) -o json | jq '.spec.initContainers[] | {name: .name, resources: .resources}'

rollout-strategy: ## Inspect deployment rolling update strategy (requires DEPLOYMENT=... NS=...)
	@$(call check_ctx)
	@$(call check_var,DEPLOYMENT)
	kubectl --context=$(CTX) get deployment $(DEPLOYMENT) -n $(NS) -o jsonpath='{.spec.strategy.rollingUpdate}'
	@echo ""

# ------------------------------------------------------------------------------
# 5. Storage & DiskPressure (Kubelet Summary API)
# ------------------------------------------------------------------------------
.PHONY: node-fs pod-storage images-by-size

node-fs: ## Inspect node root filesystem & imageFs via Kubelet Summary API (requires NODE=...)
	@$(call check_ctx)
	@$(call check_var,NODE)
	kubectl --context=$(CTX) get --raw "/api/v1/nodes/$(NODE)/proxy/stats/summary" | jq '.node.fs, .node.runtime.imageFs'

pod-storage: ## Show ephemeral storage consumed by every pod on node (requires NODE=...)
	@$(call check_ctx)
	@$(call check_var,NODE)
	kubectl --context=$(CTX) get --raw "/api/v1/nodes/$(NODE)/proxy/stats/summary" | jq '[.pods[] | {pod: .podRef.name, namespace: .podRef.namespace, ephemeral: .["ephemeral-storage"]}]'

images-by-size: ## List all container images on node sorted by size in MB (requires NODE=...)
	@$(call check_ctx)
	@$(call check_var,NODE)
	kubectl --context=$(CTX) get node $(NODE) -o json | jq '[.status.images[] | {names: .names, sizeMB: (.sizeBytes / 1024 / 1024 | floor)}] | sort_by(-.sizeMB)'

# ------------------------------------------------------------------------------
# 6. Deep Python Diagnostic Scripts
# ------------------------------------------------------------------------------
.PHONY: analyze-namespaces analyze-nodes analyze-disks watch-disk

analyze-namespaces: ## Aggregate per-namespace actual usage vs. requests vs. limits
	@$(call check_ctx)
	@python3 scripts/analyze_namespaces.py --context="$(CTX)"

analyze-nodes: ## Calculate allocatable vs requested resources and remaining headroom per node
	@$(call check_ctx)
	@python3 scripts/analyze_nodes.py --context="$(CTX)" $(if $(NODE),--node="$(NODE)",)

analyze-disks: ## Query Kubelet Summary API across all nodes for root vs imageFs footprint
	@$(call check_ctx)
	@python3 scripts/analyze_disks.py --context="$(CTX)" $(if $(NODE),--node="$(NODE)",)

watch-disk: ## Live check node disk usage percentage and available bytes (requires NODE=...)
	@$(call check_ctx)
	@$(call check_var,NODE)
	@python3 scripts/watch_disk.py --context="$(CTX)" --node="$(NODE)"

# ------------------------------------------------------------------------------
# 7. Cloud Infrastructure (GKE / GCP)
# ------------------------------------------------------------------------------
.PHONY: gke-clusters gke-nodepools gke-nodepool-describe gke-autoscaling gke-nodepool-specs

gke-clusters: ## List GKE clusters in project (requires PROJECT_ID=...)
	@$(call check_var,PROJECT_ID)
	gcloud container clusters list --project $(PROJECT_ID)

gke-nodepools: ## List node pools in cluster (requires CLUSTER_NAME=... REGION=... PROJECT_ID=...)
	@$(call check_var,CLUSTER_NAME)
	@$(call check_var,REGION)
	@$(call check_var,PROJECT_ID)
	gcloud container node-pools list --cluster $(CLUSTER_NAME) --region $(REGION) --project $(PROJECT_ID)

gke-nodepool-describe: ## Describe node pool autoscaling & count (requires NODE_POOL=... CLUSTER_NAME=... REGION=... PROJECT_ID=...)
	@$(call check_var,NODE_POOL)
	@$(call check_var,CLUSTER_NAME)
	@$(call check_var,REGION)
	@$(call check_var,PROJECT_ID)
	gcloud container node-pools describe $(NODE_POOL) --cluster $(CLUSTER_NAME) --region $(REGION) --project $(PROJECT_ID) --format="json(autoscaling, initialNodeCount, management)"

gke-autoscaling: ## Inspect cluster autoscaling profile (requires CLUSTER_NAME=... REGION=... PROJECT_ID=...)
	@$(call check_var,CLUSTER_NAME)
	@$(call check_var,REGION)
	@$(call check_var,PROJECT_ID)
	gcloud container clusters describe $(CLUSTER_NAME) --region $(REGION) --project $(PROJECT_ID) --format="json(autoscaling)"

gke-nodepool-specs: ## Inspect full node pool machine & disk specifications (requires CLUSTER_NAME=... REGION=... PROJECT_ID=...)
	@$(call check_var,CLUSTER_NAME)
	@$(call check_var,REGION)
	@$(call check_var,PROJECT_ID)
	gcloud container clusters describe $(CLUSTER_NAME) --region $(REGION) --project $(PROJECT_ID) --format="json(nodePools)"

# ------------------------------------------------------------------------------
# 8. Helm & Live Manifests
# ------------------------------------------------------------------------------
.PHONY: helm-values configmap

helm-values: ## Inspect user-supplied Helm values (requires RELEASE_NAME=... NS=...)
	@$(call check_ctx)
	@$(call check_var,RELEASE_NAME)
	helm get values $(RELEASE_NAME) -n $(NS) --kube-context=$(CTX)

configmap: ## Inspect ConfigMap YAML (requires CONFIGMAP=... NS=...)
	@$(call check_ctx)
	@$(call check_var,CONFIGMAP)
	kubectl --context=$(CTX) get configmap $(CONFIGMAP) -n $(NS) -o yaml

# ------------------------------------------------------------------------------
# 9. Operational Remediation Commands
# ------------------------------------------------------------------------------
.PHONY: clean-failed-pods rollout-restart scale-workload

clean-failed-pods: ## Delete all Failed / Evicted pods across all namespaces
	@$(call check_ctx)
	kubectl --context=$(CTX) delete pod -A --field-selector=status.phase=Failed

rollout-restart: ## Force rolling restart of a deployment (requires DEPLOYMENT=... NS=...)
	@$(call check_ctx)
	@$(call check_var,DEPLOYMENT)
	kubectl --context=$(CTX) rollout restart deployment $(DEPLOYMENT) -n $(NS)

scale-workload: ## Emergency scaling of a deployment (requires DEPLOYMENT=... NS=... REPLICAS=...)
	@$(call check_ctx)
	@$(call check_var,DEPLOYMENT)
	kubectl --context=$(CTX) scale deployment $(DEPLOYMENT) -n $(NS) --replicas=$(REPLICAS)

# ------------------------------------------------------------------------------
# Validation Helpers
# ------------------------------------------------------------------------------
define check_ctx
	@if [ -z "$(CTX)" ]; then \
		echo "Error: CTX (kubectl context) is not set and no active context found."; \
		echo "Usage: make <target> CTX=<context_name>"; \
		exit 1; \
	fi
endef

define check_var
	@if [ -z "$($1)" ]; then \
		echo "Error: Required parameter '$1' is missing."; \
		echo "Usage: make $@ $1=<value>"; \
		exit 1; \
	fi
endef
