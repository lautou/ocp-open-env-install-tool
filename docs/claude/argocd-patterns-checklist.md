# ArgoCD GitOps Patterns Checklist

**CRITICAL**: This checklist MUST be followed when creating new components or applications.

---

## 1. Application/ApplicationSet Definition

### ✅ REQUIRED: ignoreDifferences for cluster-versions ConfigMap

**When**: Creating ANY Application or ApplicationSet that deploys resources.

**Pattern**:
```yaml
spec:
  ignoreDifferences:
  - group: ''
    jsonPointers:
    - /metadata/annotations
    kind: ConfigMap
    name: cluster-versions
```

**Why**: The `cluster-versions` ConfigMap is a shared resource used by ALL components for version tracking. Without `ignoreDifferences`, ArgoCD will report OutOfSync because multiple Applications update the tracking annotations.

**Examples**:
- ✅ `gitops-profiles/ocp-ai/uc-ai-generation-llm-rag.yaml` (lines 22-27)
- ✅ `gitops-bases/ai/ai-models-service-appset.yaml` (lines 31-36)
- ✅ `gitops-bases/ai/applicationset.yaml` (lines 39-46)

**Rule**: ALWAYS add this to Application/ApplicationSet `spec.ignoreDifferences` or `spec.template.spec.ignoreDifferences`

---

## 2. Namespace Definitions

### ✅ REQUIRED: ArgoCD managed-by label

**When**: Creating cluster-scoped Namespace resources.

**Pattern**:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
  name: <namespace-name>
```

**Why**: ArgoCD uses this label to track which GitOps instance manages the namespace. Without it, ArgoCD may have permission issues or fail to manage resources in the namespace.

**Examples**:
- ✅ `components/ai-models-service/base/cluster-namespace-ai-models-service.yaml`
- ✅ `components/uc-ai-generation-llm-rag/base/cluster-namespace-ai-generation-llm-rag.yaml`
- ✅ `components/uc-llamastack/base/cluster-namespace-llamastack.yaml`

**File naming**: `cluster-namespace-<namespace-name>.yaml`

**Rule**: ALL cluster-scoped Namespace manifests MUST have `argocd.argoproj.io/managed-by: openshift-gitops` label

---

## 3. Custom Resource Definitions (Operator CRs)

### ✅ REQUIRED: SkipDryRunOnMissingResource annotation

**When**: Creating ANY Custom Resource (CR) where the CRD is installed by an operator.

**Pattern**:
```yaml
apiVersion: <operator-api>/<version>
kind: <CustomResourceKind>
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  name: <resource-name>
  namespace: <namespace>
spec:
  ...
```

**Why**: 
- ArgoCD validates ALL resources before applying ANY resources (dry-run)
- If CRD doesn't exist yet (operator not deployed), validation fails
- ArgoCD aborts ENTIRE sync without applying ANY resources
- **Deadlock**: Operator Subscription never created → CRDs never installed → CR validation always fails
- **Result**: Application stuck in OutOfSync/Missing state forever

**When to use**:
- ✅ ALL operator Custom Resources (InferenceService, ServingRuntime, ClusterPolicy, etc.)
- ✅ Resources where CRD is installed by operator (cert-manager, ODF, RHOAI, NetworkPolicy, etc.)

**When NOT to use**:
- ❌ Built-in Kubernetes resources (ConfigMap, Secret, Deployment, Service, etc.)
- ❌ Resources where CRD is pre-installed by OpenShift

**Examples**:
- ✅ `components/ai-models-service/base/ai-models-service-inferenceservice-granite-embedding.yaml`
- ✅ `components/cert-manager/base/cert-manager-clusterissuer-cluster.yaml`
- ✅ `components/nvidia-gpu-operator/base/cluster-clusterpolicy-gpu-cluster-policy.yaml`
- ✅ `components/rhoai/base/rhoai-datasciencecluster-default-dsc.yaml`

**Rule**: ALL operator CRs MUST have `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` annotation

---

## 4. Additional Common Patterns

### Optional: Prune=false for InferenceServices

**Pattern**:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true,Prune=false
```

