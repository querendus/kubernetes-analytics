# ==============================================================================
# Generic Kubernetes Investigation & Troubleshooting Justfile
# Just equivalent to Makefilek8s
# ==============================================================================

set shell := ["bash", "-c"]

# ------------------------------------------------------------------------------
# Configurable Variables (Override via environment variable or recipe arguments)
# ------------------------------------------------------------------------------
CTX          := env_var_or_default("CTX", `kubectl config current-context 2>/dev/null || true`)
NS           := env_var_or_default("NS", "default")
NODE         := env_var_or_default("NODE", "")
DEPLOYMENT   := env_var_or_default("DEPLOYMENT", "")
POD          := env_var_or_default("POD", "")
HPA          := env_var_or_default("HPA", "")
RELEASE_NAME := env_var_or_default("RELEASE_NAME", "")
CONFIGMAP    := env_var_or_default("CONFIGMAP", "")

# Cloud Provider (GCP / GKE) variables
PROJECT_ID   := env_var_or_default("PROJECT_ID", "")
CLUSTER_NAME := env_var_or_default("CLUSTER_NAME", "")
REGION       := env_var_or_default("REGION", "")
NODE_POOL    := env_var_or_default("NODE_POOL", "")
REPLICAS     := env_var_or_default("REPLICAS", "1")

# Default recipe: displays all available commands
default:
    @just --list --justfile {{justfile()}}

# ------------------------------------------------------------------------------
# 1. Cluster & Context Discovery
# ------------------------------------------------------------------------------

# List all available kubectl contexts
contexts:
    kubectl config get-contexts

# List all namespaces in cluster
namespaces ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get namespaces

# Print the currently active context
current-context ctx=CTX:
    @echo "Active Context: {{ctx}}"

# ------------------------------------------------------------------------------
# 2. Node Health, Capacity & Schedulable Headroom
# ------------------------------------------------------------------------------

# List nodes with OS, kernel, container runtime, and status
nodes ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get nodes -o wide

# Live CPU & Memory utilization per node
nodes-top ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} top nodes

# Check node conditions (Ready, DiskPressure, MemoryPressure, PIDPressure)
nodes-pressure ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get nodes \
      -o custom-columns=NAME:.metadata.name,READY:'.status.conditions[?(@.type=="Ready")].status',DISK_PRESSURE:'.status.conditions[?(@.type=="DiskPressure")].status',MEM_PRESSURE:'.status.conditions[?(@.type=="MemoryPressure")].status',PID_PRESSURE:'.status.conditions[?(@.type=="PIDPressure")].status',TRANSITION:'.status.conditions[?(@.type=="DiskPressure")].lastTransitionTime'

# Show node compute capacity vs. allocatable
nodes-capacity ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get nodes \
      -o custom-columns=NAME:.metadata.name,CPU_CAP:.status.capacity.cpu,CPU_ALLOC:.status.allocatable.cpu,MEM_CAP:.status.capacity.memory,MEM_ALLOC:.status.allocatable.memory

# Show node ephemeral storage capacity vs. allocatable
nodes-storage ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get nodes \
      -o custom-columns=NAME:.metadata.name,EPHEM_CAP:.status.capacity.ephemeral-storage,EPHEM_ALLOC:.status.allocatable.ephemeral-storage

# Show allocated CPU & Memory requests/limits on a node
node-allocated node=NODE ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{node}}" ]; then echo "Error: NODE is required. Usage: just node-allocated <node_name>"; exit 1; fi
    kubectl --context={{ctx}} describe node {{node}} | grep -A 15 -E "Allocated resources:"

# List non-terminated pods running on a specific node
node-pods node=NODE ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{node}}" ]; then echo "Error: NODE is required. Usage: just node-pods <node_name>"; exit 1; fi
    kubectl --context={{ctx}} get pods -A --field-selector spec.nodeName={{node}}

# ------------------------------------------------------------------------------
# 3. Workload Utilization & Bottleneck Diagnostics
# ------------------------------------------------------------------------------

# Top pods sorted by CPU usage across all namespaces
top-cpu ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} top pods -A --sort-by=cpu

# Top pods sorted by Memory usage across all namespaces
top-mem ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} top pods -A --sort-by=memory

# List all pods not in Running or Completed state
pods-unhealthy ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get pods -A | grep -v -E "Running|Completed" || echo "All pods are Running or Completed."

# List all Failed / Evicted pods across all namespaces
pods-failed ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get pods -A --field-selector=status.phase=Failed

# List pods with restarts > 0 sorted by restart count
pods-restarts ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get pods -A --sort-by='.status.containerStatuses[0].restartCount' | grep -v '0\s\+' || echo "No restarted pods found."

# Inspect termination reason & exit code of a pod
pod-last-state pod=POD ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{pod}}" ]; then echo "Error: POD is required. Usage: just pod-last-state <pod_name> [ns]"; exit 1; fi
    kubectl --context={{ctx}} get pod {{pod}} -n {{ns}} -o jsonpath='{.status.containerStatuses[*].lastState}'
    @echo ""

