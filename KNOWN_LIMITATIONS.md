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

## Operator Pod Placement on Infra Nodes

### Issue

**Severity:** Medium - Impacts infrastructure isolation and resource management
**Affects:** Multiple operators across different product portfolios
**Status:** Tracked in multiple RFEs and bug tickets across components

### Description

Many OpenShift operators do NOT support configuring node selectors and tolerations for their managed workloads, preventing placement on dedicated infrastructure nodes. This forces operator pods to run on worker nodes even when infra nodes are available, increasing resource costs and reducing workload isolation.

### Affected Components and Tracking

The following operators lack infra node placement configuration capabilities:

#### OpenShift Builds
- **JIRA:** [RFE-8720](https://issues.redhat.com/browse/RFE-8720)
- **Title:** "Builds for RH Openshift: Allow node-selector and taints configuration for build operator components"
- **Status:** Open - RFE (Request for Enhancement)
- **Impact:** Build controller and build pods run on worker nodes
- **Workaround:** None currently available

#### Network Observability
- **JIRA:** [NETOBSERV-2575](https://issues.redhat.com/browse/NETOBSERV-2575)
- **Title:** "Ability to configure node-selector and tolerations for netobserv-plugin-static"
- **Status:** Open
- **Impact:** netobserv-plugin-static and FlowCollector components cannot be placed on infra nodes
- **Workaround:** None currently available

#### Additional Tracked Issues

**Enhancement Requests (RFEs):**
- **[RFE-8721](https://issues.redhat.com/browse/RFE-8721)** - "Red Hat build of Kueue: Allow node-selector and taints configuration for Kueue components"
- **[RFE-8722](https://issues.redhat.com/browse/RFE-8722)** - "Node Feature Discovery: Allow node-selector and taints configuration for gc components"
- **[RFE-8791](https://issues.redhat.com/browse/RFE-8791)** - "Gateway API: Ability to configure nodeSelector/tolerations in GatewayClass"
- **[RHAIRFE-1244](https://issues.redhat.com/browse/RHAIRFE-1244)** - "Improve Install of Service Mesh 3 Operator"

**OpenShift Bugs:**
- **[OCPBUGS-9274](https://issues.redhat.com/browse/OCPBUGS-9274)** - "Ingress-canary daemonset does not tolerate Infra taints NoExecute"
- **[OCPBUGS-49690](https://issues.redhat.com/browse/OCPBUGS-49690)** - "[RHOCP4.17] networking-console-plugin pods should run on control plane nodes"
- **[OCPBUGS-51091](https://issues.redhat.com/browse/OCPBUGS-51091)** - "[RHOCP4.18] migrator pod should run on control plane node"
- **[OCPBUGS-74211](https://issues.redhat.com/browse/OCPBUGS-74211)** - "Insight runtime extractor is not deployed on tainted nodes"
- **[OCPBUGS-74232](https://issues.redhat.com/browse/OCPBUGS-74232)** - "volume-data-source-validator should run on master (control plane) node"
- **[OCPBUGS-74350](https://issues.redhat.com/browse/OCPBUGS-74350)** - "collect-profiles job in openshift-operator-lifecycle-manager namespace should run on control plane node"

**Data Foundation Bugs:**
- **[DFBUGS-5355](https://issues.redhat.com/browse/DFBUGS-5355)** - "odf-prometheus-operator and odf-external-snapshotter-operator-stable pods does not have node.ocs.openshift.io/storage toleration"

**Service Platform Bugs:**
- **[SRVKP-8922](https://issues.redhat.com/browse/SRVKP-8922)** - "The Results configuration is not being propagated from TektonConfig to Results"

### Business Impact

- **Increased costs:** Operator infrastructure workloads consume worker node resources that could be used for application workloads
- **Reduced isolation:** Cannot separate platform services from application workloads using node roles
- **Capacity planning complexity:** Must account for operator overhead on worker nodes
- **Resource contention:** Platform services compete with application workloads for CPU/memory

### Workarounds

**Per-component workarounds** (where available):

1. **Post-deployment patching** (fragile - lost on operator upgrades):
   ```bash
   # Example: Patch deployment after operator creates it
   oc patch deployment <name> -n <namespace> -p '
     spec:
       template:
         spec:
           nodeSelector:
             node-role.kubernetes.io/infra: ""
           tolerations:
           - key: node-role.kubernetes.io/infra
             operator: Exists
   '
   ```

2. **ArgoCD PostSync Jobs** (automation - see `jobs.md`):
   - Several components use Jobs to patch resources after operator deployment
   - Examples: ODF subscriptions, cluster-monitoring configurations
   - Limitation: Requires maintenance as operator APIs evolve

3. **Admission webhooks** (advanced - requires MutatingWebhookConfiguration):
   - Can intercept pod creation and inject node selectors/tolerations
   - Complex to maintain, requires careful scoping to avoid breaking workloads

**General recommendation:** Track upstream RFEs and upgrade operators when infra placement support is added.

### Verification

Check if operator pods are running on worker vs infra nodes:

```bash
# List all pods NOT on infra nodes (grouped by namespace)
oc get pods -A -o wide | grep -v 'infra' | awk '{print $1}' | sort | uniq -c

# Check specific operator namespace
oc get pods -n <namespace> -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeSelector}{"\t"}{.spec.tolerations}{"\n"}'

# Expected: Operators with RFE tracking will show no infra nodeSelector
```

### Future Resolution

Red Hat Engineering is actively working on adding infra node placement configuration to operators. Track individual JIRA tickets for progress and target OpenShift versions.

**When updating operators:** Check release notes for "infra node placement" or "node selector configuration" features.

---

## RHBK Keycloak Realm Cache Synchronization Issues

### Issue

**Component:** Red Hat build of Keycloak (RHBK)
**Severity:** High - Impacts authentication availability after pod restarts
**Affects:** Keycloak 26.0.7, Kubernetes deployments with Infinispan cache
**Status:** Open upstream (GitHub)

### Description

Keycloak realms exist in PostgreSQL database but return "404 Realm not found" errors after pod restarts. Accessing realms directly via URL works, indicating the issue is in the cache layer, not database persistence. Deleting and recreating KeycloakRealmImport resources triggers cache refresh and temporarily resolves the issue.

### Upstream Tracking

**Primary Issue:**
- **GitHub:** [keycloak/keycloak#36159](https://github.com/keycloak/keycloak/issues/36159)
- **Title:** "Realm not found while exists and works if entered directly in the URL"
- **Status:** Open (December 2024)
- **Keycloak Version:** 26.0.7
- **Priority:** Important - Must be worked on very soon
- **Symptom:** Realms exist in database but return "not found" errors, though accessing directly via URL works

**Related Issues (cache synchronization):**
- **[keycloak/keycloak#27975](https://github.com/keycloak/keycloak/issues/27975)**: "Realm cache not created in Infinispan after restart"
- **[keycloak/keycloak#22988](https://github.com/keycloak/keycloak/issues/22988)**: "Cache stampede after realm cache invalidation"

### Root Cause

Infinispan cache layer doesn't properly reload realm data from PostgreSQL after pod restarts in Kubernetes environments. The cache becomes out-of-sync with the database, causing Keycloak to believe realms don't exist even though they're present in persistent storage.

### Business Impact

- **Authentication outages:** Users cannot log in until cache is manually refreshed
- **Service disruption:** Pod restarts (scaling, upgrades, node maintenance) trigger realm unavailability
- **Operational overhead:** Requires manual intervention to delete/recreate KeycloakRealmImport CRs
- **Reduced confidence:** Deployments become fragile, discouraging Kubernetes-native Keycloak adoption

### Workaround

**Manual cache refresh** (when realms become unavailable):

```bash
# List KeycloakRealmImport resources
oc get keycloakrealmimport -A

# Delete the realm import (Keycloak Operator will detect and reconcile)
oc delete keycloakrealmimport <realm-name> -n <namespace>

# Wait for operator to recreate (watch events)
oc get keycloakrealmimport <realm-name> -n <namespace> -w

# Verify realm is accessible
curl -f https://<keycloak-host>/realms/<realm-name>/.well-known/openid-configuration
```

**Preventive measures:**
1. Monitor Keycloak pod restarts and proactively check realm availability
2. Implement health checks that verify realm accessibility (not just pod readiness)
3. Consider using Keycloak clustering with multiple replicas to reduce cache inconsistency window

### Verification

Check if realms are accessible after pod restart:

```bash
# Restart Keycloak pods
oc delete pod -n <namespace> -l app=keycloak

# Wait for pods to be ready
oc wait --for=condition=Ready pod -n <namespace> -l app=keycloak --timeout=300s

# Test realm endpoint (replace <realm-name> and <keycloak-host>)
for realm in $(oc get keycloakrealmimport -n <namespace> -o jsonpath='{.items[*].metadata.name}'); do
  echo "Testing realm: $realm"
  curl -f https://<keycloak-host>/realms/$realm/.well-known/openid-configuration || echo "FAILED: $realm not found"
done
```

**Expected behavior:** All realms should return valid OpenID configuration
**Actual behavior (bug):** Some or all realms return 404 errors

### Future Resolution

**Note:** The exact scenario (404 after pod restart → fixed by deleting KeycloakRealmImport) is not fully described in upstream issues. Consider opening a new GitHub issue referencing:
- #36159: Realm not found while exists
- #27975: Realm cache not created after restart
- Specific reproduction steps for RHBK Operator + KeycloakRealmImport pattern in OpenShift

**Track upstream issues for:**
- Infinispan cache initialization improvements
- Database-to-cache synchronization fixes
- Keycloak Operator enhancements for cache management

---

**Last Updated:** 2026-03-29