**When**: InferenceService resources that should persist even if removed from Git (e.g., shared services).

**Example**: `ai-models-service-inferenceservice-granite-embedding.yaml`

### Optional: Delete=false for cluster-critical resources

**Pattern**:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Delete=false,SkipDryRunOnMissingResource=true
```

**When**: Cluster-critical resources that should NEVER be deleted by ArgoCD (e.g., IngressController, OAuth).

**Examples**:
- `cluster-ingresscontroller-default.yaml`
- `cluster-oauth-cluster.yaml`

---

## Pre-Commit Checklist

Before committing new components or applications:

- [ ] **Application/ApplicationSet**: Added `ignoreDifferences` for `cluster-versions` ConfigMap?
- [ ] **Namespace**: Added `argocd.argoproj.io/managed-by: openshift-gitops` label?
- [ ] **Operator CRs**: Added `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` annotation?
- [ ] **File Naming**: Followed naming conventions (`cluster-`, namespace prefixes, type aliases)?
- [ ] **Kustomization**: Alphabetically sorted resources list?

---

## Common Mistakes to Avoid

### ❌ MISTAKE #1: Forgot ignoreDifferences
**Symptom**: Application shows OutOfSync (but Healthy)  
**Message**: "ConfigMap/cluster-versions is part of applications X and Y"  
**Fix**: Add ignoreDifferences to Application/ApplicationSet spec

### ❌ MISTAKE #2: Forgot managed-by label
**Symptom**: ArgoCD permission errors, namespace management issues  
**Fix**: Add `argocd.argoproj.io/managed-by: openshift-gitops` to namespace labels

### ❌ MISTAKE #3: Forgot SkipDryRunOnMissingResource
**Symptom**: Application stuck OutOfSync/Missing forever, "resource mapping not found"  
**Fix**: Add `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` to CR annotations

### ❌ MISTAKE #4: Created orphaned Application
**Symptom**: Application exists but doesn't match Git, wrong project/targetRevision  
**Fix**: Delete Application, apply correct definition from Git profile

---

## Validation Commands

### Check Application ignoreDifferences
```bash
oc get application.argoproj.io <app-name> -n openshift-gitops -o jsonpath='{.spec.ignoreDifferences}'
```

**Expected**: Should include cluster-versions ConfigMap entry

### Check Namespace managed-by label
```bash
oc get namespace <namespace> -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/managed-by}'
```

**Expected**: `openshift-gitops`

### Check CR SkipDryRunOnMissingResource annotation
```bash
oc get <resource-type> <resource-name> -n <namespace> -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}'
```

**Expected**: Should include `SkipDryRunOnMissingResource=true`

---

## Real Examples from This Project

### ✅ CORRECT: uc-ai-generation-llm-rag Application

**File**: `gitops-profiles/ocp-ai/uc-ai-generation-llm-rag.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: uc-ai-generation-llm-rag
  namespace: openshift-gitops
  finalizers:
  - resources-finalizer.argocd.argoproj.io/background
spec:
  project: ai-usecases
  source:
    path: components/uc-ai-generation-llm-rag/overlays/default
    repoURL: https://github.com/lautou/ocp-open-env-install-tool.git
    targetRevision: master
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
  ignoreDifferences:  # ✅ CORRECT: cluster-versions ConfigMap ignored
  - group:
    jsonPointers:
    - /metadata/annotations
    kind: ConfigMap
    name: cluster-versions
```

### ✅ CORRECT: ai-generation-llm-rag Namespace

**File**: `components/uc-ai-generation-llm-rag/base/cluster-namespace-ai-generation-llm-rag.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops  # ✅ CORRECT: managed-by label
  name: ai-generation-llm-rag
