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
- ✅ `gitops-bases/ai/applicationset.yaml`
- ✅ `gitops-bases/rh-connectivity-link/default/applicationset.yaml`

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
- ✅ `components/rh-connectivity-link/base/cluster-namespace-kuadrant-system.yaml`
- ✅ `components/openshift-insights/base/cluster-namespace-openshift-insights.yaml`

**Note**: Not every namespace in this repo has this label — some (e.g. `nvidia-gpu-operator`, `jobset`, `kueue`, `leader-work-set`) intentionally omit it. Only add it when ArgoCD needs to manage resources inside that namespace beyond what the operator's own installation covers.

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
- ✅ `components/demo-ei/base/demo-ei-inferenceservice-mistral-medium-3-5.yaml`
- ✅ `components/cert-manager/base/cert-manager-clusterissuer-cluster.yaml`
- ✅ `components/nvidia-gpu-operator/base/cluster-clusterpolicy-gpu-cluster-policy.yaml`
- ✅ `components/rhoai/base/cluster-datasciencecluster-default-dsc.yaml`

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

**No current example in this repo** — apply this when introducing a shared/persistent InferenceService.

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

## 5. ArgoCD RBAC Gaps (Unmanaged Namespaces AND managed-by Coverage Gaps)

**When**: A component needs ArgoCD to create/manage a resource and hits `<resource> is forbidden: User "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller" cannot create resource ...`. This happens in two distinct scenarios — check which one you're in before picking a fix:

1. **Namespace isn't `managed-by`-labeled at all** (e.g. `openshift-apiserver`) — ArgoCD has no generated RBAC there whatsoever.
2. **Namespace IS `managed-by`-labeled, but the auto-generated Role still doesn't cover the resource type** (e.g. `openshift-ingress`, which carries the label). Confirmed live 2026-08-09: OpenShift GitOps's auto-generated `openshift-gitops-argocd-application-controller` Role there is **not** a wildcard grant — it's a curated per-API-group allowlist, with a blanket `get/list/watch`-only fallback for anything not explicitly listed. `gateway.networking.k8s.io/gateways` gets read-only (matching OpenShift's own `gateway-api:aggregate-to-admin` ClusterRole — see `components.md` "MaaS Gateway for Model Serving" for why this is deliberate, not a bug). `telemetry.istio.io` isn't listed at all (JIRA [OSSM-15257](https://redhat.atlassian.net/browse/OSSM-15257) — a genuine upstream gap). **Don't assume a `managed-by` label means full write access — check the actual generated Role's rules on your cluster (`oc get role openshift-gitops-argocd-application-controller -n <namespace> -o yaml`) before concluding RBAC should already work.**

Both scenarios use the same two fix approaches — pick based on scope and namespace sensitivity:

### Option A: Narrow Role/RoleBinding (preferred for sensitive namespaces, one-off grants)

Grant only the specific resource type needed, nothing broader (not `edit`/`admin`):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: <resource>-manager
  namespace: <target-namespace>
rules:
- apiGroups:
  - <api-group>
  resources:
  - <resource-plural>
  verbs:
  - '*'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: <resource>-manager
  namespace: <target-namespace>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: <resource>-manager
subjects:
- kind: ServiceAccount
  name: openshift-gitops-argocd-application-controller
  namespace: openshift-gitops
```

**Examples**:
- `components/rh-connectivity-link/base/openshift-ingress-role-telemetry-manager.yaml` + `-rb-telemetry-manager.yaml` (scenario 2 — `openshift-ingress` is `managed-by`-labeled, but its generated Role has no `telemetry.istio.io` entry at all)
- `components/cluster-ingress/base/openshift-ingress-role-gateway-manager.yaml` + `-rb-gateway-manager.yaml` (scenario 2 — same namespace, generated Role covers `gateway.networking.k8s.io/gateways` but read-only)
- `components/openshift-config/base/openshift-apiserver-role-networkpolicy-manager.yaml` + `-rb-networkpolicy-manager.yaml` (scenario 1 — `openshift-apiserver` has no `managed-by` label at all)

**File naming**: name by the target namespace + what it manages (`<namespace>-role-<resource>-manager.yaml`, `<namespace>-rb-<resource>-manager.yaml`), not by the source SA — see the cross-namespace RBAC naming rule in `gitops-specialist-agent.md`.

### Option B: Dedicated component with `managed-by` on the namespace (preferred when a namespace will accumulate more GitOps-managed content over time)

Give the namespace itself the standard label, then ArgoCD auto-generates its own RBAC there — no manual Role/RoleBinding needed at all:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Delete=false
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
  name: <namespace-name>
```

**Example**: `components/openshift-insights/` — its own core component (registered in `gitops-bases/core/applicationset.yaml`) whose base is just this Namespace manifest plus the resources that need to live there. Same pattern already used for `openshift-config`/`openshift-ingress`.

**Trade-off**: Option A has a smaller blast radius (grants exactly one resource type) but doesn't scale if a namespace needs several different resource types managed over time — each new type needs its own Role. Option B scales cleanly but grants the namespace's auto-generated Role, which is broader than a single resource type (still far short of `cluster-admin` — see the actual generated Role's rules to confirm what it covers on your cluster).

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

### ✅ CORRECT: ApplicationSet template (all components now deploy this way, not standalone Application files)

**File**: `gitops-bases/rh-connectivity-link/default/applicationset.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  finalizers:
  - resources-finalizer.argocd.argoproj.io
  name: rh-connectivity-link
  namespace: openshift-gitops
spec:
  generators:
  - list:
      elements:
      - branch: master
        item: rh-connectivity-link
  template:
    metadata:
      finalizers:
      - resources-finalizer.argocd.argoproj.io/background
      name: '{{item}}'
    spec:
      project: default  # ✅ CORRECT: use the default AppProject, not a custom one
      source:
        path: components/{{item}}/overlays/default
        repoURL: https://github.com/lautou/ocp-open-env-install-tool.git
        targetRevision: '{{branch}}'
      destination:
        server: https://kubernetes.default.svc
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        retry:
          limit: 10
      ignoreDifferences:  # ✅ CORRECT: cluster-versions ConfigMap ignored
      - group: ''
        jsonPointers:
        - /metadata/annotations
        kind: ConfigMap
        name: cluster-versions
```

### ✅ CORRECT: kuadrant-system Namespace

**File**: `components/rh-connectivity-link/base/cluster-namespace-kuadrant-system.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops  # ✅ CORRECT: managed-by label
  name: kuadrant-system
```

### ✅ CORRECT: InferenceService with SkipDryRunOnMissingResource

**File**: `components/demo-ei/base/demo-ei-inferenceservice-mistral-medium-3-5.yaml`

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true  # ✅ CORRECT
    opendatahub.io/model-type: generative
    security.opendatahub.io/enable-auth: "false"
  name: mistral-medium-3-5
  namespace: demo-ei
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
