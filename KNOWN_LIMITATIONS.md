# Known Limitations

This document tracks known limitations and workarounds in the OCP installation tool and underlying OpenShift/OLM components.

---

## OLM Install Plan Grouping (Classic OLM v0)

### Issue

**Component:** Operator Lifecycle Manager (OLM) - Classic OLM v0
**Severity:** Medium - Impacts operator lifecycle management in multi-operator environments
**Affects:** All profiles with multiple operators in the same namespace

### Description

When multiple operator subscriptions in the **same namespace** require upgrades simultaneously, OLM creates a **combined install plan**. If **any** subscription in that combined plan has `installPlanApproval: Manual`, the **entire install plan becomes Manual**, blocking upgrades for **all unrelated operators** with `installPlanApproval: Automatic`.

This defeats the purpose of `installPlanApproval: Automatic` and creates unexpected operational overhead.

### Real-World Impact

**Example from ocp-ai profile:**

The cluster runs the following operators in `openshift-operators` namespace:
- **Red Hat OpenShift AI (RHOAI)**: Automatically installs `servicemeshoperator3` with `installPlanApproval: Manual` (intentional - prevents automatic mesh upgrades that could break model serving workloads)
- **OpenShift Pipelines**: `installPlanApproval: <omitted>` (defaults to Automatic per OLM spec)
- **DevWorkspace Operator**: `installPlanApproval: <omitted>` (defaults to Automatic)
- **Web Terminal**: `installPlanApproval: <omitted>` (defaults to Automatic)

**Result:**
- OLM creates install plan `install-vq9ck` with 4 owner references (all subscriptions)
- Install plan inherits `approval: Manual` from servicemeshoperator3
- Pipelines, DevWorkspace, and Web Terminal upgrades **blocked** waiting for manual approval
- Security patches for unrelated operators require manual intervention

**Business Impact:**
- Security patches delayed (requires monitoring install plans manually)
- Operational overhead increased (manual approval for unrelated operators)
- GitOps automation defeated (automatic upgrades don't work as configured)
- Cluster drift (different clusters may have different operator versions depending on when install plans were approved)

### Root Cause

Classic OLM v0 performs dependency resolution at the **namespace level**, not per-subscription. When creating install plans:
1. OLM groups all pending upgrades in the same namespace into a single install plan
2. If any subscription has `installPlanApproval: Manual`, the combined plan becomes Manual
3. All operators in the plan block until manual approval

This is a known architectural limitation of Classic OLM v0.

### Upstream Status

Red Hat Engineering confirmed this is **expected behavior** for Classic OLM v0. The limitation is documented in:
- Red Hat Support Case: [Insert case number after filing]
- OpenShift Documentation: Operator Lifecycle Manager concepts

**Recommended Solution from Red Hat:**
Deploy operators with different approval policies to **separate namespaces** with AllNamespaces OperatorGroups.

### Workaround - Namespace Isolation (AI Profile)

For the **ocp-ai profile only**, we implement namespace isolation to prevent install plan grouping:

**Architecture:**

1. **Standard profiles** (ocp-standard, ocp-acs-central, etc.):
   - Reference: `gitops-bases/devops/default/applicationset.yaml`
   - Components use: `components/{pipelines,webterminal}/overlays/default`
   - Operators deploy to: `openshift-operators` (shared namespace)
   - Behavior: Pipelines/Web Terminal blocked by RHOAI Service Mesh Manual approval (accepted limitation)

2. **AI profile** (ocp-ai):
   - Reference: `gitops-bases/devops/ai/applicationset.yaml`
   - Components use: `components/{pipelines,webterminal}/overlays/ai`
   - Operators deploy to:
     - `openshift-pipelines-operator` (dedicated namespace for Pipelines)
     - `openshift-dev-terminal` (dedicated namespace for DevWorkspace + Web Terminal)
   - Each namespace has AllNamespaces OperatorGroup (empty spec)
   - Behavior: Separate install plans per namespace, Automatic approval works correctly

**Implementation Details:**

AI overlays create dedicated namespaces and OperatorGroups:

```yaml
# components/openshift-pipelines/overlays/ai/
- cluster-namespace-openshift-pipelines-operator.yaml
- openshift-pipelines-operator-operatorgroup-openshift-pipelines-operator.yaml
- kustomization.yaml (sets namespace: openshift-pipelines-operator)

# components/webterminal/overlays/ai/
- cluster-namespace-openshift-dev-terminal.yaml
- openshift-dev-terminal-operatorgroup-openshift-dev-terminal.yaml
- kustomization.yaml (sets namespace: openshift-dev-terminal)
```

All namespaces include the label:
```yaml
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
```

**Why DevWorkspace and Web Terminal share a namespace:**

DevWorkspace Operator is a **dependency** of Web Terminal. Both must be in the same namespace for OLM dependency resolution to work correctly.

**Result:**
- RHOAI Service Mesh remains in `openshift-operators` with Manual approval (controlled upgrades)
- Pipelines in `openshift-pipelines-operator` with Automatic approval (independent install plans)
- DevWorkspace + Web Terminal in `openshift-dev-terminal` with Automatic approval (independent install plans)
- No install plan grouping across namespaces

**Trade-offs:**
- ✅ Automatic upgrades work as intended for platform operators
- ✅ RHOAI Service Mesh retains Manual approval for production stability
- ✅ Security patches for Pipelines/Web Terminal applied automatically
- ⚠️ Additional namespaces created (acceptable complexity for AI profile)
- ⚠️ Profile-specific configuration (standard profiles accept blocking behavior)

### Why Standard Profiles Don't Use This Workaround

Standard profiles (ocp-standard, ocp-acs-central, etc.) do NOT implement namespace isolation because:
1. They don't include RHOAI (no Manual approval operators)
2. All operators use Automatic approval (or omit field, which defaults to Automatic)
3. Install plan grouping is harmless when all operators have the same approval mode
4. Keeping all operators in `openshift-operators` is simpler and matches OpenShift conventions

The workaround is **only necessary** when mixing Manual and Automatic approval modes in the same deployment.

### Future Resolution

Red Hat is developing **OLM v1** which will address this limitation with improved dependency resolution. When OLM v1 becomes the default in OpenShift, this workaround may no longer be necessary.

**Tracking:**
- OLM v1 Development: https://github.com/operator-framework/operator-controller
- OpenShift Integration Timeline: TBD (check OpenShift roadmap)

### References

- **Technical Report:** `/tmp/redhat-olm-issue-report.md` (detailed analysis for Red Hat Engineering)
- **Red Hat Documentation:** [Operator Lifecycle Manager concepts](https://docs.openshift.com/container-platform/latest/operators/understanding/olm/olm-understanding-olm.html)
- **Component Implementation:**
  - `gitops-bases/devops/default/applicationset.yaml` - Standard profiles
  - `gitops-bases/devops/ai/applicationset.yaml` - AI profile with namespace isolation
  - `components/openshift-pipelines/overlays/ai/` - AI overlay with dedicated namespace
  - `components/webterminal/overlays/ai/` - AI overlay with dedicated namespace

---

**Last Updated:** 2026-03-20