```

### ✅ CORRECT: InferenceService with SkipDryRunOnMissingResource

**File**: `components/ai-models-service/base/ai-models-service-inferenceservice-granite-embedding.yaml`

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true,Prune=false  # ✅ CORRECT
    opendatahub.io/model-type: embedding
    security.opendatahub.io/enable-auth: "true"
  name: granite-embedding
  namespace: ai-models-service
spec:
  predictor:
    ...
```

---

## 4. ignoreDifferences Detailed Examples

### Shared Resources (Multi-Application Management)

**Scenario**: cluster-versions ConfigMap managed by ALL ApplicationSets simultaneously

**Problem**:
- ConfigMap referenced by all ApplicationSets via Kustomize replacements
- Each Application that syncs updates `argocd.argoproj.io/tracking-id` to itself
- Without ignoreDifferences → constant OutOfSync (false drift detection)

**Solution**:
```yaml
ignoreDifferences:
  - group: ''
    kind: ConfigMap
    name: cluster-versions
    jsonPointers:
      - /metadata/annotations  # ArgoCD tracking-id changes per sync
```

**Why this works**:
- All Applications sync successfully
- No conflicts over tracking metadata
- No labels or ownerReferences on this ConfigMap (not needed in ignore list)

**Key pattern**: Ignoring ArgoCD's own metadata that conflicts in multi-Application scenarios.

---

### Operator-Managed Fields

**Scenario**: RHACM ClusterManagementAddons with operator-managed spec fields

**Problem**:
- ACM operator enriches ClusterManagementAddon resources with runtime configuration
- Operator adds `defaultConfigs` entries specific to each addon (e.g., proxy configs)
- Operator sets `installStrategy` based on addon type (Manual vs Placements)
- Operator updates versions in `defaultConfigs` during ACM upgrades (e.g., 2.10 → 2.11)
- Our manifests provide minimal baseline, operator owns these fields completely
- Without ignoreDifferences → auto-heal cycles every 4-8 minutes

**Solution**:
```yaml
ignoreDifferences:
  - group: addon.open-cluster-management.io
    kind: ClusterManagementAddOn
    jsonPointers:
    - /spec/defaultConfigs      # Operator adds addon-specific configs
    - /spec/installStrategy     # Operator determines deployment strategy
```

**Why BOTH fields are required**:
- Ignoring only `/spec/installStrategy` is insufficient (commit 80da465 attempted, failed)
- Operator manages both fields independently and dynamically
- Must ignore both to prevent auto-heal cycles

**Result**: No auto-heal cycles, operator manages fields as designed (fixed in commit dd38d0e)

**Key pattern**: Ignoring operator-managed fields that cannot be statically declared in manifests.

---

### Testing ignoreDifferences

**Before adding ignoreDifferences**:
1. Remove ignoreDifferences entry
2. Push change
3. Verify sync status: `oc get applicationset <name>`
4. Check resource state: `oc get <resource> -o yaml`
5. Only re-add if genuine conflict confirmed

**Recent findings**:
- ✅ APIServer: No ignoreDifferences needed (RBAC sufficient) - 2026-03-30
- ✅ Network: No ignoreDifferences needed (RBAC sufficient) - 2026-03-30
- ✅ cluster-versions ConfigMap: Only `/metadata/annotations` needed (not labels/ownerReferences) - 2026-03-30
- ✅ HardwareProfile: No ignoreDifferences needed (namespace managed-by label sufficient) - 2026-03-30
- ✅ OdhDashboardConfig: No ignoreDifferences needed (namespace managed-by label sufficient) - 2026-03-30
- ✅ RHACM ClusterManagementAddons: Require `/spec/defaultConfigs` AND `/spec/installStrategy` (operator-managed) - 2026-04-08

**Excessive ignores are technical debt** - Test carefully before adding.

---

## Reference

**See also**:
- [CLAUDE.md](../../CLAUDE.md) - Section "GitOps Patterns"
- [components.md](components.md) - Component-specific patterns
- [gitops-specialist-agent.md](gitops-specialist-agent.md) - File naming conventions

**Last Updated**: 2026-04-16  
**Reason**: Added detailed ignoreDifferences examples (consolidated from CLAUDE.md)