# List all Horizontal Pod Autoscalers (HPAs)
hpa ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get hpa -A

# Describe a specific HPA
hpa-describe hpa=HPA ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{hpa}}" ]; then echo "Error: HPA is required. Usage: just hpa-describe <hpa_name> [ns]"; exit 1; fi
    kubectl --context={{ctx}} describe hpa {{hpa}} -n {{ns}}

# List all Deployments, StatefulSets, and DaemonSets
workloads ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @echo "=== DEPLOYMENTS ==="
    kubectl --context={{ctx}} get deployments -A
    @echo -e "\n=== STATEFULSETS ==="
    kubectl --context={{ctx}} get statefulset -A
    @echo -e "\n=== DAEMONSETS ==="
    kubectl --context={{ctx}} get daemonset -A

# Recent Warning events cluster-wide sorted by timestamp
events-warning ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} get events -A --field-selector type=Warning --sort-by='.lastTimestamp'

# ------------------------------------------------------------------------------
# 4. Rollout & Scheduling Diagnostics
# ------------------------------------------------------------------------------

# Check deployment rollout status
rollout-status deployment=DEPLOYMENT ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{deployment}}" ]; then echo "Error: DEPLOYMENT is required. Usage: just rollout-status <deployment_name> [ns]"; exit 1; fi
    kubectl --context={{ctx}} rollout status deployment {{deployment}} -n {{ns}}

# Describe a pod to inspect scheduler events
pod-describe pod=POD ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{pod}}" ]; then echo "Error: POD is required. Usage: just pod-describe <pod_name> [ns]"; exit 1; fi
    kubectl --context={{ctx}} describe pod {{pod}} -n {{ns}}

# Inspect container resource requests/limits of deployment
deployment-resources deployment=DEPLOYMENT ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{deployment}}" ]; then echo "Error: DEPLOYMENT is required. Usage: just deployment-resources <deployment_name> [ns]"; exit 1; fi
    kubectl --context={{ctx}} get deployment {{deployment}} -n {{ns}} -o jsonpath='{.spec.template.spec.containers[*].resources}'
    @echo ""

# Show resource requests/limits for all containers & sidecars in pod
pod-resources pod=POD ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{pod}}" ]; then echo "Error: POD is required. Usage: just pod-resources <pod_name> [ns]"; exit 1; fi
    @echo "--- App Containers ---"
    kubectl --context={{ctx}} get pod {{pod}} -n {{ns}} -o json | jq '.spec.containers[] | {name: .name, resources: .resources}'
    @echo "--- Init / Sidecar Containers ---"
    kubectl --context={{ctx}} get pod {{pod}} -n {{ns}} -o json | jq '.spec.initContainers[] | {name: .name, resources: .resources}'

# Inspect deployment rolling update strategy
rollout-strategy deployment=DEPLOYMENT ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{deployment}}" ]; then echo "Error: DEPLOYMENT is required. Usage: just rollout-strategy <deployment_name> [ns]"; exit 1; fi
    kubectl --context={{ctx}} get deployment {{deployment}} -n {{ns}} -o jsonpath='{.spec.strategy.rollingUpdate}'
    @echo ""

# ------------------------------------------------------------------------------
# 5. Storage & DiskPressure (Kubelet Summary API)
# ------------------------------------------------------------------------------

# Inspect node root filesystem & imageFs via Kubelet Summary API
node-fs node=NODE ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{node}}" ]; then echo "Error: NODE is required. Usage: just node-fs <node_name>"; exit 1; fi
    kubectl --context={{ctx}} get --raw "/api/v1/nodes/{{node}}/proxy/stats/summary" | jq '.node.fs, .node.runtime.imageFs'

# Show ephemeral storage consumed by every pod on node
pod-storage node=NODE ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{node}}" ]; then echo "Error: NODE is required. Usage: just pod-storage <node_name>"; exit 1; fi
    kubectl --context={{ctx}} get --raw "/api/v1/nodes/{{node}}/proxy/stats/summary" | jq '[.pods[] | {pod: .podRef.name, namespace: .podRef.namespace, ephemeral: .["ephemeral-storage"]}]'

# List all container images on node sorted by size in MB
images-by-size node=NODE ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{node}}" ]; then echo "Error: NODE is required. Usage: just images-by-size <node_name>"; exit 1; fi
    kubectl --context={{ctx}} get node {{node}} -o json | jq '[.status.images[] | {names: .names, sizeMB: (.sizeBytes / 1024 / 1024 | floor)}] | sort_by(-.sizeMB)'

# ------------------------------------------------------------------------------
# 6. Deep Python Diagnostic Scripts
# ------------------------------------------------------------------------------

# Aggregate per-namespace actual usage vs. requests vs. limits
analyze-namespaces ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @python3 scripts/analyze_namespaces.py --context="{{ctx}}"

# Calculate allocatable vs requested resources and remaining headroom per node
analyze-nodes node=NODE ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @python3 scripts/analyze_nodes.py --context="{{ctx}}" $(if [ -n "{{node}}" ]; then echo "--node={{node}}"; fi)

# Query Kubelet Summary API across all nodes for root vs imageFs footprint
analyze-disks node=NODE ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @python3 scripts/analyze_disks.py --context="{{ctx}}" $(if [ -n "{{node}}" ]; then echo "--node={{node}}"; fi)

# Live check node disk usage percentage and available bytes
watch-disk node=NODE ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{node}}" ]; then echo "Error: NODE is required. Usage: just watch-disk <node_name>"; exit 1; fi
    @python3 scripts/watch_disk.py --context="{{ctx}}" --node="{{node}}"

# ------------------------------------------------------------------------------
# 7. Cloud Infrastructure (GKE / GCP)
# ------------------------------------------------------------------------------

# List GKE clusters in project
gke-clusters project_id=PROJECT_ID:
    @if [ -z "{{project_id}}" ]; then echo "Error: PROJECT_ID is required. Usage: just gke-clusters <project_id>"; exit 1; fi
    gcloud container clusters list --project {{project_id}}

# List node pools in cluster
gke-nodepools cluster=CLUSTER_NAME region=REGION project_id=PROJECT_ID:
    @if [ -z "{{cluster}}" ] || [ -z "{{region}}" ] || [ -z "{{project_id}}" ]; then \
        echo "Error: CLUSTER_NAME, REGION, and PROJECT_ID are required."; exit 1; fi
    gcloud container node-pools list --cluster {{cluster}} --region {{region}} --project {{project_id}}

# Describe node pool autoscaling & count
gke-nodepool-describe nodepool=NODE_POOL cluster=CLUSTER_NAME region=REGION project_id=PROJECT_ID:
    @if [ -z "{{nodepool}}" ] || [ -z "{{cluster}}" ] || [ -z "{{region}}" ] || [ -z "{{project_id}}" ]; then \
        echo "Error: NODE_POOL, CLUSTER_NAME, REGION, and PROJECT_ID are required."; exit 1; fi
    gcloud container node-pools describe {{nodepool}} --cluster {{cluster}} --region {{region}} --project {{project_id}} --format="json(autoscaling, initialNodeCount, management)"

# Inspect cluster autoscaling profile
gke-autoscaling cluster=CLUSTER_NAME region=REGION project_id=PROJECT_ID:
    @if [ -z "{{cluster}}" ] || [ -z "{{region}}" ] || [ -z "{{project_id}}" ]; then \
        echo "Error: CLUSTER_NAME, REGION, and PROJECT_ID are required."; exit 1; fi
    gcloud container clusters describe {{cluster}} --region {{region}} --project {{project_id}} --format="json(autoscaling)"

# Inspect full node pool machine & disk specifications
gke-nodepool-specs cluster=CLUSTER_NAME region=REGION project_id=PROJECT_ID:
    @if [ -z "{{cluster}}" ] || [ -z "{{region}}" ] || [ -z "{{project_id}}" ]; then \
        echo "Error: CLUSTER_NAME, REGION, and PROJECT_ID are required."; exit 1; fi
    gcloud container clusters describe {{cluster}} --region {{region}} --project {{project_id}} --format="json(nodePools)"

# ------------------------------------------------------------------------------
# 8. Helm & Live Manifests
# ------------------------------------------------------------------------------

# Inspect user-supplied Helm values
helm-values release=RELEASE_NAME ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{release}}" ]; then echo "Error: RELEASE_NAME is required. Usage: just helm-values <release_name> [ns]"; exit 1; fi
    helm get values {{release}} -n {{ns}} --kube-context={{ctx}}

# Inspect ConfigMap YAML
configmap cm=CONFIGMAP ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{cm}}" ]; then echo "Error: CONFIGMAP is required. Usage: just configmap <cm_name> [ns]"; exit 1; fi
    kubectl --context={{ctx}} get configmap {{cm}} -n {{ns}} -o yaml

# ------------------------------------------------------------------------------
# 9. Operational Remediation Commands
# ------------------------------------------------------------------------------

# Delete all Failed / Evicted pods across all namespaces
clean-failed-pods ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    kubectl --context={{ctx}} delete pod -A --field-selector=status.phase=Failed

# Force rolling restart of a deployment
rollout-restart deployment=DEPLOYMENT ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{deployment}}" ]; then echo "Error: DEPLOYMENT is required. Usage: just rollout-restart <deployment_name> [ns]"; exit 1; fi
    kubectl --context={{ctx}} rollout restart deployment {{deployment}} -n {{ns}}

# Emergency scaling of a deployment
scale-workload deployment=DEPLOYMENT replicas=REPLICAS ns=NS ctx=CTX:
    @if [ -z "{{ctx}}" ]; then echo "Error: CTX is not set."; exit 1; fi
    @if [ -z "{{deployment}}" ]; then echo "Error: DEPLOYMENT is required. Usage: just scale-workload <deployment_name> [replicas] [ns]"; exit 1; fi
    kubectl --context={{ctx}} scale deployment {{deployment}} -n {{ns}} --replicas={{replicas}}
