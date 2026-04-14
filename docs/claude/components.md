# Component-Specific Configuration

**Purpose**: Detailed configuration patterns and special behaviors for GitOps components.

**Note**: Only components with non-standard patterns or special requirements are documented here. Simple operator deployments without special configuration are intentionally omitted (discoverable via filesystem).

## ⚠️ IMPORTANT: ignoreDifferences Guidance

**Default**: Avoid ignoreDifferences. Most components do NOT need it.

**When adding ignoreDifferences**:
1. **Test first** - Try without ignoreDifferences, only add if sync fails
2. **Minimal scope** - Add one field at a time, test each addition
3. **Verify necessity** - Check if RBAC/namespace labels solve the issue instead
4. **Document why** - Explain the specific conflict being resolved

**Common mistakes**:
- ❌ Adding entire `/metadata` block when only `/metadata/annotations` needed
- ❌ Copying ignoreDifferences from other resources without testing
- ❌ Ignoring fields that ArgoCD can manage with proper RBAC

**Recent validations** (2026-03-30):
- Cluster-scoped resources (APIServer, Network): RBAC sufficient, no ignores needed
- Namespace-scoped operator CRs (HardwareProfile, OdhDashboardConfig): namespace managed-by label sufficient
- Shared ConfigMaps (cluster-versions): Only annotations need ignoring

See CLAUDE.md for complete ignoreDifferences patterns and testing workflow.

## Console Plugins

**Pattern**: Pure Patch Jobs (no static manifests)

**Why Jobs only:**
- Console is a **shared resource** modified by 4 components
- Static manifests would overwrite each other
- Jobs use `oc patch` with JSON Patch to ADD plugins incrementally
- Each Job is idempotent and checks if plugin already exists

**Components with console plugins:**
- `openshift-gitops-admin-config` → `gitops-plugin`
- `openshift-pipelines` → `pipelines-console-plugin`
- `openshift-storage` → `odf-console`, `odf-client-console`
- `rh-connectivity-link` → `kuadrant-console-plugin`

**Implementation:**
Each component includes:
1. Patch Job `openshift-gitops-job-enable-*-console-plugin.yaml` that adds plugin if not present
2. Job runs with `Force=true` to ensure execution on every sync
3. Idempotent check prevents duplicate additions

## OpenShift GitOps (ArgoCD)

**Purpose**: Manages Day 2 cluster configuration through GitOps principles.

**Namespace**: `openshift-gitops`

**Configuration**: `components/openshift-gitops-admin-config/base/openshift-gitops-argocd-openshift-gitops.yaml`

**Key Configurations:**

1. **Controller Memory Limits** (Critical):
   ```yaml
   controller:
     resources:
       limits:
         cpu: '2'
         memory: 8Gi  # Version-specific, see below
       requests:
         cpu: 250m
         memory: 2Gi
   ```

   **Version-Specific Memory Requirements**:
   
   | GitOps Version | Min Memory | Recommended | Cluster Size |
   |----------------|------------|-------------|--------------|
   | 1.19.x | 4Gi | 4Gi | 25-30 Applications |
   | 1.20.x+ | 6Gi | **8Gi** | 30-35 Applications |
   
   **Why 8Gi for GitOps 1.20+?**
   - GitOps 1.20 (ArgoCD 3.3+) has significantly higher memory requirements than 1.19
   - Testing showed OOMKills (exit code 137) with both 4Gi and 6Gi during reconciliation
   - 8Gi provides stable operation with 33+ Applications
   - Likely due to improved caching and concurrent reconciliation in newer version
   - Memory usage spikes during ApplicationSet rollouts and bulk syncs
   
   **Upgrade Note**: When upgrading from GitOps 1.19 to 1.20, increase memory to 8Gi **before** or **immediately after** operator upgrade to prevent OOMKill crashes during initial reconciliation.

2. **ApplicationSet Retry Configuration**:
   All ApplicationSets configured with:
   ```yaml
   syncPolicy:
     automated:
       prune: true
       selfHeal: true
     retry:
       limit: 10  # Increased from default 5-7
   ```

   **Why retry limit 10?**
   - Addresses CRD timing issues during cluster bootstrap
   - Operators may not have created CRDs when ArgoCD first syncs
   - Exponential backoff means later retries have sufficient delay
   - By retry 10, enough time has passed for operator bootstrapping
   - Prevents manual intervention for transient CRD availability issues

3. **RBAC Configuration**:

   **ArgoCD Default Policy**:
   ```yaml
   rbac:
     defaultPolicy: ''
     policy: |
       g, system:cluster-admins, role:admin
       g, cluster-admins, role:admin
     scopes: '[groups]'
   ```

   **Namespace-Level RBAC via `argocd.argoproj.io/managed-by` Label**:

   When a namespace has the label `argocd.argoproj.io/managed-by: openshift-gitops`, the OpenShift GitOps operator automatically creates a Role and RoleBinding in that namespace granting the ArgoCD application controller ServiceAccount permissions to manage resources.

   **Auto-Generated Role Pattern**:
   ```yaml
   # Auto-created by OpenShift GitOps operator
   kind: Role
   metadata:
     namespace: <labeled-namespace>
     name: openshift-gitops-argocd-application-controller
   rules:
   - apiGroups: ['*']
     resources: ['*']
     verbs: [get, list, watch]  # READ permissions for ALL resources
   
   # Then specific write permissions for certain resources:
   - apiGroups: [monitoring.coreos.com]
     resources: ['*']
     verbs: ['*']
   - apiGroups: [operators.coreos.com]
     resources: [subscriptions]
     verbs: [create, update, patch, delete]
   # ... additional specific write grants
   ```

   **Key Behavior**:
   - ✅ **All resources get READ access** (`get, list, watch`) - ArgoCD can discover and monitor everything
   - ⚠️ **Only specific resources get WRITE access** - Not all CRDs are included in write permissions
   - ⚠️ **Custom Resources often need explicit RBAC** - If ArgoCD cannot patch/create a CR, add explicit Role + RoleBinding

   **When to add explicit namespace RBAC**:
   - ArgoCD sync fails with `is forbidden: cannot create/patch resource`
   - Resource is a Custom Resource not in the auto-generated write list
   - Create Role + RoleBinding in the same namespace granting specific permissions

   **Examples requiring explicit RBAC**:
   - `searches.search.open-cluster-management.io` (RHACM) - See RHACM section
   - `gateways.gateway.networking.k8s.io` (Gateway API) - See cluster-ingress component

   **Additional ClusterRole Grants**:

   ArgoCD requires explicit RBAC permissions for cluster-scoped resources and some namespace-scoped resources not covered by the namespace label. The following ClusterRoles grant the ArgoCD application controller ServiceAccount permissions to manage specific resource types.

   **Operator-Specific ClusterRoles**:

   ClusterRoles grant permissions for operator-managed resources:
   - `cert-manager-operator`: Manage cert-manager CRs (Certificate, ClusterIssuer)
   - `console-plugin-manager`: Patch Console CR for plugin enablement
   - `cleanup-operator`: Delete installer pods in kube-system
   - `ack-config-operator`: Manage ACK Route53 configuration
   - `gpu-machineset-operator`: Manage GPU MachineSets

   See `components/openshift-gitops-admin-config/base/` for complete RBAC definitions.

4. **Resource Exclusions**:
   ```yaml
   resourceExclusions: |
     - apiGroups:
       - tekton.dev
       clusters:
       - '*'
       kinds:
       - TaskRun
       - PipelineRun
   ```
   Prevents ArgoCD from managing ephemeral Tekton resources.

5. **Gateway API Resource Health Checks**:
   Custom health checks for Gateway API resources to properly assess health status:

   **Gateway health check:**
   - Checks for `Programmed` condition status
   - Ignores `NoMatchingListenerHostname` reason (expected state)
   - Marks as Degraded if Programmed=False
   - Uses `observedGeneration` to ensure condition is current

   **HTTPRoute health check:**
   - Checks for `Accepted` condition per parent gateway
   - Ignores `NoMatchingListenerHostname` reason (expected state)
   - Marks as Degraded if Accepted=False
   - Reports which parent gateway rejected the route
   - Uses `observedGeneration` to ensure condition is current

   **Why custom health checks needed:**
   - Gateway API resources are not well-handled by ArgoCD's default health checks
   - Prevents false degraded states in ArgoCD UI
   - Provides accurate health information based on Gateway API specification
   - Critical for RHCL (Kuadrant) component which heavily uses Gateway/HTTPRoute resources

   **Configuration:** `spec.resourceHealthChecks` in ArgoCD CR (Lua scripts)

6. **ConfigManagementPlugin (CMP) for Dynamic Cluster Configuration**:

   **Purpose**: Automatically discovers cluster domain, region, and AWS credentials, replacing placeholders in manifests at ArgoCD build time.

   **Architecture**: ConfigManagementPlugin (CMP) sidecar in ArgoCD repo-server pod.

   **How It Works**:

   1. **Plugin Discovery**: ArgoCD detects repositories with `**/kustomization.yaml` files
   2. **API Queries**: CMP queries OpenShift and Kubernetes APIs for cluster configuration
      - DNS API: `dnses.config.openshift.io/cluster` for domain
      - Infrastructure API: `infrastructures.config.openshift.io/cluster` for region
      - Secret API: `secrets/aws-creds` in `kube-system` namespace for AWS credentials
   3. **Value Calculation**:
      - `BASE_DOMAIN`: Discovered from DNS API (e.g., `myocp.sandbox3491.opentlc.com`)
      - `CLUSTER_DOMAIN`: Calculated as `apps.${BASE_DOMAIN}` (e.g., `apps.myocp.sandbox3491.opentlc.com`)
      - `ROOT_DOMAIN`: Parent domain (e.g., `sandbox3491.opentlc.com`)
      - `CLUSTER_REGION`: Discovered from Infrastructure API (e.g., `eu-central-1`, fallback: `unknown` for non-AWS)
      - `AWS_ACCESS_KEY_ID`: Extracted and base64-decoded from `aws-creds` Secret
      - `AWS_SECRET_ACCESS_KEY`: Extracted and base64-decoded from `aws-creds` Secret
   4. **Placeholder Replacement**: Runs `kustomize build . | sed` to replace placeholders in output

   **Placeholder Naming Convention**:
   All CMP placeholders use the `CMP_PLACEHOLDER_` prefix for consistency and clarity:
   - `CMP_PLACEHOLDER_ROOT_DOMAIN`: Parent domain (e.g., `sandbox3491.opentlc.com`)
   - `CMP_PLACEHOLDER_OCP_CLUSTER_DOMAIN`: Base cluster domain (e.g., `myocp.sandbox3491.opentlc.com`)
   - `CMP_PLACEHOLDER_OCP_APPS_DOMAIN`: Apps subdomain (e.g., `apps.myocp.sandbox3491.opentlc.com`) - for Routes, Gateway HTTPRoutes
   - `CMP_PLACEHOLDER_OCP_API_DOMAIN`: API subdomain (e.g., `api.myocp.sandbox3491.opentlc.com`)
   - `CMP_PLACEHOLDER_TIMESTAMP`: Unix timestamp (e.g., `1774792401`) - for unique DNS challenge names in Let's Encrypt DNS-01
   - `CMP_PLACEHOLDER_CLUSTER_REGION`: AWS region (e.g., `eu-central-1`) - for region-specific configs, S3 endpoints
   - `CMP_PLACEHOLDER_AWS_ACCESS_KEY_ID`: AWS access key for static Secret data fields
   - `CMP_PLACEHOLDER_AWS_SECRET_ACCESS_KEY`: AWS secret key for static Secret data fields

   **Naming benefits**: Consistent prefix pattern, clear CMP identification, semantic naming (OCP_APPS_DOMAIN vs CLUSTER_DOMAIN), no collisions with YAML keys or bash variables

   **⚠️ TIMESTAMP behavior** (DEPRECATED - Removed from Certificate manifests):
   - **NOT cached per commit**: CMP runs `date +%s` (current time), generates NEW timestamp on every Git sync
   - **Causes certificate regeneration**: Every Git commit (even unrelated changes) triggers new cert requests
   - **Let's Encrypt rate limits**: Risk of hitting 5 certificates/domain/week limit with frequent commits
   - **Removed from usage**: TIMESTAMP no longer used in Certificate dnsNames (2026-03-29)
   - **Reason**: Let's Encrypt DNS-01 validation does not require unique dnsNames per deployment

   **Why TIMESTAMP was removed**:
   - CMP plugin generates current Unix timestamp (`date +%s`), NOT commit-based
   - Every Git sync (even documentation changes) regenerates TIMESTAMP
   - Changed Certificate dnsNames trigger new cert-manager requests to Let's Encrypt
   - Let's Encrypt DNS-01 validation does NOT require unique dnsNames
   - Static dnsNames (`apps.*.opentlc.com`, `*.apps.*.opentlc.com`) work correctly

   **Implementation**:
   ```yaml
   # ArgoCD CR modification (openshift-gitops-argocd-openshift-gitops.yaml)
   spec:
     repo:
       mountsatoken: true  # Enable ServiceAccount token for Kubernetes API access
       sidecarContainers:
       - name: cmp-cluster-domain
         image: registry.redhat.io/openshift-gitops-1/argocd-rhel9@sha256:ddf6e5c439...
         # RHEL9-based image required for ArgoCD 3.3+ (GLIBC 2.32/2.34 compatibility)
         # ServiceAccount token auto-mounted at /var/run/secrets/kubernetes.io/serviceaccount/
       volumes:
       - name: cmp-plugin
         configMap:
           name: cmp-plugin  # Plugin definition
   ```

   **CRITICAL: ArgoCD 3.3+ Requires RHEL9 Image**

   ArgoCD 3.3.2 (included in OpenShift GitOps 1.20) requires GLIBC 2.32+ and 2.34+ for the argocd-cmp-server binary:
   - ❌ `argocd-rhel8` image: GLIBC too old → CMP container crashes with "version not found" errors
   - ✅ `argocd-rhel9` image: GLIBC 2.34+ → CMP container runs successfully

   **Error without RHEL9**:
   ```
   /var/run/argocd/argocd-cmp-server: /lib64/libc.so.6: version `GLIBC_2.34' not found
   /var/run/argocd/argocd-cmp-server: /lib64/libc.so.6: version `GLIBC_2.32' not found
   ```

   **After upgrading OpenShift GitOps to 1.20+**, you MUST update the CMP sidecar image to RHEL9.

   **RBAC Requirements**:
   - ClusterRole: `argocd-cmp-dns-reader` (grants `get/list` on `dnses.config.openshift.io` and `infrastructures.config.openshift.io`, plus `get` on `secrets/aws-creds` in `kube-system`)
   - ClusterRoleBinding: Binds to `default` ServiceAccount in `openshift-gitops` namespace

   **Files**:
   - ConfigMap: `components/openshift-gitops-admin-config/base/openshift-gitops-configmap-cmp-plugin.yaml`
   - ClusterRole: `components/openshift-gitops-admin-config/base/cluster-clusterrole-argocd-cmp-dns-reader.yaml`
   - ClusterRoleBinding: `components/openshift-gitops-admin-config/base/cluster-crb-argocd-cmp-dns-reader.yaml`

   **Verification**:
   ```bash
   # Check sidecar running (should show 2/2 containers)
   oc get pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-repo-server

   # Check CMP logs for discovered values
   oc logs <repo-server-pod> -n openshift-gitops -c cmp-cluster-domain --tail=50 | grep "\[CMP\]"
   # Expected output:
   # [CMP] Discovered BASE_DOMAIN: myocp.sandbox3491.opentlc.com
   # [CMP] Discovered REGION: eu-central-1
   # [CMP] Computed CLUSTER_DOMAIN: apps.myocp.sandbox3491.opentlc.com
   # [CMP] Computed ROOT_DOMAIN: sandbox3491.opentlc.com
   # [CMP] AWS credentials available: YES
   ```

   **When to use CMP_PLACEHOLDER_CLUSTER_REGION**:
   - ✅ Static ConfigMap/Secret data fields with region values
   - ✅ Resource annotations/labels referencing region
   - ✅ Any YAML field that doesn't require runtime evaluation
   - ❌ NOT for bash variables in Jobs (use distinct names like `OCP_REGION`, `BASE_REGION`, `AWS_REGION` to avoid conflicts)

   **When to use CMP_PLACEHOLDER_AWS_ACCESS_KEY_ID / CMP_PLACEHOLDER_AWS_SECRET_ACCESS_KEY**:
   - ✅ Static Secret stringData fields containing AWS credentials
   - ✅ Avoids YAML key name collisions (Secret field names remain unchanged, only values replaced)
   - ✅ Eliminates runtime extraction Jobs (simplifies architecture)
   - ❌ NOT for temporary/rotated credentials (placeholders are baked at ArgoCD build time)
   - ❌ NOT for cross-namespace credential distribution (create Secret in target namespace)

   **Security note**: Credentials are replaced at ArgoCD build time, visible in ArgoCD UI (base64-encoded). Suitable for operator-managed credentials that ArgoCD already has access to via RBAC.

   **When to use CMP_PLACEHOLDER_TIMESTAMP** (DEPRECATED):
   - ❌ **DO NOT USE** - Removed from all manifests (2026-03-29)
   - ❌ NOT for Certificate dnsNames (causes unnecessary regeneration on every Git commit)
   - ❌ NOT cached per commit (uses `date +%s` = current time, not deterministic)
   - ❌ Risk of Let's Encrypt rate limits (5 certs/domain/week with frequent commits)

   **Self-Protection Mechanism**:

   The CMP plugin includes two layers of self-protection to prevent corrupting its own ConfigMap:

   1. **Directory Detection** (runtime protection):
      - **Detection**: Checks if working directory contains `openshift-gitops-admin-config`
      - **Action**: Skips placeholder replacement (runs `kustomize build` without `sed`)
      - **Log message**: `[CMP] Detected openshift-gitops-admin-config component, skipping placeholder replacement to avoid self-corruption`

   2. **Variable Naming Convention** (build-time protection):
      - **Internal variables**: Use distinct names (`DISCOVERED_REGION`, `DISCOVERED_AWS_KEY`, `COMPUTED_CLUSTER_DOMAIN`)
      - **Placeholders**: Use `CMP_PLACEHOLDER_` prefix (`CMP_PLACEHOLDER_CLUSTER_REGION`, `CMP_PLACEHOLDER_AWS_ACCESS_KEY_ID`, `CMP_PLACEHOLDER_CLUSTER_DOMAIN`)
      - **Rationale**: Internal variable names never match placeholder names, preventing sed self-corruption
      - **Example**: `DISCOVERED_REGION` variable won't be replaced by `s|CMP_PLACEHOLDER_CLUSTER_REGION|...|g` sed command

   This two-layer approach allows the openshift-gitops-admin-config component to be managed by ArgoCD without the CMP plugin corrupting its own definition.

   **Important**: Plugin applies automatically to all kustomize-based Applications. No special configuration needed in Application manifests.

**Troubleshooting:**

Common issues and solutions:

1. **Controller OOMKilled**:
   - Symptom: Pod restarts with exit code 137
   - Solution: Memory limit increased to 4Gi (already applied)
   - Verification: `oc get pod -n openshift-gitops -l app.kubernetes.io/name=argocd-application-controller`

2. **Applications stuck OutOfSync with CRD errors**:
   - Symptom: "resource mapping not found: no matches for kind X"
   - Solution: Retry limit set to 10 (already applied in all ApplicationSets)
   - Wait for automatic retry or manually sync application

3. **ApplicationSet ownership conflicts**:
   - Symptom: "Object X is already owned by another ApplicationSet controller Y"
   - Solution: Delete conflicting Application, let correct ApplicationSet recreate it
   - Example: When moving applications between ApplicationSets (core → devops)

**Version Management:**

ArgoCD version follows OpenShift GitOps operator channel (managed by OLM).

**Current Versions** (as of 2026-04-01):
- OpenShift GitOps Operator: 1.20.0
- ArgoCD: v3.3.2+8a3940d
- Channel: `gitops-1.20`

**Upgrade Path**:
When upgrading OpenShift GitOps operator, verify CMP sidecar image compatibility:
- OpenShift GitOps 1.19 (ArgoCD 3.1): `argocd-rhel8` image compatible
- OpenShift GitOps 1.20+ (ArgoCD 3.3+): `argocd-rhel9` image **required**

Update the CMP sidecar image in `components/openshift-gitops-admin-config/base/openshift-gitops-argocd-openshift-gitops.yaml` after operator upgrades.

## Cluster Network (AdminNetworkPolicy)

**Pattern**: Zero-trust network isolation using AdminNetworkPolicy (ANP) + BaselineAdminNetworkPolicy (BANP)

**Architecture**: Defense-in-depth with three priority tiers
1. **AdminNetworkPolicy** (priority 10, highest) - Explicit Allow rules for cluster services
2. **NetworkPolicy** (medium priority) - User/developer policies (if any)
3. **BaselineAdminNetworkPolicy** (lowest priority) - Default deny fallback

**Opt-in mechanism**: Policies only apply to namespaces labeled `network-policy.gitops/enforce: "true"`

**Resources**:
- `components/cluster-network/base/cluster-adminnetworkpolicy-gitops-standard.yaml`
- `components/cluster-network/base/cluster-baselineadminnetworkpolicy-gitops-baseline.yaml`
- RBAC: `components/cluster-network/base/cluster-clusterrole-manage-admin-network-policies.yaml` (ArgoCD permissions)

**API Version**: `policy.networking.k8s.io/v1alpha1` (OpenShift 4.20)

**Subject (where policy applies)**:
```yaml
subject:
  namespaces:
    matchLabels:
      network-policy.gitops/enforce: "true"
```

Only namespaces with this label have ANP rules applied (opt-in mechanism).

**ANP Rules** (action: Allow, cannot be overridden):

**Ingress Rules** (FROM these namespaces):

| Rule | Namespace Selector | Label Used | Purpose |
|------|-------------------|------------|---------|
| `allow-openshift-ingress` | `network.openshift.io/policy-group: ingress` | OpenShift auto-labeled | Ingress controller routing |
| `allow-openshift-monitoring` | `kubernetes.io/metadata.name: openshift-monitoring` | Kubernetes auto-labeled | Prometheus scraping |
| `allow-openshift-user-workload-monitoring` | `kubernetes.io/metadata.name: openshift-user-workload-monitoring` | Kubernetes auto-labeled | UWM Prometheus scraping |

**Egress Rules** (TO these destinations):

| Rule | Namespace Selector | Label Used | Purpose |
|------|-------------------|------------|---------|
| `allow-dns` | `kubernetes.io/metadata.name: openshift-dns` | Kubernetes auto-labeled | DNS queries (5353 UDP/TCP) |
| `allow-kube-api` | `nodes:` (control-plane) | Node selector, not namespace | Kubernetes API (6443 TCP) |
| `allow-openshift-ingress` | `network.openshift.io/policy-group: ingress` | OpenShift auto-labeled | App routing |
| `allow-openshift-logging` | `kubernetes.io/metadata.name: openshift-logging` | Kubernetes auto-labeled | Log forwarding |
| `allow-openshift-monitoring` | `kubernetes.io/metadata.name: openshift-monitoring` | Kubernetes auto-labeled | Metrics pushing |

### Network Diagnostics Configuration

**Pattern**: Static manifest for shared cluster-scoped resource

**File**: `components/cluster-network/base/cluster-network-cluster.yaml`

```yaml
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  networkDiagnostics:
    sourcePlacement:
      nodeSelector:
        kubernetes.io/os: linux
        node-role.kubernetes.io/infra: ''
      tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
```

**Purpose**: Configures network diagnostics pods to run on infrastructure nodes.

**Field ownership**:
- **GitOps manages**: `spec.networkDiagnostics.sourcePlacement` (infra node placement)
- **OpenShift manages**: `spec.clusterNetwork`, `spec.serviceNetwork`, `spec.networkType`, `spec.externalIP` (set during installation)

**No ignoreDifferences needed**: Both systems coexist, each managing their own fields. No sync conflicts occur.

### AdminNetworkPolicy Labels

**Label Types**:

1. **Standard Kubernetes labels** (auto-created):
   - `kubernetes.io/metadata.name: <namespace-name>` - Every namespace has this set to its name

2. **OpenShift policy-group labels** (auto-created for infra namespaces):
   - `network.openshift.io/policy-group: ingress` - Applied to openshift-ingress

3. **Custom opt-in label** (manual):
   - `network-policy.gitops/enforce: "true"` - Apply to enable ANP for namespace

**Example selector patterns**:
```yaml
# Pattern 1: Match by namespace name (standard Kubernetes label)
namespaces:
  matchLabels:
    kubernetes.io/metadata.name: openshift-monitoring

# Pattern 2: Match by policy group (OpenShift infrastructure label)
namespaces:
  matchLabels:
    network.openshift.io/policy-group: ingress

# Pattern 3: Match control-plane nodes (for Kube API)
nodes:
  matchExpressions:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
```

**Note**: Same-namespace traffic is NOT controlled by ANP. Use namespace-scoped NetworkPolicy for intra-namespace isolation.

**BANP Rules** (action: Deny, applies when nothing else matches):
- Deny all egress to 0.0.0.0/0 (blocks everything not explicitly allowed)

**Why this architecture**:
- ANP guarantees critical cluster services always work (highest priority)
- Developer NetworkPolicies can add restrictions without breaking monitoring/ingress
- BANP provides default-deny fallback only when ANP and NetworkPolicy don't match
- Prevents accidental lockout scenarios (DNS, monitoring, ingress always allowed)

**⚠️ IMPORTANT: sameLabels NOT SUPPORTED in v1alpha1**

The `sameLabels` and `notSameLabels` fields were **removed from the AdminNetworkPolicy v1alpha1 API** used in OpenShift 4.20. These fields were originally designed for tenancy use cases but were removed due to complexity concerns.

**What happened:**
- `sameLabels` was intended to allow same-namespace traffic control
- The upstream community removed it from v1alpha1 API
- When OVN-Kubernetes encounters `sameLabels`, it normalizes it to `namespaces: {}` (matches ALL namespaces - dangerous!)
- NPEP-122 is being developed as a better tenancy API proposal

**For same-namespace traffic isolation:**
Use **NetworkPolicy** (namespace-scoped) instead of AdminNetworkPolicy (cluster-scoped):

```yaml
# Use NetworkPolicy for same-namespace traffic
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: <your-namespace>
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector: {}
  egress:
  - to:
    - podSelector: {}
```

**References:**
- [NPEP-122: Better tenancy API proposal](https://network-policy-api.sigs.k8s.io/npeps/npep-122/)
- [AdminNetworkPolicy OVN-Kubernetes docs](https://ovn-kubernetes.io/features/network-security-controls/admin-network-policy/)

**Deployment impact**: Zero until namespace labeled. Safe incremental rollout.

**Enable for namespace**:
```bash
oc label namespace <namespace-name> network-policy.gitops/enforce=true
```

**⚠️ CRITICAL: Kubernetes API Access Requires `nodes:` Selector**

**Problem**: IP-based rules (`networks: [172.30.0.1/32]`) DO NOT work for Kubernetes API access.

**Root Cause**: OVN-Kubernetes performs DNAT **before** ANP evaluation:
- Service IP `172.30.0.1:443` → Control-Plane-Node-IP:`6443`
- ANP sees post-DNAT destination (node IP, not service IP)
- Host-network endpoints require `nodes:` peer selector

**Correct syntax** (use `nodes:` selector with port 6443):
```yaml
egress:
- name: allow-kube-api
  action: Allow
  to:
  - nodes:
      matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
  ports:
  - portNumber:
      port: 6443  # API server host port (post-DNAT)
      protocol: TCP
```

**Why this works**:
- Matches control plane nodes (where kube-apiserver runs on host network)
- Uses port 6443 (API server host port, not Service port 443)
- Works with host-network endpoints (nodes don't belong to pod network)

**Failed approaches** (do NOT use):
- ❌ `networks: [172.30.0.1/32]` - ANP sees node IP after DNAT
- ❌ `networks: [172.30.0.0/16]` - Node IPs not in service CIDR
- ❌ `namespaces: {matchLabels: {kubernetes.io/metadata.name: default}}` - Nodes not in pod network

**This is intended behavior** (confirmed by Red Hat Engineering, 2026-03-27):
- Network policies evaluate post-DNAT (resolved endpoint IPs)
- Not a bug or limitation of ANP v1alpha1

**Requirements**:
- OVN-Kubernetes network plugin (default in OpenShift 4.11+)
- AdminNetworkPolicy API v1alpha1 (available in OpenShift 4.14+)

## cert-manager

**Architecture**: Static manifests with CMP placeholders + Watchdog Deployment for operator health monitoring.

**Certificate Issuance** (managed in `cert-manager` component):
- ClusterIssuer with Let's Encrypt DNS-01 challenge
- Certificate resources with CMP placeholders for dynamic domains
- Static Secret for AWS Route53 credentials (CMP extracts from kube-system/aws-creds)

**Certificate Usage** (managed in separate components):
- IngressController: `cluster-ingress` component
- APIServer: `openshift-config` component

**Files**:
- `components/cert-manager/base/cert-manager-clusterissuer-cluster.yaml` - Let's Encrypt ACME issuer
- `components/cert-manager/base/openshift-ingress-certificate-ingress.yaml` - Ingress wildcard certificate
- `components/cert-manager/base/openshift-config-certificate-api.yaml` - API server certificate
- `components/cert-manager/base/cert-manager-secret-aws-acme.yaml` - AWS credentials for Route53 DNS-01
- `components/cert-manager/base/openshift-gitops-deployment-watchdog-certmanager.yaml` - CM-412 watchdog

**CMP Placeholder Usage**:
```yaml
# Static Certificate with dynamic domains
spec:
  commonName: CMP_PLACEHOLDER_OCP_APPS_DOMAIN
  dnsNames:
  - CMP_PLACEHOLDER_OCP_APPS_DOMAIN
  - '*.CMP_PLACEHOLDER_OCP_APPS_DOMAIN'
```

**Note**: CMP_PLACEHOLDER_TIMESTAMP was removed from Certificate dnsNames (2026-03-29) due to Let's Encrypt rate limit concerns. Static dnsNames work correctly for DNS-01 validation.

**IngressController Configuration** (cluster-ingress component):

**Pattern**: Static manifest + ignoreDifferences for shared resource

**File**: `components/cluster-ingress/base/openshift-ingress-operator-ingresscontroller-default.yaml`

```yaml
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Delete=false,SkipDryRunOnMissingResource=true
spec:
  defaultCertificate:
    name: ingress-certificates
```

**Why static manifest works**:
- IngressController is a **shared resource** (created by OpenShift installer)
- GitOps manages only `defaultCertificate` field
- `ignoreDifferences` prevents ArgoCD from trying to delete/recreate the resource
- `SkipDryRunOnMissingResource` allows sync before Certificate Secret exists

**Lesson learned**:
- ✅ Static + ignoreDifferences works for **shared resources** when ignoring fields NOT in Git
- ❌ Static + ignoreDifferences fails when ignoring fields IN Git (logical contradiction)

**APIServer Configuration** (openshift-config component):

**Pattern**: Static manifest for shared cluster-scoped resource

**File**: `components/openshift-config/base/cluster-apiserver-cluster.yaml`

```yaml
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Delete=false,SkipDryRunOnMissingResource=true
  name: cluster
spec:
  servingCerts:
    namedCertificates:
    - names:
      - CMP_PLACEHOLDER_OCP_API_DOMAIN
      servingCertificate:
        name: api-certificates
```

**Why static manifest works**:
- APIServer is a **shared resource** (created by OpenShift installer)
- GitOps manages only `servingCerts.namedCertificates` field
- OpenShift manages installation fields (`spec.audit`, metadata annotations, ownerReferences)
- CMP placeholder replaced with actual API domain at build time

**RBAC**: `openshift-gitops-clusterrole-cert-manager-operator` grants `patch` permissions on `apiservers`

**No ignoreDifferences needed**: Explicit ClusterRole RBAC is sufficient. ArgoCD and OpenShift coexist, each managing their own fields.

**Watchdog Deployment** (CM-412 workaround):

**Purpose**: Continuous monitoring for cert-manager operator stuck states, with automatic recovery.

**File**: `components/cert-manager/base/openshift-gitops-deployment-watchdog-certmanager.yaml`

**Implementation**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: watchdog-certmanager
  namespace: openshift-gitops
spec:
  replicas: 1
  template:
    spec:
      containers:
      - command: ["/scripts/watchdog-certmanager.sh"]
        image: registry.redhat.io/openshift4/ose-cli:latest
        resources:
          requests:
            cpu: 10m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
        volumeMounts:
        - mountPath: /scripts
          name: scripts
      volumes:
      - configMap:
          name: cert-manager-scripts
          defaultMode: 0755
```

**Monitoring Logic**:

Detects two types of stuck states (checks every 60 seconds):

**STUCK SCENARIO 1: Race Condition (CR exists but no reconciliation)**
- CertManager CR exists
- NO deploymentAvailable conditions present (operator didn't reconcile)
- NO pods created in cert-manager namespace
- CR age > 120 seconds (grace period for initial deployment)

**Detection**:
```bash
# Check if conditions are missing
if [ -z "$CONTROLLER_AVAILABLE" ] && [ -z "$CAINJECTOR_AVAILABLE" ] && [ -z "$WEBHOOK_AVAILABLE" ]; then
  # Check if no pods and CR old enough
  POD_COUNT=$(oc get pods -n cert-manager --no-headers | wc -l)
  if [ "$POD_COUNT" -eq 0 ] && [ "$CR_AGE" -gt 120 ]; then
    oc delete certmanager cluster  # Operator race condition - force recreation
  fi
fi
```

**Why this happens**:
- Watchdog or ArgoCD deletes CertManager CR
- ArgoCD immediately recreates it (self-heal enabled)
- Operator tries to create default CR but sees it already exists
- Operator enters stuck state without reconciling
- CR exists but operator never creates deployments/conditions

**Real-world occurrence**: 2026-03-29 19:07-20:16 on main cluster (myocp)

**STUCK SCENARIO 2: Operator Stuck (conditions exist but deployments unavailable)**
- CertManager CR exists
- deploymentAvailable conditions exist
- At least one deployment condition != "True"

**Detection**:
```bash
# Check deployment conditions
CONTROLLER_AVAILABLE=$(oc get certmanager cluster -o jsonpath='{.status.conditions[?(@.type=="cert-manager-controller-deploymentAvailable")].status}')
CAINJECTOR_AVAILABLE=$(oc get certmanager cluster -o jsonpath='{.status.conditions[?(@.type=="cert-manager-cainjector-deploymentAvailable")].status}')
WEBHOOK_AVAILABLE=$(oc get certmanager cluster -o jsonpath='{.status.conditions[?(@.type=="cert-manager-webhook-deploymentAvailable")].status}')

# If any != "True" → Delete CertManager CR (operator recreates it)
if [ "$CONTROLLER_AVAILABLE" != "True" ] || [ "$CAINJECTOR_AVAILABLE" != "True" ] || [ "$WEBHOOK_AVAILABLE" != "True" ]; then
  oc delete certmanager cluster
fi
```

**Why this happens**: CM-412 operator bug - operator gets stuck and doesn't reconcile deployments

**Detection criteria**:
- `cert-manager-controller-deploymentAvailable` status
- `cert-manager-cainjector-deploymentAvailable` status
- `cert-manager-webhook-deploymentAvailable` status
- Pod count in cert-manager namespace
- CertManager CR age (for grace period)

**Why Deployment over Job/CronJob**:
- ✅ Immediate detection (<60s vs up to 10 minutes)
- ✅ Continuous monitoring (not scheduled)
- ✅ Automatic recovery from cluster hibernation
- ✅ Minimal overhead (~10m CPU when idle)
- ✅ Better for infrastructure-critical services

**ConfigMap**: `components/cert-manager/base/cert-manager-configmap-scripts.yaml`

**Script extraction benefits**:
- Readable bash syntax (no YAML escaping)
- Easier maintenance and testing
- Reusable across Deployment and Jobs

**Related Bug**: See CM-412 in known-bugs.md for background on operator stuck states.

## OpenShift Data Foundation (ODF)

**Pattern**: Dynamic Job with ConfigMap-driven channel management

**Purpose**: Configure all ODF operator subscriptions to run on infrastructure nodes via nodeSelector.

**Implementation**:

Job: `openshift-storage-job-update-subscriptions-node-selector.yaml`

1. Extracts ODF channel from `cluster-versions` ConfigMap: `data.odf` (e.g., `stable-4.20`)
2. Builds subscription names dynamically: `<package>-<channel>-redhat-operators-openshift-marketplace`
3. Patches 8 ODF subscriptions with nodeSelector: `cluster.ocs.openshift.io/openshift-storage: ""`
4. Handles special case: `odf-dependencies` (no channel suffix in name)

**Subscriptions Patched** (7 standard + 1 special):
- `cephcsi-operator`
- `mcg-operator`
- `ocs-client-operator`
- `ocs-operator`
- `odf-csi-addons-operator`
- `recipe`
- `rook-ceph-operator`
- `odf-dependencies` (special - no channel in name)

**Known Bug - Intentional Exclusions**:

The following 2 subscriptions are **intentionally NOT patched** due to a known ODF bug that prevents proper configuration of tolerations/nodeSelector:
- `odf-external-snapshotter-operator` → runs on worker nodes
- `odf-prometheus-operator` → runs on worker nodes

These operators will continue running on worker nodes until the upstream bug is resolved.

**Upgrade Behavior**:

When upgrading OCP (e.g., 4.20 → 4.21):
1. Update `cluster-versions` ConfigMap: `odf: "stable-4.21"`
2. Job automatically uses new channel
3. No Job modification required → channel-agnostic design

**Why ConfigMap approach**:
- ✅ Consistent with project architecture (centralized version management)
- ✅ Upgrade-proof (no hardcoded channels)
- ✅ Explicit control (list of packages, not wildcard discovery)
- ✅ Documents exceptions clearly (bug workaround)

## OpenShift Pipelines (Tekton)

**TektonConfig Profile Behavior:**

The TektonConfig CR supports three profiles:
- **`lite`**: Installs only Tekton Pipelines
- **`basic`**: Installs Tekton Pipelines, Tekton Triggers, Tekton Chains, and Tekton Results
- **`all`**: Installs all components including TektonAddon (ConsoleCLIDownload, ConsoleQuickStart, etc.)

**Important**: While Red Hat documentation states "all" is the default profile, when managing TektonConfig via GitOps without explicitly specifying the `profile` field, the operator appears to default to `basic` instead. This means:

- ✅ With `profile: basic`: You get core Tekton components but **no** TektonAddon
- ✅ With `profile: all`: You get TektonAddon which includes:
  - ConsoleCLIDownload resources (tkn-cli-serve pod for web console CLI downloads)
  - ConsoleQuickStart resources
  - ConsoleYAMLSample resources

**TektonConfig Configuration:**

The project explicitly configures both `profile` and `targetNamespace`:

```yaml
# components/openshift-pipelines/base/cluster-tektonconfig-config.yaml
apiVersion: operator.tekton.dev/v1alpha1
kind: TektonConfig
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    argocd.argoproj.io/sync-wave: "2"  # Deploy AFTER cleanup Job
  name: config
spec:
  profile: all                        # Full Tekton components with console integration
  targetNamespace: openshift-pipelines  # Deploy components to standard OpenShift namespace
```

**Why explicit configuration:**
- `profile: all` ensures TektonAddon is installed (console CLI downloads, quick starts, YAML samples)
- `targetNamespace: openshift-pipelines` uses the standard OpenShift namespace (operator default is `tekton-pipelines`)
- Both fields are managed by GitOps (no ignoreDifferences)

**Version Note**: In OpenShift Pipelines 1.20+, the `basic` profile was enhanced to include Tekton Results (previously only in `all` profile).

### TektonConfig Race Condition and Sync-Wave Solution

**Problem**: Tekton operator auto-creates TektonConfig immediately after Subscription installation with default `targetNamespace: tekton-pipelines`. When ArgoCD tries to apply our manifest with `targetNamespace: openshift-pipelines`, the admission webhook blocks the change with error: `"Doesn't allow to update targetNamespace, delete existing TektonConfig and create the updated TektonConfig"`.

**Root Cause**: Race condition between operator auto-creation and ArgoCD sync. The webhook requires delete+recreate to change targetNamespace, but operator recreates faster than ArgoCD can sync.

**Solution**: Sync-wave orchestration with cleanup Job

```yaml
# Wave 0: Subscription (operator installs)
# components/openshift-pipelines/base/openshift-operators-subscription-openshift-pipelines-operator.yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"

# Wave 1: Cleanup Job (deletes auto-created TektonConfig if wrong targetNamespace)
# components/openshift-pipelines/base/openshift-gitops-job-cleanup-auto-tektonconfig.yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  template:
    spec:
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          # Wait for operator to be ready
          sleep 10
          
          if oc get tektonconfig config &>/dev/null; then
            CURRENT_NS=$(oc get tektonconfig config -o jsonpath='{.spec.targetNamespace}')
            
            if [[ "$CURRENT_NS" != "openshift-pipelines" ]]; then
              echo "TektonConfig has wrong targetNamespace, deleting..."
              oc patch tektonconfig config --type json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
              oc delete tektonconfig config --wait=false
              
              # Wait for deletion (max 60s)
              for i in {1..30}; do
                if ! oc get tektonconfig config &>/dev/null; then
                  echo "TektonConfig deleted successfully"
                  exit 0
                fi
                sleep 2
              done
            fi
          fi

# Wave 2: TektonConfig (ArgoCD creates with correct targetNamespace)
# Sync-wave annotation shown above
```

**How it works:**
1. **Wave 0**: Subscription deploys, operator installs and auto-creates TektonConfig
2. **Wave 1**: Cleanup Job runs, checks targetNamespace, deletes if wrong, removes finalizer to force deletion
3. **Wave 2**: ArgoCD creates TektonConfig with correct `targetNamespace: openshift-pipelines`

**Job idempotency:**
- Job checks current targetNamespace before deleting
- If already correct (`openshift-pipelines`), skips deletion (no-op)
- Prevents unnecessary churn on subsequent syncs
- **Regular Job pattern**: Uses `Force=true` annotation (not a hook) to enable Job recreation on sync
- **No TTL**: `ttlSecondsAfterFinished` removed to prevent 5-minute partial sync cycles (fixed in d337add)

**Why regular Job (not hook):**
- Avoids PostSync deadlock risk if Job waits indefinitely
- ArgoCD sync completes immediately, Job runs independently
- Application shows "Synced + Progressing" until Job completes
- See `docs/claude/troubleshooting.md` "Partial Sync Cycles" for TTL anti-pattern details

## OpenShift Builds (Shipwright)

**Purpose**: Extends Kubernetes with a framework for building container images from source code using various build strategies (Buildpacks, Buildah, Kaniko, ko).

**Namespace**: `openshift-builds`

**Configuration**:

The OpenShiftBuild cluster CR is managed declaratively via GitOps:

```yaml
# components/openshift-builds/base/cluster-openshiftbuild-cluster.yaml
apiVersion: operator.openshift.io/v1alpha1
kind: OpenShiftBuild
metadata:
  name: cluster
spec:
  sharedResource:
    state: Enabled  # SharedResource CSI driver for sharing Secrets/ConfigMaps across namespaces
  shipwright:
    build:
      state: Enabled  # Core Shipwright build functionality
```

**SharedResource CSI Driver**:

The SharedResource CSI driver allows Secrets and ConfigMaps to be shared across namespaces for build operations. Previously disabled due to deployment issues (`KubeDeploymentReplicasMismatch` alerts from failed ReplicaSet creation), this feature is now enabled as the underlying bug appears to have been resolved in recent operator versions.

**Deployment**:

OpenShift Builds and OpenShift Pipelines are deployed together via their respective ApplicationSets:
- `openshift-builds` → core ApplicationSet
- `openshift-pipelines` → devops ApplicationSet

Both operators can be installed simultaneously without ordering dependencies. The OpenShift Builds operator will wait for Tekton components to be ready during its reconciliation loop.

**RBAC**:

The component includes a ClusterRole for managing OpenShiftBuild cluster-scoped CRs:
- `cluster-clusterrole-manage-openshiftbuilds.yaml`
- `cluster-crb-manage-openshiftbuilds-gitops.yaml`

**Enabled Features**:
- ✅ Shipwright builds (core build strategies)
- ✅ SharedResource CSI driver (cross-namespace Secret/ConfigMap sharing)

## AWS Controllers for Kubernetes (ACK) - Route53

**Purpose**: Enables Kubernetes-native management of AWS Route53 resources (HostedZones, RecordSets, HealthChecks) via custom resources.

**Configuration Approach**:

The ACK Route53 operator requires specific ConfigMap and Secret resources to function. Rather than hardcoding AWS credentials and region, we use a **dynamic configuration injection Job** that:

1. **Runs in `openshift-gitops` namespace** with the `openshift-gitops-argocd-application-controller` ServiceAccount
2. **Waits for** the cluster's `aws-creds` Secret in `kube-system` (created during installation)
3. **Extracts** AWS credentials and region from cluster resources:
   - AWS credentials from `kube-system/aws-creds` Secret
   - AWS region from Infrastructure CR (`infrastructure.config.openshift.io/cluster`)
4. **Creates** in `ack-system` namespace:
   - `ack-route53-user-secrets` Secret (AWS credentials)
   - `ack-route53-user-config` ConfigMap (all required environment variables)

**Required ConfigMap Variables**:
The operator deployment expects these environment variables from the ConfigMap:
- `AWS_REGION` - AWS region (from Infrastructure CR)
- `AWS_ENDPOINT_URL` - Custom AWS endpoint (usually empty)
- `ACK_ENABLE_DEVELOPMENT_LOGGING` - Enable debug logging
- `ACK_LOG_LEVEL` - Log verbosity level
- `ACK_RESOURCE_TAGS` - Default tags applied to AWS resources
- `ACK_WATCH_NAMESPACE` - Limit to specific namespace (empty = all)
- `ENABLE_CARM` - Cross Account Resource Management (false by default)
- `ENABLE_LEADER_ELECTION` - High availability mode
- `FEATURE_GATES` - Feature flag configuration (empty = none)
- `LEADER_ELECTION_NAMESPACE` - Namespace for leader election
- `RECONCILE_DEFAULT_MAX_CONCURRENT_SYNCS` - Reconciliation concurrency

**Important**: Missing any of these variables will cause the controller to crash with parsing errors like `invalid argument "$(VARIABLE_NAME)"`.

**Installation**: ACK Route53 is part of the `core` gitops-base and is automatically deployed in all profiles.

## Cluster Observability Operator

**Purpose**: Provides unified observability UI plugins for OpenShift Console, integrating monitoring and logging insights directly in the console.

**Installation**: Deployed in dedicated `openshift-observability-operator` namespace with AllNamespaces OperatorGroup.

**Namespace**: `openshift-observability-operator`

**IMPORTANT - Required Label:**

The namespace **must** have the `openshift.io/cluster-monitoring: "true"` label per Red Hat documentation:

```yaml
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: openshift-observability-operator
```

**Why this label is required:**
- Routes ServiceMonitor resources to cluster monitoring (not user-workload monitoring)
- Without it, user-workload Prometheus tries to scrape the health-analyzer ServiceMonitor
- The health-analyzer ServiceMonitor uses deprecated TLS file path syntax (operator-generated)
- User-workload Prometheus Operator rejects it, causing PrometheusOperatorRejectedResources alert
- Cluster monitoring handles the ServiceMonitor correctly

**OperatorGroup**: `observability-operator`
- Empty spec (no `spec:` section) → **AllNamespaces mode**
- Operator watches all namespaces cluster-wide
- Allows UIPlugin resources to be created at cluster scope

**UI Plugins**:

The component deploys two UIPlugin custom resources:

1. **Logging UIPlugin** (`cluster-uiplugin-logging.yaml`)
   - Type: Logging
   - Integrates with LokiStack: `logging-loki`
   - Logs limit: 50
   - Timeout: 30s

2. **Monitoring UIPlugin** (`cluster-uiplugin-monitoring.yaml`)
   - Type: Monitoring
   - Cluster Health Analyzer: enabled
   - Provides cluster health insights in console
   - Creates additional `health-analyzer` deployment when enabled

Both UIPlugins:
- Use `SkipDryRunOnMissingResource=true` (CRD installed by operator)
- Deploy on infra nodes (nodeSelector + tolerations)

**Deployments Created:**
- `observability-operator` - Main operator controller
- `monitoring` - Monitoring console plugin frontend
- `logging` - Logging console plugin frontend
- `health-analyzer` - Backend health analysis (created by monitoring UIPlugin)
- `perses-operator` - Perses dashboard operator
- `obo-prometheus-operator` - Prometheus operator for custom MonitoringStack CRs
- `obo-prometheus-operator-admission-webhook` - Webhook for Prometheus resources

**Installation**: Part of the `core` gitops-base, automatically deployed in all profiles.

## Loki Operator

**Purpose**: Provides log aggregation storage backend for OpenShift Logging, enabling scalable log collection and querying via LokiStack.

**Installation**: Deployed in `openshift-operators-redhat` namespace. Available via `gitops-bases/logging/*` profiles.

**Namespace**: `openshift-operators-redhat`

**TEMPORARY-FIX: ServiceAccount Token Secret**

The component includes a workaround for a known Kubernetes 1.24+ limitation:

**File**: `components/loki/base/TEMPORARY-FIX-openshift-operators-redhat-secret-loki-operator-controller-manager-metrics-token.yaml`

**Issue:**
- **Root Cause**: Kubernetes 1.24+ (OpenShift 4.11+) stopped auto-generating ServiceAccount token secrets
- **Impact**: Loki operator's ServiceMonitor cannot scrape metrics without a manually created token secret
- **Upstream Issue**: [LOG-5240](https://issues.redhat.com/browse/LOG-5240)

**Workaround:**
Manually create a ServiceAccount token secret for the `loki-operator-controller-manager-metrics-reader` ServiceAccount:

```yaml
apiVersion: v1
kind: Secret
metadata:
  annotations:
    kubernetes.io/service-account.name: loki-operator-controller-manager-metrics-reader
  name: loki-operator-controller-manager-metrics-token
  namespace: openshift-operators-redhat
type: kubernetes.io/service-account-token
```

**Why needed:**
- The Loki operator creates a ServiceMonitor that references this token for Prometheus authentication
- Without the token secret, Prometheus cannot scrape the operator's metrics endpoint
- The token is bound to the ServiceAccount and automatically populated by Kubernetes

**Removal Criteria:**
This workaround can be removed when:
- The Loki operator automatically creates its own token secret, OR
- The operator's ServiceMonitor is updated to use a different authentication method

**Related Documentation:**
- [Red Hat Solution 7087666](https://access.redhat.com/solutions/7087666) - ServiceAccount token secrets in OpenShift 4.11+
- [Red Hat Solution 7065483](https://access.redhat.com/solutions/7065483) - Manual token secret creation

## Red Hat Advanced Cluster Management (RHACM)

**Purpose**: Multi-cluster management platform for Kubernetes/OpenShift clusters, providing cluster lifecycle, policy governance, application delivery, and search capabilities.

**Installation**: Deployed in `open-cluster-management` namespace. Available in hub profiles via `gitops-bases/acm/hub`.

**Namespace**: `open-cluster-management`

**RBAC Pattern: Namespace Label + Explicit Search RBAC**

ArgoCD can manage most ACM resources via the namespace label, but Search resources require explicit RBAC:

```yaml
# components/rhacm/overlays/hub/cluster-namespace-open-cluster-management.yaml
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops
```

**How the namespace label works:**
- OpenShift GitOps operator automatically creates Role/RoleBinding in labeled namespaces
- Auto-generated Role grants **read** permissions (`get, list, watch`) for ALL resources (`apiGroups: ['*']`)
- Auto-generated Role grants **write** permissions for specific operator resources (apps.open-cluster-management.io, cluster.open-cluster-management.io, etc.)
- ArgoCD can manage most namespace-scoped ACM resources without additional RBAC

**Search Resource Exception:**

The `searches.search.open-cluster-management.io` resource is NOT included in the auto-generated Role's write permissions. Explicit RBAC is required:

```yaml
# components/rhacm/overlays/hub/open-cluster-management-role-search-edit.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: search-edit
  namespace: open-cluster-management
rules:
- apiGroups: [search.open-cluster-management.io]
  resources: [searches]
  verbs: ['*']
```

```yaml
# components/rhacm/overlays/hub/open-cluster-management-rb-search-edit.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: search-edit
  namespace: open-cluster-management
roleRef:
  kind: Role
  name: search-edit
subjects:
- kind: ServiceAccount
  name: openshift-gitops-argocd-application-controller
  namespace: openshift-gitops
```

**Why explicit RBAC is needed:**
- Search is a namespaced custom resource
- Auto-generated Role only grants read permissions for CRDs not explicitly listed
- Without explicit Role, ArgoCD cannot patch/update Search resources
- Error: `cannot patch resource "searches" in API group "search.open-cluster-management.io" in the namespace "open-cluster-management"`

### Search Persistent Storage Configuration

**Pattern**: Direct CR management with namespace-level RBAC

ACM Search requires persistent storage for production use to prevent data loss and avoid continuous re-indexing:

```yaml
# components/rhacm/overlays/hub/open-cluster-management-search-search-v2-operator.yaml
apiVersion: search.open-cluster-management.io/v1alpha1
kind: Search
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  name: search-v2-operator
  namespace: open-cluster-management
spec:
  dbStorage:
    size: 10Gi
    storageClassName: gp3-csi  # AWS EBS gp3 storage
  deployments:
    collector: {}
    database: {}
    indexer: {}
    queryapi: {}
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
  - key: node-role.kubernetes.io/infra
    operator: Exists
```

**Storage Behavior:**

When Search CR is created/updated with `storageClassName`:
1. ACM operator creates PVC: `gp3-csi-search` (10Gi, RWO)
2. PVC enters Pending state (WaitForFirstConsumer - gp3-csi uses volumeBindingMode: WaitForFirstConsumer)
3. search-postgres Deployment updated to mount PVC at `/var/lib/pgsql/data`
4. Old search-postgres pod terminates
5. New search-postgres pod scheduled → PVC binds to volume → pod starts with persistent storage

**PVC Persistence:**
- PVC survives Search CR deletion/recreation
- Same volume reattaches to new postgres pod
- Data preserved across operator upgrades and pod restarts

**SearchPVCNotPresentCritical Alert:**

**Alert fires when BOTH conditions met:**
1. No PVC exists for search (no `*-search` PVC in open-cluster-management namespace)
2. **AND** one of these high-load/crash conditions:
   - Managing >10 clusters
   - >100 combined Subscriptions + ApplicationSets
   - search-postgres OOMKilled
   - search-indexer OOMKilled
   - >100 indexer requests in 30m

**Why it matters:**
- Without PVC: Search runs in ephemeral mode (data in pod's emptyDir)
- Pod restart = complete data loss
- Requires full re-indexing of all cluster resources
- Performance impact during re-indexing

**Resolution:**
Add `spec.dbStorage.storageClassName` to Search CR (as shown above).

**MultiClusterHub Configuration:**

```yaml
# components/rhacm/overlays/hub/open-cluster-management-multiclusterhub-multiclusterhub.yaml
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec:
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
  - key: node-role.kubernetes.io/infra
    operator: Exists
```

Deploys all ACM hub components (multicluster-engine, console, governance, observability, etc.) on infrastructure nodes.

**Version Management:**

Operator channel managed via `cluster-versions` ConfigMap:
- `rhacm: "release-2.16"` (ConfigMap)

**Installation**: Part of the `acm/hub` gitops-base, deployed in profile: `ocp-reference`, `ocp-acm-hub`

### ClusterManagementAddon API Version Migration

**Pattern**: Use v1beta1 API with defaultConfigs field (not v1alpha1 with supportedConfigs)

**CRITICAL**: ClusterManagementAddon resources MUST use `addon.open-cluster-management.io/v1beta1` API version to prevent partial sync cycles.

**Problem**: ACM operator converts v1alpha1 manifests to v1beta1 at runtime and renames the `supportedConfigs` field to `defaultConfigs`. This causes ArgoCD to detect continuous drift:

```yaml
# ❌ OLD (v1alpha1) - Causes partial sync cycles
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ClusterManagementAddon
spec:
  supportedConfigs:
    - defaultConfig:
        name: deploy-config
        namespace: open-cluster-management-hub
      group: addon.open-cluster-management.io
      resource: addondeploymentconfigs
```

```yaml
# ✅ NEW (v1beta1) - Matches operator state
apiVersion: addon.open-cluster-management.io/v1beta1
kind: ClusterManagementAddon
spec:
  defaultConfigs:
    - group: addon.open-cluster-management.io
      name: deploy-config
      namespace: open-cluster-management-hub
      resource: addondeploymentconfigs
```

**Key differences**:
- API version: `v1alpha1` → `v1beta1`
- Field name: `supportedConfigs` → `defaultConfigs`
- Field structure: No nested `defaultConfig` object in v1beta1

**Why this matters**:
- v1alpha1 manifests work initially (operator converts them)
- But ArgoCD compares desired (v1alpha1) vs actual (v1beta1) → detects drift
- Result: "Partial sync operation succeeded" every 5-6 minutes
- Fix: Use v1beta1 directly in manifests to match operator state

**Affected resources** (8 ClusterManagementAddons in hub overlay):
- application-manager
- cert-policy-controller
- cluster-proxy
- config-policy-controller
- governance-policy-framework
- managed-serviceaccount
- search-collector
- work-manager

**Historical context**: ACM deprecated v1alpha1 API in favor of v1beta1 (2.16+). Always use latest stable API version for operator CRDs.

### Operator-Managed Fields and ignoreDifferences

**Pattern**: Ignore operator-managed `spec` fields to prevent auto-heal cycles

**CRITICAL**: ACM operator dynamically manages `spec.defaultConfigs` and `spec.installStrategy` fields on ClusterManagementAddon resources. Static manifests CANNOT match operator's dynamic state.

**Problem**: Auto-heal cycles every 4-8 minutes caused by operator-managed fields

The ACM operator enriches ClusterManagementAddon resources with runtime configuration:

**1. spec.installStrategy** - Operator determines deployment strategy:
```yaml
# Our manifest: Field not declared
spec:
  defaultConfigs: [...]

# Cluster state: Operator adds installStrategy
spec:
  defaultConfigs: [...]
  installStrategy:
    type: Placements  # or Manual, determined by operator
    placements:
      - name: global
        namespace: open-cluster-management-global-set
```

**2. spec.defaultConfigs** - Operator adds addon-specific entries:
```yaml
# Our manifest: Minimal baseline
spec:
  defaultConfigs:
    - group: addon.open-cluster-management.io
      name: deploy-config
      namespace: open-cluster-management-hub
      resource: addondeploymentconfigs

# Cluster state: Operator adds extra entries
spec:
  defaultConfigs:
    - group: proxy.open-cluster-management.io      # ← ADDED by operator
      name: cluster-proxy
      resource: managedproxyconfigurations
    - group: addon.open-cluster-management.io
      name: deploy-config
      namespace: open-cluster-management-hub
      resource: addondeploymentconfigs
```

**3. Version updates** - Operator updates addon versions:
```yaml
# Our manifest: May have old version
spec:
  defaultConfigs:
    - name: managed-serviceaccount-2.10  # Old version

# Cluster state: Operator updates to current version
spec:
  defaultConfigs:
    - name: managed-serviceaccount-2.11  # Updated by operator
```

**Without ignoreDifferences**:
1. ArgoCD compares static manifest vs dynamic operator state
2. Detects drift in `spec.defaultConfigs` and/or `spec.installStrategy`
3. Auto-heal triggers sync to restore manifest state
4. Operator immediately re-adds its managed fields
5. ArgoCD detects drift again → continuous cycle every 4-8 minutes

**Solution**: Ignore both operator-managed fields in ApplicationSet:

```yaml
# gitops-bases/acm/hub/applicationset.yaml
spec:
  template:
    spec:
      ignoreDifferences:
      - group: addon.open-cluster-management.io
        kind: ClusterManagementAddOn
        jsonPointers:
        - /spec/defaultConfigs      # Operator adds/updates entries
        - /spec/installStrategy     # Operator manages deployment strategy
```

**Why both fields are required**:
- Ignoring only `/spec/installStrategy` is INSUFFICIENT (attempted in 80da465, failed)
- Both fields are actively managed by operator based on:
  - ACM version and addon versions
  - Addon-specific configuration requirements
  - Managed cluster enrollment state

**Result**:
- ✅ No more auto-heal cycles
- ✅ Operator continues managing fields as designed
- ✅ Our manifests provide minimal baseline, operator enriches with runtime config

**Affected resources** (auto-heal previously targeting these):
- `cluster-proxy` - Extra defaultConfigs entry + installStrategy
- `managed-serviceaccount` - Version updates in defaultConfigs + installStrategy
- `work-manager` - installStrategy placements

**Pattern type**: Shared Resources with ignoreDifferences (operator co-manages resources we declare)

**Historical fixes**:
- d931ec8: Fixed API version mismatch (v1alpha1 → v1beta1)
- 80da465: Added ignoreDifferences for /spec/installStrategy (insufficient)
- dd38d0e: Added /spec/defaultConfigs to ignoreDifferences (complete fix)

## Red Hat build of Apicurio Registry

**Purpose**: Provides a schema registry for API and event schema management, supporting Avro, Protobuf, JSON Schema, OpenAPI, and AsyncAPI formats.

**Installation**: Deployed in dedicated `rhb-apicurio-registry-operator` namespace. Available in devops profiles via `gitops-bases/devops/ai`.

**Namespace**: `rhb-apicurio-registry-operator`

**OperatorGroup Configuration:**

The component uses **AllNamespaces mode** to allow ApicurioRegistry instances to be created in any namespace:

```yaml
# components/rhb-apicurio-registry-operator/overlays/ai/rhb-apicurio-registry-operator-operatorgroup-rhb-apicurio-registry-operator.yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhb-apicurio-registry-operator
  namespace: rhb-apicurio-registry-operator
# No spec section → AllNamespaces mode
```

**AllNamespaces Mode Behavior:**

When `spec.targetNamespaces` is omitted entirely:
- `status.namespaces` contains empty string `[""]`
- Operator watches **all namespaces** cluster-wide
- OLM creates **ClusterRole** and **ClusterRoleBinding** (not namespace-scoped RBAC)
- ApicurioRegistry3 instances can be created in any namespace
- Operator logs confirm: `"Watching all namespaces."`

**Why AllNamespaces mode:**
- Allows application teams to deploy schema registries in their own namespaces
- Eliminates need for cluster-admin intervention per namespace
- Simplifies multi-tenant schema registry deployments
- Operator still runs in dedicated namespace but watches cluster-wide

**Alternative: SingleNamespace Mode**

For restricted deployments, use SingleNamespace mode:

```yaml
spec:
  targetNamespaces:
  - rhb-apicurio-registry-operator  # Only watch this namespace
```

**Supported Install Modes:**

The operator supports all OLM install modes:
- ✅ OwnNamespace
- ✅ SingleNamespace
- ✅ MultiNamespace
- ✅ AllNamespaces

**Version Management:**

Operator channel managed via `cluster-versions` ConfigMap:
- `rhbar: "3.x"` (ConfigMap)

**Installation**: Part of the `devops/ai` gitops-base, deployed in profiles with integration/DevOps capabilities.

## Red Hat Connectivity Link (RHCL) - Kuadrant

**Purpose**: Provides API gateway capabilities including rate limiting, authentication, DNS management, and TLS policies through the Kuadrant operator stack.

**Installation**: Deployed in `kuadrant-system` namespace. Available in select profiles via `gitops-bases/rh-connectivity-link/default`.

**Namespace**: `kuadrant-system`

**OperatorGroup**: `rhcl`
- Empty spec (no `spec:` section) → **AllNamespaces mode**
- Allows Kuadrant CRDs to be used cluster-wide

**Operator Stack (4 operators):**

The RHCL component manages 4 operator subscriptions with infrastructure node placement:

1. **RHCL Operator** (`rhcl-operator`)
   - Main Kuadrant operator
   - Creates Kuadrant CR and manages operator lifecycle

2. **Authorino Operator** (`authorino-operator`)
   - API authentication and authorization engine
   - Installed as dependency of Kuadrant

3. **DNS Operator** (`dns-operator`)
   - Multi-cluster DNS management
   - Installed as dependency of Kuadrant

4. **Limitador Operator** (`limitador-operator`)
   - Rate limiting engine
   - Installed as dependency of Kuadrant

**OLM-Generated Subscription Names:**

Dependency operators use OLM-generated subscription names following the pattern:
```
{package}-{channel}-{source}-{sourceNamespace}
```

Examples:
- `authorino-operator-stable-redhat-operators-openshift-marketplace`
- `dns-operator-stable-redhat-operators-openshift-marketplace`
- `limitador-operator-stable-redhat-operators-openshift-marketplace`

**Why these names?** When operators are installed via OLM dependency resolution (rather than direct manifest application), OLM generates subscription names automatically. The manifests use these generated names to match existing cluster state and enable GitOps management of dependencies.

**Infrastructure Node Placement:**

All 4 operator subscriptions are configured with infrastructure node placement:

```yaml
spec:
  config:
    nodeSelector:
      node-role.kubernetes.io/infra: ""
    tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
```

This ensures operator control plane workloads run on infrastructure nodes, separating them from user workloads.

**Kuadrant CR:**

The component creates a `Kuadrant` custom resource that automatically provisions:
- **Authorino** instance (authentication engine)
- **Limitador** instance (rate limiting engine)

**Known Limitations:**

1. **Operator Instance Pods** - Authorino and Limitador instances run on **worker nodes**:
   - No API exists in Kuadrant CR to configure nodeSelector/tolerations for instances
   - Only operator subscriptions support infra node placement
   - Accepted limitation for demo/lab environments

2. **Console Plugin** - `kuadrant-console-plugin` deployment runs on **worker nodes**:
   - No configuration option in operator to set nodeSelector/tolerations
   - Plugin is auto-created by RHCL operator
   - Accepted limitation for demo/lab environments
   - JIRA ticket created for upstream feature request

**Result:**
- ✅ All 4 **operator pods** run on infrastructure nodes
- ⚠️ **Instance pods** (authorino, limitador) run on worker nodes (accepted)
- ⚠️ **Console plugin** runs on worker nodes (accepted)

**Console Plugin:**

The component includes a Job to enable the `kuadrant-console-plugin` in OpenShift Console:
- Job: `openshift-gitops-job-enable-kuadrant-console-plugin.yaml`
- Idempotent patch that adds plugin if not already present
- Uses `Force=true` to run on every ArgoCD sync

**Version Management:**

Operator channels are managed via `cluster-versions` ConfigMap:
- `rhcl-operator: stable`
- `authorino-operator: stable`
- `dns-operator: stable`
- `limitador-operator: stable`

Kustomize replacements automatically inject channel versions during build.

**Observability Configuration:**

The RHCL component includes comprehensive observability for Gateway API and Kuadrant resources, following upstream Kuadrant v1.2.0 configuration with OpenShift adaptations.

1. **Kuadrant Observability Enabled:**
   ```yaml
   # components/rh-connectivity-link/base/kuadrant-system-kuadrant-kuadrant.yaml
   spec:
     observability:
       enable: true
   ```

   **Auto-creates 5 ServiceMonitors in `kuadrant-system` namespace**:
   - `authorino-operator-monitor` - Authorino operator metrics
   - `dns-operator-monitor` - DNS operator metrics
   - `kuadrant-authorino-monitor` - Authorino instance metrics
   - `kuadrant-operator-monitor` - Kuadrant operator metrics
   - `limitador-operator-monitor` - Limitador operator metrics

2. **kube-state-metrics for Gateway API:**

   Deployed in `monitoring` namespace (without cluster-monitoring label - uses user-workload Prometheus):

   - **CustomResourceStateMetrics ConfigMap**: Defines metrics for 14 resource types
     - **Gateway API** (8): Gateway, GatewayClass, HTTPRoute, GRPCRoute, TCPRoute, TLSRoute, UDPRoute, BackendTLSPolicy
     - **Kuadrant Policies** (4): RateLimitPolicy, AuthPolicy, DNSPolicy, TLSPolicy
     - **Kuadrant DNS** (2): DNSRecord, DNSHealthCheckProbe
     - **Source**: `gateway-api-state-metrics` v0.7.0
     - **API Versions**: Uses v1 for all Kuadrant policies (matches deployed CRDs)

   - **Deployment**: `kube-state-metrics-kuadrant`
     - Image: `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.9.2`
     - Resources: 10m/100m CPU, 190Mi/250Mi memory
     - Ports: 8081 (main metrics), 8082 (self metrics)

   - **RBAC**: ClusterRole with list/watch permissions for Gateway API and Kuadrant CRDs

   - **ServiceMonitor**: Scraped by user-workload Prometheus (30s interval)
     - Label drop: Removes pod/service/endpoint/namespace labels from metrics
     - Two endpoints: main metrics + self metrics

3. **Istio Observability:**

   Enhanced metrics for service mesh traffic in `openshift-ingress` namespace:

   - **Telemetry CR**: Adds custom tags to REQUEST_COUNT and REQUEST_DURATION metrics
     ```yaml
     tagOverrides:
       destination_port: "string(destination.port)"
       request_host: "request.host"
       request_url_path: "request.url_path"
     ```

   - **ServiceMonitor**: Scrapes istiod control plane metrics
     - Port: http-monitoring
     - Namespace: openshift-ingress (OpenShift OSSM location, not upstream's gateway-system)

4. **Grafana Observability Stack:**

   Complete Grafana deployment in `monitoring` namespace with OpenShift OAuth integration:

   - **Grafana Instance**: Full OAuth proxy integration for OpenShift authentication
     - Label: `dashboards: grafana` (for instance selection)
     - Managed by Grafana Operator (already deployed in core ApplicationSet)
     - **OAuth Proxy Sidecar**: `origin-oauth-proxy:latest` container
       - Provider: OpenShift OAuth (`-provider=openshift`)
       - Authentication: Header-based via `X-Forwarded-User`
       - HTTPS port: 9091 (external access)
       - Upstream: `http://localhost:3000` (Grafana container)
     - **Route**: Auto-created with TLS reencrypt termination
       - Name: `grafana-route`
       - Service: `grafana-service:443` (oauth-proxy port)
     - **ServiceAccount OAuth**: `grafana-sa` with redirect reference
       - Annotation: `serviceaccounts.openshift.io/oauth-redirectreference.primary`
     - **Auth Proxy Config**:
       - `auth.proxy.enabled: true` - Enable proxy authentication
       - `auth.proxy.auto_login: true` - Auto-login OAuth users
       - `users.auto_assign_org_role: Admin` - Grant admin permissions
     - **RBAC for OAuth Proxy**:
       - ClusterRole: `grafana-oauth-proxy` (tokenreviews, subjectaccessreviews)
       - ClusterRoleBinding: `grafana-oauth-proxy` → `grafana-sa`
     - **Supporting Resources**:
       - Secret: `grafana-proxy` (session secret for cookie encryption)
       - ConfigMap: `ocp-injected-certs` (auto-injected OpenShift CA bundle)
       - Secret: `grafana-tls` (auto-generated by service-ca)

   - **GrafanaDatasource**: Thanos Querier connection
     - Type: prometheus (default datasource)
     - Access: proxy (Grafana server proxies requests)
     - URL: `https://thanos-querier.openshift-monitoring.svc:9091` (internal service)
     - Auth: Bearer token from ServiceAccount
     - Job configures bearer token dynamically at deployment

   - **ServiceAccount**: `grafana-datasource` with `cluster-monitoring-view` ClusterRole
     - Allows Grafana to query Prometheus/Thanos
     - **Token Secret**: Explicit Secret with `kubernetes.io/service-account-token` type
       - Required in OpenShift 4.11+ (ServiceAccount tokens no longer auto-created)
       - Secret: `monitoring-secret-grafana-datasource-token.yaml`
       - Annotation: `kubernetes.io/service-account.name: grafana-datasource`

   - **10 GrafanaDashboard CRs**: Complete observability for Kuadrant + Istio

     **Kuadrant Dashboards** (from Kuadrant v1.3.0):
     - `platform-engineer` - Platform engineer focused metrics (72KB JSON)
     - `business-user` - Business user analytics (23KB JSON)
     - `controller-resources-metrics` - Controller resource utilization (8KB JSON)
     - `controller-runtime-metrics` - Controller runtime performance (20KB JSON)
     - `app-developer` - Application development metrics (46KB JSON)
     - `dns-operator` - DNS operator monitoring (23KB JSON)
     - Source: https://github.com/Kuadrant/kuadrant-operator/tree/v1.3.0/examples/dashboards

     **Istio Dashboards** (official upstream from Istio project):
     - `istio-mesh` - Service mesh overview (23KB JSON)
     - `istio-service` - Per-service traffic metrics (114KB JSON)
     - `istio-workload` - Per-workload detailed metrics (105KB JSON)
     - `istio-performance` - Istio control plane resource usage (40KB JSON)
     - Source: https://github.com/istio/istio/tree/master/manifests/addons/dashboards
     - **No Kiali required**: Uses standard Istio metrics from ServiceMonitor

   - **ConfigMapGenerator**: Creates ConfigMaps from dashboard JSON files
     - Total: 474KB of dashboard definitions (192KB Kuadrant + 282KB Istio)

   - **Configuration Job**: `configure-grafana-datasource-token` (PostSync wave 3)
     - Uses hardcoded internal Thanos Querier service URL
     - Waits for ServiceAccount token Secret to be created
     - Patches GrafanaDatasource with bearer token
     - Uses oc CLI (no jq dependency required)

**Metrics Flow:**
- kube-state-metrics → exports Gateway API/Kuadrant policy state metrics
- User-workload Prometheus → scrapes kube-state-metrics ServiceMonitor
- Istio control plane → exports enhanced request metrics via istiod
- Platform Prometheus → scrapes istiod ServiceMonitor
- Grafana → queries Thanos Querier (aggregates platform + user-workload Prometheus)

**Important Notes:**
- `monitoring` namespace does NOT have `openshift.io/cluster-monitoring: "true"` label
- RHCL is user-installed, so uses user-workload Prometheus (not platform Prometheus)
- Platform Prometheus scrapes namespaces WITH the label; user-workload scrapes WITHOUT
- Operator ServiceMonitors are auto-created by Kuadrant CR (not static manifests)
- GrafanaDatasource uses internal Thanos Querier service URL for better performance and security
- Grafana accessible via OpenShift OAuth - all authenticated users get Admin role by default

**Known Issue - API Version Fix Applied:**

The upstream `gateway-api-state-metrics` v0.7.0 expects Kuadrant v1 APIs, which RHCL 1.3 now deploys. Our implementation correctly uses v1 API versions for all Kuadrant policies (RateLimitPolicy, AuthPolicy, DNSPolicy, TLSPolicy), ensuring kube-state-metrics can collect policy metrics. Earlier versions used incorrect API versions (v1beta2/v1beta3/v1alpha1) which prevented metrics collection.

**Installation**: Part of the `rh-connectivity-link` gitops-base, included in profiles with API gateway capabilities.

## Red Hat OpenShift AI (RHOAI)

**Purpose**: Enterprise AI/ML platform providing model development, training, serving, and monitoring capabilities.

**Installation**: Deployed in `redhat-ods-operator` and `redhat-ods-applications` namespaces. Included in AI-focused profiles.

**Namespace**: `redhat-ods-operator` (operator), `redhat-ods-applications` (applications)

**Key Components:**

### DataScienceCluster Configuration

The DataScienceCluster CR controls which RHOAI components are enabled:

```yaml
# components/rhoai/base/cluster-datasciencecluster-default-dsc.yaml
spec:
  components:
    kserve:
      managementState: Managed
      modelsAsService:
        managementState: Managed  # Enables MaaS API for model serving
    kueue:
      managementState: Unmanaged  # Cluster-wide Kueue managed separately
    # ... other components
```

**Models as a Service (MaaS):**
- Enabled via `kserve.modelsAsService.managementState: Managed`
- Deploys `maas-api` pod in `redhat-ods-applications`
- Creates `tier-to-group-mapping` ConfigMap with tier definitions (Free, Premium, Enterprise)

### OdhDashboardConfig Management

**Pattern**: Direct CR management with ArgoCD ignoreDifferences (not Jobs)

The OdhDashboardConfig CR is **managed directly** by ArgoCD instead of using a patch Job:

```yaml
# components/rhoai/base/redhat-ods-applications-odhdashboardconfig-odh-dashboard-config.yaml
apiVersion: opendatahub.io/v1alpha
kind: OdhDashboardConfig
metadata:
  name: odh-dashboard-config
  namespace: redhat-ods-applications
spec:
  dashboardConfig:
    disableTracking: false
    genAiStudio: true       # Enables GenAI Studio UI
    modelAsService: true    # Enables MaaS UI
  notebookController:
    enabled: true
    notebookNamespace: rhods-notebooks
    pvcSize: 20Gi
```

**RBAC for Custom Resources:**

ArgoCD requires explicit RBAC to manage RHOAI custom resources:

```yaml
# ClusterRole for OdhDashboardConfig management
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: odhdashboardconfigs.opendatahub.io-v1alpha-edit
rules:
  - apiGroups: [opendatahub.io]
    resources: [odhdashboardconfigs]
    verbs: [get, list, watch, create, update, patch, delete]

# ClusterRoleBinding to ArgoCD ServiceAccount
subjects:
  - kind: ServiceAccount
    name: openshift-gitops-argocd-application-controller
    namespace: openshift-gitops
```

**RBAC Pattern:**

OdhDashboardConfig uses **namespace-level RBAC** (same pattern as HardwareProfile):

```yaml
# components/rhoai/base/cluster-namespace-redhat-ods-applications.yaml
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops  # Grants ArgoCD edit permissions
```

**No ignoreDifferences needed:**
- The `managed-by` label provides sufficient RBAC for ArgoCD to manage the CR
- Operator adds runtime annotations/labels (e.g., `platform.opendatahub.io/*`)
- Operator manages dynamic spec fields (`hardwareProfileOrder`, `templateDisablement`, `templateOrder`)
- ArgoCD manages declared spec fields (`dashboardConfig`, `notebookController`)
- No sync conflicts occur - each system manages its own fields

**Why this approach:**
- ✅ Simple: Single namespace label grants all necessary permissions
- ✅ No ignoreDifferences: Namespace RBAC handles operator-managed metadata
- ✅ GitOps-native: CR managed like any other namespace-scoped resource
- ✅ Auditable: Changes tracked in Git, visible in ArgoCD UI

### MaaS Gateway for Model Serving

**Pattern**: Static manifest with CMP placeholder, namespace-level RBAC

**Location**: `components/rhoai/base/openshift-ingress-gateway-maas-default-gateway.yaml`

Models as a Service requires a Gateway API resource for exposing model endpoints:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: data-science-gateway-class  # RHOAI's Gateway controller
  listeners:
  - allowedRoutes:
      namespaces:
        from: All  # Cross-namespace routing for model serving
    hostname: maas-api.CMP_PLACEHOLDER_OCP_APPS_DOMAIN
    name: https
    port: 443
    protocol: HTTPS
    tls:
      certificateRefs:
      - kind: Secret
        name: ingress-certificates  # Let's Encrypt wildcard cert
      mode: Terminate
```

**RBAC Requirement for Gateway Creation:**

The `openshift-ingress` namespace has the ArgoCD managed-by label, but Gateway resources require explicit RBAC:

```yaml
# components/cluster-ingress/base/openshift-ingress-role-gateway-manager.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gateway-manager
  namespace: openshift-ingress
rules:
- apiGroups: [gateway.networking.k8s.io]
  resources: [gateways]
  verbs: ['*']
```

```yaml
# components/cluster-ingress/base/openshift-ingress-rb-gateway-manager.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gateway-manager
  namespace: openshift-ingress
roleRef:
  kind: Role
  name: gateway-manager
subjects:
- kind: ServiceAccount
  name: openshift-gitops-argocd-application-controller
  namespace: openshift-gitops
```

**Why explicit RBAC is needed:**
- Gateway is a custom resource from gateway.networking.k8s.io API group
- Auto-generated Role from namespace label grants only **read** permissions (`get, list, watch`) for CRDs
- ArgoCD needs **write** permissions to create/update Gateways
- RBAC defined in cluster-ingress component (shared infrastructure) rather than rhoai component
- Error without RBAC: `gateways.gateway.networking.k8s.io is forbidden: cannot create resource "gateways"`

**Why static manifest works:**
- CMP plugin replaces `CMP_PLACEHOLDER_OCP_APPS_DOMAIN` with cluster apps domain at build time
- Gateway is namespace-scoped resource in `openshift-ingress`
- Explicit Role grants ArgoCD permission to manage Gateways
- Simpler than Job-based approach, direct declarative management

**Gateway Status:**
- Creates AWS ELB LoadBalancer service
- Assigns external hostname: `<uuid>.eu-central-1.elb.amazonaws.com`
- Internal service: `maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local:443`
- Supports HTTPRoute and GRPCRoute attachments for model serving

### HardwareProfile for GPU Workloads

**Pattern**: Direct CR management with namespace-level ArgoCD RBAC

HardwareProfiles define resource configurations for AI/ML workloads in RHOAI:

```yaml
# components/rhoai/base/redhat-ods-applications-hardwareprofile-gpus.yaml
apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
    opendatahub.io/display-name: gpus
  name: gpus
  namespace: redhat-ods-applications
spec:
  identifiers:
  - defaultCount: 2
    displayName: CPU
    identifier: cpu
    maxCount: 4
    minCount: 1
    resourceType: CPU
  - defaultCount: 4Gi
    displayName: Memory
    identifier: memory
    maxCount: 24Gi
    minCount: 2Gi
    resourceType: Memory
  - defaultCount: 1
    displayName: GPU
    identifier: nvidia.com/gpu
    maxCount: 2
    minCount: 1
    resourceType: Accelerator
  scheduling:
    node:
      nodeSelector: {}
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
    type: Node
```

**RBAC Requirement:**

The `redhat-ods-applications` namespace **MUST** have the ArgoCD managed-by label:

```yaml
# components/rhoai/base/cluster-namespace-redhat-ods-applications.yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    argocd.argoproj.io/managed-by: openshift-gitops  # CRITICAL for RBAC
    openshift.io/cluster-monitoring: "true"
  name: redhat-ods-applications
```

**Why this label is required:**
- Grants ArgoCD application controller permissions to manage resources in the namespace
- Without this label, ArgoCD cannot patch/update HardwareProfile resources
- Error without label: `User "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller" cannot patch resource "hardwareprofiles"`

**Operator-Managed Annotations:**

The RHOAI operator automatically adds runtime annotations to HardwareProfile resources:
- `opendatahub.io/dashboard-feature-visibility` - UI visibility settings
- `opendatahub.io/disabled` - Enable/disable status
- `opendatahub.io/modified-date` - Last modification timestamp

**These annotations do NOT cause sync drift.** ArgoCD manages the spec and core annotations (display-name), while the operator manages runtime metadata. No ignoreDifferences configuration is needed.

**Verified Behavior:**
- ✅ ArgoCD syncs HardwareProfile without conflicts
- ✅ Operator annotations coexist with GitOps-managed fields
- ✅ Application remains Synced and Healthy
- ✅ No ignoreDifferences required (namespace label is sufficient)

**Pattern Applies To:**
- HardwareProfile (this section)
- OdhDashboardConfig (see above)
- Any namespace-scoped CR in `redhat-ods-applications` where operator adds runtime metadata

**Use Case:**
Enables RHOAI users to select GPU-enabled resource profiles when creating:
- Jupyter notebooks with GPU support
- Model training workloads
- Model serving deployments
- Distributed inference workloads

### LlamaStack RAG Deployment

**Pattern**: Multi-component RAG system with PostgreSQL metadata storage, vLLM inference, and LlamaStack distribution

**Purpose**: Complete RAG (Retrieval-Augmented Generation) stack for AI applications using IBM Granite models.

**Namespaces**:
- `ai-models-service` - Granite model inference servers (embedding + LLM)
- `external-db-llamastack` - External database namespace (PostgreSQL for metadata)
- `llamastack` - LlamaStack distribution and model serving

**Component**: `uc-llamastack` (ArgoCD Application)

#### PostgreSQL 16 for Metadata Storage

**Pattern**: Red Hat supported PostgreSQL deployment with persistent storage

**Purpose**: Provides PostgreSQL 16 database for LlamaStack metadata storage (NOT vector embeddings).

**Namespace**: `external-db-llamastack`

**✅ Red Hat Supported Configuration (Current)**

**Image**: `registry.redhat.io/rhel9/postgresql-16:9.7`

**Use Case**: LlamaStack metadata storage (conversation history, agent state, etc.)

**NOT Used For**: Vector embeddings storage (no pgvector extension)

**Why No pgvector:**
- pgvector NOT available in Red Hat UBI PostgreSQL containers
- LlamaStack uses this database for metadata only
- Vector embeddings handled separately by dedicated vector database in RAG pipeline

**Components:**

```yaml
# Deployment with Red Hat PostgreSQL 16
image: registry.redhat.io/rhel9/postgresql-16:9.7
env:
- name: POSTGRESQL_DATABASE
  valueFrom:
    secretKeyRef:
      key: POSTGRES_DB
      name: llamastack-postgresql-credentials
- name: POSTGRESQL_PASSWORD
  valueFrom:
    secretKeyRef:
      key: POSTGRES_PASSWORD
      name: llamastack-postgresql-credentials
- name: POSTGRESQL_USER
  valueFrom:
    secretKeyRef:
      key: POSTGRES_USER
      name: llamastack-postgresql-credentials

# Readiness and Liveness Probes
readinessProbe:
  exec:
    command:
    - /bin/sh
    - -c
    - pg_isready -h 127.0.0.1 -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DATABASE"
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 6

livenessProbe:
  exec:
    command:
    - /bin/sh
    - -c
    - pg_isready -h 127.0.0.1 -U "$POSTGRESQL_USER" -d "$POSTGRESQL_DATABASE"
  initialDelaySeconds: 30
  periodSeconds: 20
  timeoutSeconds: 5
  failureThreshold: 6

# Resources
resources:
  limits:
    cpu: "1"
    memory: 2Gi
  requests:
    cpu: 250m
    memory: 512Mi

# PersistentVolumeClaim
storageClassName: gp3-csi
storage: 10Gi
accessModes: ReadWriteOnce

# Secret (demo credentials)
POSTGRES_USER: llamastack
POSTGRES_DB: llamastackdb
POSTGRES_PASSWORD: changeme-demo-only  # Demo/lab placeholder

# Service
type: ClusterIP
port: 5432
```

**Database Configuration:**
- Version: PostgreSQL 16 (Red Hat RHEL 9 based)
- Image: `registry.redhat.io/rhel9/postgresql-16:9.7`
- Database: `llamastackdb`
- User: `llamastack`
- Extension: None (metadata storage only)
- Encoding: UTF8
- Data directory: `/var/lib/postgresql/data` (Red Hat default)

**⚠️ CRITICAL: Red Hat PostgreSQL Environment Variables**

Red Hat PostgreSQL containers use **POSTGRESQL_*** naming convention (not POSTGRES_*):

```yaml
# ✅ CORRECT - Red Hat PostgreSQL
- name: POSTGRESQL_USER
- name: POSTGRESQL_PASSWORD  
- name: POSTGRESQL_DATABASE

# ❌ WRONG - Community PostgreSQL naming
- name: POSTGRES_USER
- name: POSTGRES_PASSWORD
- name: POSTGRES_DB
```

**Impact of incorrect naming**: Pod CrashLoopBackOff with error message:
```
you must either specify POSTGRESQL_USER POSTGRESQL_PASSWORD POSTGRESQL_DATABASE
```

**Note**: Secret keys still use `POSTGRES_*` naming (unchanged), but deployment env vars map them to `POSTGRESQL_*`.

**Verification:**
```bash
# Check database connection
oc exec deployment/llamastack-postgresql -n external-db-llamastack -- \
  psql -U llamastack -d llamastackdb -c "SELECT version();"
```

**Node Placement:**
- Scheduled on worker nodes (application workload)
- No infra node constraints

**Connection:**
```
llamastack-postgresql.external-db-llamastack.svc.cluster.local:5432
```

**Security:**
- Demo credentials marked with `# gitleaks:allow`
- Added to `.gitleaks.toml` allowlist

**Files:**
```
components/uc-llamastack/base/
├── cluster-namespace-external-db-llamastack.yaml
├── cluster-namespace-llamastack.yaml
├── external-db-llamastack-deployment-llamastack-postgresql.yaml
├── external-db-llamastack-pvc-llamastack-postgresql.yaml
├── external-db-llamastack-secret-llamastack-postgresql-credentials.yaml
├── external-db-llamastack-service-llamastack-postgresql.yaml
├── llamastack-llamastackdistribution-llamastack.yaml
├── llamastack-secret-postgres-secret.yaml
└── ... (additional LlamaStack resources)
```

#### MariaDB with TLS for DSPA

**Pattern**: Deployment with OpenShift Service CA TLS for DataSciencePipelinesApplication

**Purpose**: Provides MariaDB database with TLS encryption for RHOAI Data Science Pipelines (Kubeflow Pipelines).

**Namespace**: `external-db-llamastack`

**Components:**

```yaml
# Service with OpenShift Service CA annotation
apiVersion: v1
kind: Service
metadata:
  name: dspa-mariadb
  namespace: external-db-llamastack
  annotations:
    # OpenShift Service CA automatically creates TLS certificate
    service.beta.openshift.io/serving-cert-secret-name: dspa-mariadb-tls
spec:
  ports:
  - port: 3306
    protocol: TCP
    targetPort: 3306
  selector:
    app: dspa-mariadb
  type: ClusterIP

# Deployment with TLS configuration
image: registry.redhat.io/rhel9/mariadb-105:1-1775695255
env:
- name: MYSQL_USER
  valueFrom:
    secretKeyRef:
      name: dspa-mariadb-credentials
      key: username
- name: MYSQL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: dspa-mariadb-credentials
      key: password
- name: MYSQL_DATABASE
  valueFrom:
    secretKeyRef:
      name: dspa-mariadb-credentials
      key: database
volumeMounts:
- mountPath: /var/lib/mysql
  name: data
- mountPath: /etc/mysql-certs
  name: tls-certs
  readOnly: true
- mountPath: /etc/my.cnf.d/tls.cnf
  name: tls-config
  subPath: tls.cnf
  readOnly: true

# ConfigMap with MariaDB TLS configuration
data:
  tls.cnf: |
    [mysqld]
    ssl-ca=/etc/mysql-certs/tls.crt
    ssl-cert=/etc/mysql-certs/tls.crt
    ssl-key=/etc/mysql-certs/tls.key

# Secret credentials (demo/lab)
username: mlpipeline
password: changeme-demo-only  # Demo/lab placeholder
database: mlpipeline

# PersistentVolumeClaim
storageClassName: gp3-csi
storage: 10Gi
accessModes: ReadWriteOnce
```

**CRITICAL: OpenShift Service CA Pattern**

**Why OpenShift Service CA instead of cert-manager:**

1. **Automatic trust**: All cluster components automatically trust OpenShift's internal CA
2. **Zero configuration**: No manual CA injection or certificate distribution
3. **Auto-renewal**: OpenShift handles certificate rotation automatically
4. **Standard pattern**: Recommended approach for internal service-to-service TLS

**Service annotation triggers automatic certificate creation:**
```yaml
annotations:
  service.beta.openshift.io/serving-cert-secret-name: dspa-mariadb-tls
```

**Result**: OpenShift creates Secret `dspa-mariadb-tls` with:
- `tls.crt` - Server certificate (trusted by all pods)
- `tls.key` - Private key

**DSPA External Database Requirement:**

DataSciencePipelinesApplication **requires TLS** for external database connections. Without TLS:
```
Error: TLS requested but server does not support TLS
```

**Database Configuration:**
- Version: MariaDB 10.5 (RHEL9-based)
- Database: `mlpipeline`
- User: `mlpipeline`
- TLS: OpenShift Service CA (automatic)
- Data directory: `/var/lib/mysql`

**Health Checks:**
```yaml
livenessProbe:
  exec:
    command:
    - /bin/sh
    - -c
    - MYSQL_PWD="$MYSQL_PASSWORD" mysqladmin -u $MYSQL_USER --ssl-ca=/etc/mysql-certs/tls.crt ping
```

**Connection:**
```
dspa-mariadb.external-db-llamastack.svc.cluster.local:3306
```

**DSPA Configuration Example:**
```yaml
apiVersion: datasciencepipelinesapplications.opendatahub.io/v1
kind: DataSciencePipelinesApplication
metadata:
  name: pipelines
  namespace: ai-generation-llm-rag
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  database:
    externalDB:
      host: dspa-mariadb.external-db-llamastack.svc.cluster.local
      port: "3306"
      username: mlpipeline
      pipelineDBName: mlpipeline
      passwordSecret:
        name: dspa-mariadb-password
        key: password
  objectStorage:
    externalStorage:
      host: s3.openshift-storage.svc
      port: "443"
      bucket: "ai-generation-llm-rag-pipelines"  # Static bucket name - critical!
      scheme: https
      s3CredentialsSecret:
        accessKey: AWS_ACCESS_KEY_ID
        secretKey: AWS_SECRET_ACCESS_KEY
        secretName: pipeline-artifacts  # Auto-created by OBC
```

**CRITICAL: Static Bucket Name Pattern**

**Always use static bucket names** in OBC, never auto-generated names:

```yaml
# ✅ CORRECT - Static bucket name
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: pipeline-artifacts
  namespace: ai-generation-llm-rag
spec:
  bucketName: ai-generation-llm-rag-pipelines  # Static, predictable name
  storageClassName: openshift-storage.noobaa.io
```

```yaml
# ❌ WRONG - Auto-generated bucket name
spec:
  generateBucketName: pipeline-artifacts  # Creates UUID suffix
```

**Why static names are required:**

1. **Chicken-and-egg problem**: OBC creates bucket name at runtime, but DSPA needs bucket name to deploy
2. **Auto-generated names**: OBC adds UUID suffix (e.g., `pipeline-artifacts-43b455e5-...`)
3. **DSPA validation**: DSPA fails if bucket field is empty, even temporarily
4. **PostSync Jobs fail**: Attempting to patch bucket name after DSPA creation doesn't work reliably
5. **Static approach**: Simple, declarative, robust for redeployment

**Credentials managed automatically:**
- OBC creates Secret `pipeline-artifacts` with `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
- DSPA references this Secret for S3 access
- No manual credential management needed

**Result**: DSPA deploys successfully on first sync, no dynamic patching required.

**Security:**
- Demo credentials marked with `# gitleaks:allow`
- Added to `.gitleaks.toml` allowlist (mlpipeline)
- TLS enforced for all connections
- For production: use external secret management

**Files:**
```
components/rhoai/base/
├── external-db-llamastack-configmap-dspa-mariadb-tls-config.yaml
├── external-db-llamastack-deployment-dspa-mariadb.yaml
├── external-db-llamastack-pvc-dspa-mariadb.yaml
├── external-db-llamastack-secret-dspa-mariadb-credentials.yaml
└── external-db-llamastack-service-dspa-mariadb.yaml
```

**Verification:**
```bash
# Check TLS secret created by OpenShift Service CA
oc get secret dspa-mariadb-tls -n external-db-llamastack

# Test TLS connectivity
oc exec deployment/dspa-mariadb -n external-db-llamastack -- \
  mysql -u mlpipeline -p --ssl-ca=/etc/mysql-certs/tls.crt \
  -e "SHOW STATUS LIKE 'Ssl_cipher';"
```

#### GitOps Automation for KFP Pipeline Definitions

**Pattern**: PostSync Job with init container for cross-namespace ConfigMap access, ServiceAccount token authentication

**Purpose**: Automate upload of Kubeflow Pipelines (KFP) v2 pipeline definitions to DSPA API using GitOps.

**Component**: `uc-ai-generation-llm-rag` (user workload separated from RHOAI platform)

**Key Concepts:**

**KFP v2 pipelines are API-managed resources, not Kubernetes CRs:**
- Pipelines exist as database records in DSPA's MariaDB backend
- Managed via REST API, not kubectl/GitOps directly
- Require programmatic upload using KFP Python SDK

**Architecture:**

```
┌─────────────────────────────────────────────────────────┐
│ ai-generation-llm-rag namespace                         │
│  - ConfigMap: pipeline-docling-standard (pipeline YAML) │
│  - DataSciencePipelinesApplication (DSPA)               │
│  - Secret: dspa-mariadb-password (credentials ref)      │
└─────────────────────────────────────────────────────────┘
                      ▲
                      │ (1) Init container fetches ConfigMap
                      │     using oc CLI (ose-cli image)
┌─────────────────────────────────────────────────────────┐
│ openshift-gitops namespace                              │
│  - Job: upload-pipeline-docling-standard (PostSync)     │
│    ├─ Init: fetch-pipeline (ose-cli)                    │
│    │   └─ oc get configmap → /pipeline/pipeline.yaml   │
│    └─ Main: upload-pipeline (python-311)                │
│        └─ KFP SDK upload via REST API                   │
│  - ConfigMap: pipeline-upload-script (Python)           │
│  - ServiceAccount: pipeline-uploader                    │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ external-db-generation-llm-rag namespace                │
│  - Deployment: dspa-mariadb (KFP metadata)              │
│    └─ Service: dspa-mariadb:3306                        │
│  - Deployment: rag-postgresql (pgvector for RAG)        │
│    └─ Service: rag-postgresql:5432                      │
│  - PVCs: 10Gi each (gp3-csi)                            │
│  - Secrets: Credentials for both databases              │
└─────────────────────────────────────────────────────────┘
```

**Implementation:**

**1. Pipeline Definition as ConfigMap:**
```yaml
# components/uc-ai-generation-llm-rag/base/ai-generation-llm-rag-cm-pipeline-docling-standard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pipeline-docling-standard
  namespace: ai-generation-llm-rag
data:
  pipeline.yaml: |
    # KFP v2 pipeline definition (1000+ lines)
    # Generated from Python using kfp.compiler.Compiler().compile()
```

**2. Init Container Pattern for Cross-Namespace Access:**

Problem: Kubernetes doesn't support mounting ConfigMaps from other namespaces.

Solution: Init container with oc CLI fetches ConfigMap content, shares via emptyDir volume:

```yaml
# Job spec (simplified)
initContainers:
- name: fetch-pipeline
  image: registry.redhat.io/openshift4/ose-cli:latest
  command:
  - /bin/bash
  - -c
  - |
    set -e
    oc get configmap pipeline-docling-standard -n ai-generation-llm-rag \
      -o jsonpath='{.data.pipeline\.yaml}' > /pipeline/pipeline.yaml
  volumeMounts:
  - name: pipeline-data
    mountPath: /pipeline

containers:
- name: upload-pipeline
  image: registry.access.redhat.com/ubi9/python-311:latest
  env:
  - name: PIPELINE_FILE
    value: /pipeline/pipeline.yaml
  volumeMounts:
  - name: pipeline-data
    mountPath: /pipeline
    readOnly: true

volumes:
- name: pipeline-data
  emptyDir: {}
```

**3. ServiceAccount Authentication for KFP Client:**

DSPA API requires authentication even for internal service-to-service calls:

```python
# Python upload script
token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
with open(token_path, 'r') as f:
    token = f.read().strip()

client = kfp.Client(
    host='https://ds-pipeline-pipelines.ai-generation-llm-rag.svc:8443',
    verify_ssl=False,
    existing_token=token
)
```

**4. Hash-Based Versioning for Idempotency:**

Prevents duplicate uploads on every sync:

```python
import hashlib

def calculate_pipeline_hash(filepath):
    with open(filepath, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()[:12]

pipeline_hash = calculate_pipeline_hash(PIPELINE_FILE)
version_name = f"v-{pipeline_hash}"  # e.g., v-e1e153422907

# Check if version already exists
if version_name in existing_versions:
    print(f"Version '{version_name}' already exists - skipping (idempotent)")
    sys.exit(0)
```

**Behavior:**
- Pipeline definition unchanged → Job skips upload (idempotent)
- Pipeline definition changes → New version uploaded with new hash

**5. RBAC Configuration:**

ServiceAccount requires permissions for:
- Reading ConfigMap in ai-generation-llm-rag namespace
- Managing DSPA pipelines via API

```yaml
# RoleBinding in ai-generation-llm-rag namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pipeline-manager
  namespace: ai-generation-llm-rag
subjects:
- kind: ServiceAccount
  name: pipeline-uploader
  namespace: openshift-gitops
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  # Operator-provided ClusterRole includes /api subresource permissions
  name: data-science-pipelines-operator-aggregate-dspa-admin-edit
```

**CRITICAL RBAC Detail:**

The DSPA API endpoint requires permissions on the `datasciencepipelinesapplications/api` subresource:

```yaml
# Operator-provided ClusterRole (do not recreate manually)
rules:
- apiGroups: [datasciencepipelinesapplications.opendatahub.io]
  resources:
  - datasciencepipelinesapplications
  - datasciencepipelinesapplications/api  # Required for KFP client access
  verbs: [get, list, watch, create, update, patch, delete]
```

Without `/api` subresource permission:
```
403 Forbidden (user=system:serviceaccount:openshift-gitops:pipeline-uploader,
  verb=get, resource=datasciencepipelinesapplications, subresource=api)
```

**6. PostSync Hook Configuration:**

```yaml
# Job metadata
annotations:
  argocd.argoproj.io/hook: PostSync
  argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

**Execution flow:**
1. ArgoCD syncs DSPA and ConfigMap resources
2. PostSync hook triggers after successful sync
3. Job fetches pipeline definition via init container
4. Job uploads pipeline to DSPA using KFP SDK
5. Job completes, ArgoCD deletes Job (HookSucceeded policy)

**Error Handling:**

Common issues and fixes:

| Error | Cause | Fix |
|-------|-------|-----|
| 401 Unauthorized | Missing ServiceAccount token | Add `existing_token=token` to kfp.Client() |
| 403 Forbidden (api subresource) | Missing RBAC for /api | Use operator-provided ClusterRole |
| Pipeline ID is None | Pipeline doesn't exist | Raise ValueError to trigger creation flow |
| Cross-namespace mount | ConfigMap in different namespace | Use init container with oc CLI |

**Files:**

```
components/uc-ai-generation-llm-rag/base/
├── ai-generation-llm-rag-cm-pipeline-docling-standard.yaml               # Pipeline definition
├── ai-generation-llm-rag-dspa-pipelines.yaml                             # DSPA CR
├── ai-generation-llm-rag-obc-pipeline-artifacts.yaml                     # S3 bucket for pipeline artifacts
├── ai-generation-llm-rag-rb-pipeline-configmap-reader.yaml               # ConfigMap RBAC
├── ai-generation-llm-rag-rb-pipeline-manager.yaml                        # DSPA API RBAC
├── ai-generation-llm-rag-role-pipeline-configmap-reader.yaml             # ConfigMap Role
├── ai-generation-llm-rag-secret-dspa-mariadb-password.yaml               # DSPA MariaDB password reference
├── cluster-crb-argocd-manage-uc-workload.yaml                            # ArgoCD RBAC
├── cluster-namespace-ai-generation-llm-rag.yaml                          # User workload namespace
├── cluster-namespace-external-db-generation-llm-rag.yaml                 # External database namespace
├── external-db-generation-llm-rag-configmap-dspa-mariadb-tls-config.yaml # MariaDB TLS CA bundle
├── external-db-generation-llm-rag-deployment-dspa-mariadb.yaml           # MariaDB deployment
├── external-db-generation-llm-rag-deployment-rag-postgresql.yaml         # PostgreSQL 16 + pgvector
├── external-db-generation-llm-rag-pvc-dspa-mariadb.yaml                  # MariaDB storage (10Gi)
├── external-db-generation-llm-rag-pvc-rag-postgresql.yaml                # PostgreSQL storage (10Gi)
├── external-db-generation-llm-rag-secret-dspa-mariadb-credentials.yaml   # MariaDB credentials
├── external-db-generation-llm-rag-secret-rag-postgresql-credentials.yaml # PostgreSQL credentials
├── external-db-generation-llm-rag-service-dspa-mariadb.yaml              # MariaDB service (port 3306)
├── external-db-generation-llm-rag-service-rag-postgresql.yaml            # PostgreSQL service (port 5432)
├── openshift-gitops-cm-pipeline-upload-script.yaml                       # Python upload script
├── openshift-gitops-job-upload-pipeline-docling-standard.yaml            # PostSync Job
└── openshift-gitops-sa-pipeline-uploader.yaml                            # ServiceAccount
```

**External Databases:**

**Namespace**: `external-db-generation-llm-rag`

The component deploys two separate databases in a dedicated namespace for isolation:

1. **dspa-mariadb** - DSPA metadata backend (KFP pipelines, runs, experiments)
   - Image: `registry.redhat.io/rhel9/mariadb-1011:1-78.1731539089`
   - Storage: 10Gi PVC (gp3-csi)
   - Service: `dspa-mariadb.external-db-generation-llm-rag.svc.cluster.local:3306`
   - Credentials: Secret `dspa-mariadb-credentials` (database=mlpipeline, username=mlpipeline)
   - TLS: Service annotation auto-generates certificate via OpenShift service-ca

2. **rag-postgresql** - Vector embeddings database for RAG applications
   - Image: `pgvector/pgvector:pg16`
   - Storage: 10Gi PVC (gp3-csi)
   - Service: `rag-postgresql.external-db-generation-llm-rag.svc.cluster.local:5432`
   - Credentials: Secret `rag-postgresql-credentials` (database=ragdb, username=raguser)
   - Extensions: pgvector automatically initialized via lifecycle.postStart hook

**PostgreSQL pgvector Auto-Initialization:**

```yaml
# Pattern from external-db-generation-llm-rag-deployment-rag-postgresql.yaml
lifecycle:
  postStart:
    exec:
      command:
      - /bin/sh
      - -c
      - |
        set -e
        echo "Waiting for PostgreSQL to be ready before enabling pgvector..."
        until PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" >/dev/null 2>&1; do
          sleep 2
        done
        PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

**Why separate databases:**
- DSPA requires MariaDB for metadata storage (KFP standard)
- RAG applications require PostgreSQL with pgvector for semantic search
- Namespace isolation separates data plane from workload plane
- Independent scaling and lifecycle management

**Verification:**

```bash
# Check MariaDB deployment
oc get deployment dspa-mariadb -n external-db-generation-llm-rag
oc exec deployment/dspa-mariadb -n external-db-generation-llm-rag -- mysql -u mlpipeline -pchangeme-demo-only -e "SHOW DATABASES;"

# Check PostgreSQL deployment with pgvector
oc get deployment rag-postgresql -n external-db-generation-llm-rag
oc exec deployment/rag-postgresql -n external-db-generation-llm-rag -- \
  psql -U raguser -d ragdb -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"

# Expected output: vector | 0.8.0 (or later)
```

**Verification:**

```bash
# Check Job completed successfully
oc get job upload-pipeline-docling-standard -n openshift-gitops

# List pipelines in DSPA
oc run -it --rm kfp-test --image=registry.access.redhat.com/ubi9/python-311:latest \
  --restart=Never -n openshift-gitops -- bash -c "
pip install --quiet kfp==2.14.6
python3 -c '
import kfp
token = open(\"/var/run/secrets/kubernetes.io/serviceaccount/token\").read().strip()
client = kfp.Client(host=\"https://ds-pipeline-pipelines.ai-generation-llm-rag.svc:8443\",
                    verify_ssl=False, existing_token=token)
pipelines = client.list_pipelines()
for p in pipelines.pipelines:
    print(f\"Name: {p.display_name}, ID: {p.pipeline_id}\")
'"

# Expected output:
# Name: docling-standard-convert, ID: eddb696e-6f59-4bb0-9411-a0ba390004a9
```

**Component Separation:**

**uc-ai-generation-llm-rag** (user workload) vs **rhoai** (platform):

- `rhoai` component: RHOAI operator, DataScienceCluster, platform configuration
- `uc-ai-generation-llm-rag` component: User workload (DSPA instance, pipelines, MariaDB, PostgreSQL+pgvector)
- Separation enables independent lifecycle management and clear ownership

**Key Patterns:**

✅ **Init container** for cross-namespace resource access
✅ **ServiceAccount token** authentication for internal APIs
✅ **Hash-based versioning** for idempotent uploads
✅ **Operator-provided ClusterRole** for RBAC (includes /api subresource)
✅ **PostSync hook** for automated pipeline upload after DSPA deployment
✅ **emptyDir volume** for sharing data between init and main containers

#### RAG Pipeline Container Images - Docling GPU Acceleration

**Critical Issue Resolved**: Red Hat AI container image compatibility with NVIDIA GPU drivers

**Problem (2026-04-11)**:

Red Hat's `rhai/docling-cuda-rhel9:3.2.1` image ships PyTorch 2.9.0 compiled with CUDA 12.9, but PyTorch 2.9.0 does not officially support CUDA 12.9. This causes CUDA Error 803 preventing GPU acceleration:

```
Error 803: system has unsupported display driver / cuda driver combination
(Triggered internally at /pytorch/c10/cuda/CUDAFunctions.cpp:119.)
```

**Root Cause**:
- Red Hat rebuilt PyTorch 2.9.0 from source using their `fromager` build system
- Compiled against CUDA 12.9 (cuda-compat-12-9-575.57.08-1.el9.x86_64)
- PyTorch 2.9.0 officially supports: CUDA 12.6, 12.8, 13.0 (experimental) - NOT 12.9
- CUDA 12.9 support was present in PyTorch 2.8 but dropped for 2.9

**Solution**:

Switch to community docling image with compatible PyTorch/CUDA versions:

```yaml
# Updated in:
# - components/uc-ai-generation-llm-rag/base/ai-generation-llm-rag-cm-pipeline-chunk-data.yaml
# - components/uc-ai-generation-llm-rag/base/ai-generation-llm-rag-cm-pipeline-rag-data-ingestion.yaml

# OLD (broken):
image: registry.redhat.io/rhai/docling-cuda-rhel9:3.2.1
# PyTorch 2.9.0 + CUDA 12.9 → CUDA Error 803

# NEW (working):
image: quay.io/docling-project/docling-serve-cu126:latest
# PyTorch 2.10.0+cu126 + CUDA 12.6 → GPU acceleration confirmed
```

**Verified GPU Tasks**:

Four pipeline tasks successfully executed with GPU acceleration (Tesla T4):

| Task | Document | GPU | Processing Time | Output |
|------|----------|-----|-----------------|--------|
| docling-convert-standard | 2203.01017v2.pdf | cuda:0 | 23.20 sec | JSON + Markdown |
| docling-convert-standard | 2206.01062.pdf | cuda:0 | 10.60 sec | JSON + Markdown |
| docling-chunk | 2203.01017v2.pdf | cuda:0 | N/A | 39 semantic chunks |
| docling-chunk | 2206.01062.pdf | cuda:0 | N/A | 42 semantic chunks |

**GPU Models Loaded**:
- Layout analysis: `docling_layout_default`
- Table structure recognition: `docling_tableformer`
- Both use GPU-accelerated computer vision models

**Alternative Images Tested**:

Community docling images from `quay.io/docling-project/`:
- `docling-serve-cu126:latest` - PyTorch 2.10.0+cu126 (CUDA 12.6) ✅ **SELECTED**
- `docling-serve-cu128:latest` - PyTorch 2.10.0+cu128 (CUDA 12.8) ✅ **TESTED OK**

**JIRA Issue Filed**:

Reported to Red Hat AI team (RHAIENG project) - ticket template: `/tmp/rhaieng-jira-ticket.md`

Requested fix options:
1. Rebuild PyTorch 2.9.0 with CUDA 12.6 or 12.8 (recommended)
2. Downgrade to PyTorch 2.8.x (supports CUDA 12.9)
3. Upgrade to PyTorch 2.10+ when CUDA 12.9 support is re-added

**Verification**:

```bash
# Check pipeline ConfigMap uses community image
oc get configmap pipeline-rag-data-ingestion -n ai-generation-llm-rag -o yaml | \
  grep "quay.io/docling-project/docling-serve-cu126"

# Run pipeline and verify GPU acceleration in logs
oc logs <docling-pod> -n ai-generation-llm-rag -c main | grep "Accelerator device"
# Expected: [KFP Executor] Accelerator device: 'cuda:0'

# Verify NO CUDA Error 803
oc logs <docling-pod> -n ai-generation-llm-rag -c main | grep -i "error 803"
# Expected: (no output)
```

**GPU Driver Compatibility**:

Works with NVIDIA GPU Operator driver 580.126.20 (CUDA 13.0 support):
- Tesla T4 GPUs (Turing architecture)
- Driver installed via GPU Operator v26.3
- Compatible with both CUDA 12.6 (docling) and CUDA 13.0 (driver)

❌ **DO NOT** create custom ClusterRole for DSPA (operator provides complete RBAC)
❌ **DO NOT** mount ConfigMaps across namespaces (Kubernetes restriction)
❌ **DO NOT** use unauthenticated KFP client (DSPA requires token)

**GPU Scheduling for KFP Pipeline Tasks:**

**CRITICAL**: HardwareProfile does NOT apply to KFP pipeline pods - GPU tolerations must be explicit.

**Problem**: GPU nodes have taint `nvidia.com/gpu=present:NoSchedule` to prevent non-GPU workloads from consuming expensive resources.

**HardwareProfile limitation:**
- HardwareProfile webhooks only mutate: Notebooks, InferenceServices, LLMInferenceServices
- KFP pipeline pods are NOT mutated by HardwareProfile
- GPU resource requests alone are insufficient (pods stay Pending without tolerations)

**Solution**: Add tolerations per executor in `platforms.kubernetes.deploymentSpec` section:

```yaml
# Pipeline ConfigMap - platforms section
platforms:
  kubernetes:
    deploymentSpec:
      executors:
        # GPU executors (docling-cuda-rhel9 image)
        exec-docling-chunk:
          tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
        exec-docling-convert-standard:
          tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
        exec-download-docling-models:
          tolerations:
          - key: nvidia.com/gpu
            operator: Exists
            effect: NoSchedule
        
        # CPU-only executors (no tolerations needed)
        exec-import-pdfs:
          secretAsVolume: [...]
        exec-create-pdf-splits:
          # No tolerations - uses ubi9/python-311
```

**Executor configuration:**

| Executor | Image | GPU | Tolerations |
|----------|-------|-----|-------------|
| `exec-docling-chunk` | `docling-cuda-rhel9:3.2.1` | ✅ `nvidia.com/gpu: 1` | ✅ Required |
| `exec-docling-convert-standard` | `docling-cuda-rhel9:3.2.1` | ✅ `nvidia.com/gpu: 1` | ✅ Required |
| `exec-download-docling-models` | `docling-cuda-rhel9:3.2.1` | ❌ No GPU request | ✅ Required (downloads GPU models) |
| `exec-import-pdfs` | `ubi9/python-311:9.7` | ❌ CPU only | ❌ Not needed |
| `exec-create-pdf-splits` | `ubi9/python-311:9.7` | ❌ CPU only | ❌ Not needed |

**Image versions (latest supported):**
- **docling-cuda-rhel9**: `3.2.1` (CUDA-enabled for GPU acceleration)
- **ubi9/python-311**: `9.7-1775725322` (CPU tasks)

**GPU resource requests in executors section:**
```yaml
executors:
  exec-docling-convert-standard:
    container:
      image: registry.redhat.io/rhai/docling-cuda-rhel9:3.2.1
      resources:
        accelerator:
          count: '1'
          type: nvidia.com/gpu
```

**Why both resources AND tolerations are required:**
1. **Resources** (`nvidia.com/gpu: 1`): Requests GPU allocation from kubelet
2. **Tolerations**: Allows pod to schedule on tainted GPU nodes
3. **Without tolerations**: Pod stays Pending even with GPU request (cannot tolerate taint)

**Verification:**

```bash
# Run pipeline and check pod scheduling
oc get pods -n ai-generation-llm-rag -l pipeline/runid

# Check GPU task pods scheduled on GPU nodes
oc get pod <docling-pod> -n ai-generation-llm-rag -o jsonpath='{.spec.nodeName}'
# Expected: ip-10-0-27-42.eu-central-1.compute.internal (GPU node)

# Verify tolerations applied
oc get pod <docling-pod> -n ai-generation-llm-rag -o jsonpath='{.spec.tolerations}'
# Expected: [{"effect":"NoSchedule","key":"nvidia.com/gpu","operator":"Exists"}]
```

**Pipeline update workflow:**
1. Edit pipeline ConfigMap in `components/uc-ai-generation-llm-rag/base/`
2. Commit and push changes
3. ArgoCD syncs ConfigMap
4. PostSync hook re-uploads pipeline (hash-based versioning detects changes)
5. New pipeline version available in DSPA UI

**Known Issue: DAG Graph Visualization Shows Misleading Dependencies**

**Problem:** The Data Science Pipelines UI graph displays misleading visual connections that mix execution dependencies (what blocks execution) with artifact flow (data lineage).

**Symptom:**
- Graph shows visual arrows/boxes suggesting a task waits for multiple upstream tasks
- Actual execution timing proves task only depends on subset of visually connected tasks
- Cannot determine critical path or actual execution order from graph alone

**Example:**
```
Graph shows:  task_a ──┐
                       ├──→ task_c  (appears to wait for both)
              task_b ──┘

Timing shows: task_a completes at t=10s
              task_c STARTS at t=11s (only waits for task_a)
              task_b completes at t=180s (task_c didn't wait for this!)
```

**Root Cause:**
- Upstream Kubeflow Pipelines issue (KFP #4924, #3790)
- UI mixes artifact consumption (data flow) with execution blocking (task dependencies)
- RHOAI inherits this from KFP v2

**Workaround - Verify Actual Dependencies:**

```bash
# Get workflow execution timing
WORKFLOW=$(oc get workflow -n ai-generation-llm-rag --sort-by=.metadata.creationTimestamp | tail -1 | awk '{print $1}')

# Check actual task start/finish times
oc get workflow ${WORKFLOW} -n ai-generation-llm-rag -o jsonpath='{.status.nodes}' | \
  jq -r '[.[] | select(.type == "Pod")] | sort_by(.startedAt) | 
  map({task: .displayName, started: .startedAt, finished: .finishedAt})'

# Rule: If Task B starts BEFORE Task A finishes, Task B does NOT depend on Task A
```

**Tracking:**
- **JIRA:** [RHOAIENG-57573](https://redhat.atlassian.net/browse/RHOAIENG-57573) - Pipeline DAG graph shows misleading dependency arrows
- **Upstream:** [KFP #4924](https://github.com/kubeflow/pipelines/issues/4924), [KFP #3790](https://github.com/kubeflow/pipelines/issues/3790)
- **Status:** Documented - workaround available, pending upstream fix

**Impact:** Medium - Does not affect execution, but creates confusion for debugging and optimization.

#### Granite Model Inference Services

**Pattern**: KServe InferenceServices with OCI modelcar images in consolidated namespace

**Namespace**: `ai-models-service`

**Purpose**: Serves IBM Granite models (embedding + LLM) for RAG applications using vLLM on Tesla T4 GPUs.

**Architecture** (2026-04-14 refactoring):
- Both Granite models consolidated in single namespace `ai-models-service`
- Former `ai-embedding-service` namespace renamed
- Former `llamastack-model` InferenceService moved and renamed to `granite-llm`

**InferenceServices:**
1. **granite-embedding** - Granite embedding model (768-dim vectors)
2. **granite-llm** - Granite 3.1 8B Instruct (4-bit quantized, tool calling)

**Components:**

**1. Granite LLM InferenceService:**
```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: granite-llm
  namespace: ai-models-service
spec:
  predictor:
    model:
      modelFormat:
        name: vLLM
      runtime: granite-llm
      storageUri: oci://quay.io/redhat-ai-services/modelcar-catalog:granite-3.1-8b-instruct-quantized.w4a16
      args:
      # ❌ DO NOT add --quantization=awq (auto-detected from model config)
      # ❌ DO NOT add --dtype=half (quantized models use compressed-tensors)
      - --max-model-len=20000
      - --gpu-memory-utilization=0.80
      - --enable-auto-tool-choice
      - --tool-call-parser=granite
      - --chat-template=/app/data/template/tool_chat_template_granite.jinja
      - --max-num-seqs=128
      resources:
        requests: { cpu: 2, memory: 10Gi, nvidia.com/gpu: 1 }
        limits: { cpu: 2, memory: 12Gi, nvidia.com/gpu: 1 }
    tolerations:
    - key: nvidia.com/gpu
      operator: Exists
```

**2. ServingRuntime with Chat Template Mount:**
```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: granite-llm
  namespace: ai-models-service
spec:
  containers:
  - name: kserve-container
    image: registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:ec799bb5...
    volumeMounts:
    - name: chat-template
      mountPath: /app/data/template
      readOnly: true
    readinessProbe:
      tcpSocket:
        port: 8080
      initialDelaySeconds: 180  # Critical: CUDA graph compilation time
      periodSeconds: 10
      timeoutSeconds: 1
      failureThreshold: 3
  volumes:
  - name: chat-template
    configMap:
      name: granite-chat-template
```

**3. Chat Template ConfigMaps:**

Files:
- `llamastack-configmap-granite-chat-template.yaml` - Granite 3.x tool calling template (current)
- `llamastack-configmap-llama32-chat-template.yaml` - Llama 3.2 template (legacy)

Contains Jinja2 template for Granite tool calling with JSON format parser.

**⚠️ CRITICAL: Quantized Model Configuration**

**Quantization Auto-Detection:**
- ✅ **DO**: Let vLLM auto-detect quantization format from model config
- ❌ **DO NOT**: Add `--quantization=awq` argument explicitly
- **Why**: Granite 3.1 quantized uses `compressed-tensors` format, not AWQ
- **Error if wrong**: `Quantization method specified in model config (compressed-tensors) does not match the quantization method specified in 'quantization' argument (awq)`

**Model Variants:**
- `granite-3.1-8b-instruct-quantized.w4a16` - **Current** (4-bit weights, FP16 activations)
- `granite-3.3-8b-instruct` - Full precision FP16 (OOMs on single T4, requires 2 GPUs or quantization)
- `llama-3.2-3b-instruct` - Legacy (smaller model, fits easily)

**Quantization Format:**
- Format: `compressed-tensors` (w4a16 = 4-bit weights, 16-bit activations)
- Kernel: `ExllamaLinearKernel for CompressedTensorsWNA16`
- Memory footprint: ~4 GB model + ~7 GB KV cache = **11 GB total** (vs 16+ GB full precision)
- Quality trade-off: ~5-10% degradation vs FP16 (minimal impact for RAG use cases)

**Git History:**
- Commit `31dc700`: Switch from Llama 3.2 3B to Granite 3.1 8B quantized
- Commit `d5d53f3`: Fix quantization auto-detection (remove explicit --quantization arg)
- Reason: T4 GPU (14.56 GiB VRAM) insufficient for Granite 8B full precision

**GPU Memory Management (Quantized Model):**
- `--gpu-memory-utilization=0.80` (reduced from default 0.95)
- `--max-num-seqs=128` (reduced from default 256)
- **Why:** Tesla T4 has 14.56 GiB total memory
  - Quantized model requires ~4 GiB for weights (75% reduction vs FP16)
  - Additional ~7 GiB for KV cache + CUDA graphs
  - 80% utilization provides stable operation
  - Full precision Granite 8B OOMs (requires ~16 GB for weights alone)

**Memory Comparison:**

| Model | Precision | Model Weights | KV Cache | Total | Fits T4? |
|-------|-----------|---------------|----------|-------|----------|
| Granite 3.3 8B | FP16 | ~16 GB | N/A | 16+ GB | ❌ OOM |
| Granite 3.1 8B | 4-bit (w4a16) | ~4 GB | ~7 GB | ~11 GB | ✅ Success |
| Llama 3.2 3B | FP16 | ~6 GB | ~8 GB | ~14 GB | ✅ Success |

**Attention Backend:**
- **Auto-selected:** FLASHINFER (vLLM detects T4 compute capability 7.5)
- **DO NOT manually specify** `--attention-backend` flag
- FlashAttention 2 requires compute capability ≥ 8.0 (A100, A10G)
- Tesla T4 (7.5) incompatible with FA2

**Readiness Probe:**
- `initialDelaySeconds: 180` **required**
- CUDA graph compilation takes ~2-3 minutes
- Without delay: pod crashes before initialization completes
- Default 30s timeout insufficient for vLLM startup

**Tool Calling Configuration:**
- `--enable-auto-tool-choice`: Enables automatic tool selection
- `--tool-call-parser=granite`: Granite-specific JSON format
- `--chat-template=/app/data/template/tool_chat_template_granite.jinja`: Custom Jinja2 template
- Template mounted from ConfigMap at `/app/data/template/`
- Granite uses different tokenization format vs Llama (`<|start_of_role|>`, `<|end_of_role|>`, `<|end_of_text|>`)

**Service Endpoints:**
```
# Granite LLM (8B quantized, tool calling)
https://granite-llm-predictor.ai-models-service.svc.cluster.local:8443

# Granite Embedding (768-dim vectors)
https://granite-embedding-predictor.ai-models-service.svc.cluster.local:8443
```

**ArgoCD Management:**
- **ApplicationSet**: `ai-models-service` (in `cluster-ai` base)
- **Application**: `ai-models-service` (auto-generated)
- **Source path**: `components/ai-models-service/overlays/default`
- **Replaces**: Former `ai-embedding-service` and `uc-llamastack` Applications

**GPU Requirements:**
- Tesla T4 GPUs (compute capability 7.5)
- `--dtype=half` for float16 precision (bfloat16 not supported)
- GPU nodes provisioned via MachineAutoscaler (g4dn.12xlarge)

**Node Scheduling:**
- Tolerations for `nvidia.com/gpu` taint
- Scheduled on GPU-enabled worker nodes

**Troubleshooting:**

**Common Issues:**

1. **Quantization format mismatch (compressed-tensors vs AWQ):**
   ```
   pydantic_core._pydantic_core.ValidationError: 1 validation error for ModelConfig
   Value error, Quantization method specified in the model config (compressed-tensors) 
   does not match the quantization method specified in the `quantization` argument (awq).
   ```
   **Solution:** Remove `--quantization=awq` argument, let vLLM auto-detect from model config
   **Root cause:** Granite 3.1 quantized uses compressed-tensors format, not AWQ
   **Fix commit:** d5d53f3

2. **CUDA Out of Memory during model loading (full precision):**
   ```
   torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 200.00 MiB. 
   GPU 0 has a total capacity of 14.56 GiB of which 178.81 MiB is free.
   ```
   **Solution:** Use quantized model instead of full precision
   - Switch from `granite-3.3-8b-instruct` to `granite-3.1-8b-instruct-quantized.w4a16`
   - **OR** Use tensor parallelism with 2 GPUs (`--tensor-parallel-size=2`)
   **Root cause:** Granite 8B FP16 requires ~16 GB VRAM, T4 has only 14.56 GiB

3. **CUDA Out of Memory during warmup (sampler):**
   ```
   RuntimeError: CUDA out of memory occurred when warming up sampler with 256 dummy requests.
   ```
   **Solution:** Reduce `--gpu-memory-utilization` to 0.80 and add `--max-num-seqs=128`

4. **FlashAttention 2 incompatibility:**
   ```
   ERROR: Cannot use FA version 2 is not supported due to FA2 is only supported on devices with compute capability >= 8
   ```
   **Solution:** Remove any `--attention-backend` flags, let vLLM auto-select FLASHINFER

5. **Chat template not found:**
   ```
   ValueError: The supplied chat template string (/app/data/template/...) appears path-like, but doesn't exist!
   ```
   **Solution:** Ensure ConfigMap mounted to ServingRuntime at `/app/data/template/`

6. **Pod CrashLoopBackOff before ready:**
   **Solution:** Add `readinessProbe.initialDelaySeconds: 180` to ServingRuntime

#### PostgreSQL Connection Secret

**Pattern**: Static Secret with pgvector connection details for LlamaStack

**Namespace**: `llamastack`

**File**: `llamastack-secret-pgvector-connection.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  annotations:
    # gitleaks:allow - Demo/lab environment placeholder credentials
    security.internal/credential-type: demo-placeholder
  name: pgvector-connection
  namespace: llamastack
stringData:
  # gitleaks:allow - Demo/lab environment placeholder credentials
  PGVECTOR_HOST: llamastack-postgresql.external-db-llamastack.svc.cluster.local
  PGVECTOR_PORT: "5432"
  # gitleaks:allow - Demo/lab environment placeholder credentials
  PGVECTOR_DB: llamastackdb
  # gitleaks:allow - Demo/lab environment placeholder credentials
  PGVECTOR_USER: llamastack
  # gitleaks:allow - Demo/lab environment placeholder credentials
  PGVECTOR_PASSWORD: changeme-demo-only
```

**Purpose:** Provides PostgreSQL connection details for LlamaStack RAG operations with pgvector extension.

**Required Environment Variables:**
- `PGVECTOR_HOST` - PostgreSQL service hostname (cluster-internal)
- `PGVECTOR_PORT` - PostgreSQL port (5432)
- `PGVECTOR_DB` - Database name
- `PGVECTOR_USER` - Database user
- `PGVECTOR_PASSWORD` - Database password

**Security:**
- Demo credentials marked with `# gitleaks:allow`
- `security.internal/credential-type: demo-placeholder` annotation
- For production: use external secret management (Vault, AWS Secrets Manager)

**Verification:**
```bash
oc get secret pgvector-connection -n llamastack
# Expected: Opaque secret with 5 data keys
```

#### LlamaStackDistribution

**Pattern**: rh-dev distribution with environment-based provider configuration and persistent storage

**Namespace**: `llamastack`

**Status**: ✅ ACTIVE (deployed and operational)

```yaml
# llamastack-llamastackdistribution-llamastack.yaml
apiVersion: llamastack.io/v1alpha1
kind: LlamaStackDistribution
metadata:
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  name: llamastack
  namespace: llamastack
spec:
  replicas: 1
  server:
    containerSpec:
      env:
      - name: EMBEDDING_MODEL
        value: granite-embedding-english-r2
      - name: EMBEDDING_PROVIDER_MODEL_ID
        value: ibm-granite/granite-embedding-english-r2
      - name: INFERENCE_MODEL
        value: granite-3.3-2b-instruct
      - name: POSTGRES_DB
        value: llamastackdb
      - name: POSTGRES_HOST
        value: llamastack-postgresql.external-db-llamastack.svc.cluster.local
      - name: POSTGRES_PASSWORD
        valueFrom:
          secretKeyRef:
            key: POSTGRES_PASSWORD
            name: postgres-secret
      - name: POSTGRES_PORT
        value: "5432"
      - name: POSTGRES_USER
        value: llamastack
      - name: VLLM_EMBEDDING_API_TOKEN
        value: ""
      - name: VLLM_EMBEDDING_MAX_TOKENS
        value: "512"
      - name: VLLM_EMBEDDING_TLS_VERIFY
        value: "false"
      - name: VLLM_EMBEDDING_URL
        value: https://granite-embedding-predictor.ai-models-service.svc.cluster.local:8443/v1
      - name: VLLM_TLS_VERIFY
        value: "false"
      - name: VLLM_URL
        value: https://granite-llm-predictor.ai-models-service.svc.cluster.local:8443/v1
      port: 8321
      resources:
        limits:
          cpu: "2"
          memory: 4Gi
        requests:
          cpu: 500m
          memory: 2Gi
    distribution:
      name: rh-dev
    storage:
      size: 20Gi
```

**⚠️ CRITICAL: Embedding Configuration is REQUIRED**

The `rh-dev` distribution includes pre-registered models that require the `vllm-embedding` provider. **Omitting embedding configuration causes pod crash:**

```
ValueError: Provider `vllm-embedding` not found
```

**All embedding-related environment variables are MANDATORY:**
- `EMBEDDING_MODEL` - Model identifier (granite-embedding-english-r2)
- `EMBEDDING_PROVIDER_MODEL_ID` - Full model path (ibm-granite/granite-embedding-english-r2)
- `VLLM_EMBEDDING_URL` - Embedding service endpoint
- `VLLM_EMBEDDING_API_TOKEN` - Authentication token (empty string if no auth)
- `VLLM_EMBEDDING_MAX_TOKENS` - Maximum token limit (512)
- `VLLM_EMBEDDING_TLS_VERIFY` - TLS verification setting (false for self-signed certs)

**Configuration Pattern: Environment Variables (Not userConfig)**

Unlike earlier versions, the current deployment uses **environment variables** for provider configuration instead of userConfig ConfigMap. This simplifies deployment and aligns with OpenShift patterns.

**Storage Configuration:**

LlamaStack includes persistent storage for caching and runtime data:
```yaml
storage:
  size: 20Gi
```

Creates PVC `llamastack-pvc` (gp3-csi) mounted at `/app/.llama/` in the pod.

**Model Endpoints:**

```bash
# Inference (Granite 3.3 2B)
https://granite-llm-predictor.ai-models-service.svc.cluster.local:8443/v1

# Embeddings (Granite Embedding English R2)
https://granite-embedding-predictor.ai-models-service.svc.cluster.local:8443/v1
```

**Status Check:**
```bash
oc get llamastackdistribution llamastack -n llamastack
# Conditions: DeploymentReady=True, ServiceReady=True, HealthCheck=True

oc get pod -n llamastack
# llamastack-xxxxx  1/1  Running
```

**Provided APIs:**
- agents, batches, datasetio, eval, inference
- safety, scoring, tool_runtime, vector_io, files

**Known Issue: Unauthorized Warnings**

LlamaStack logs show periodic "Unauthorized" warnings when refreshing model lists:
```
WARNING  Model refresh failed for provider vllm-inference: Unauthorized
WARNING  Model refresh failed for provider vllm-embedding: Unauthorized
```

**Impact**: None - warnings are cosmetic. LlamaStack remains functional and healthy. Auth tokens are empty because KServe InferenceServices use service account tokens, not API keys.

**Documentation Issue:**

Red Hat documentation (RHOAI 3.3) does NOT clearly state that embedding configuration is required for rh-dev distribution. See JIRA bug report for details.

**Files:**
```
components/uc-llamastack/base/
├── llamastack-llamastackdistribution-llamastack.yaml  # Main distribution CR
├── llamastack-secret-postgres-secret.yaml             # PostgreSQL password
├── llamastack-configmap-granite-chat-template.yaml    # Granite tool calling template
└── (additional supporting resources)
```

**Version Management:**

Operator channel managed via `cluster-versions` ConfigMap:
- `rhoai: "stable-3.3"` (ConfigMap - actual deployed version)
- Subscription fallback: `stable-3.x` (generic channel for future upgrades)

**Installation**: Part of the `ai` gitops-base, deployed in profiles: `ocp-ai`, `ocp-standard`, etc.
## Leader Worker Set Operator

**Purpose**: Provides an API for deploying a group of pods as a unit of replication, addressing AI/ML inference workloads deployment patterns, especially multi-host inference where LLMs are sharded across multiple devices.

**Installation**: Deployed in `openshift-lws-operator` namespace. Included in AI-focused profiles.

**Namespace**: `openshift-lws-operator`

**Key Components:**

### LeaderWorkerSetOperator CR

The cluster-scoped LeaderWorkerSetOperator CR controls the operator lifecycle:

```yaml
# components/leader-work-set/base/cluster-leaderworkersetoperator-cluster.yaml
apiVersion: operator.openshift.io/v1
kind: LeaderWorkerSetOperator
metadata:
  name: cluster
spec:
  logLevel: Normal
  operatorLogLevel: Normal
```

**Available Fields:**
- `logLevel`: Component logging level (Normal, Debug, Trace, TraceAll)
- `operatorLogLevel`: Operator logging level (Normal, Debug, Trace, TraceAll)
- `managementState`: Operator management state (Managed, Unmanaged, Force, Removed)
- `observedConfig`: Sparse config observed from cluster state
- `unsupportedConfigOverrides`: Override final configuration (unsupported, blocks upgrades)

**Managed Resources:**
- **lws-controller-manager**: Deployment managing LeaderWorkerSet resources
  - Replicas: 2 (high availability)
  - Image: `registry.redhat.io/leader-worker-set/lws-rhel9`

### Known Limitation: Infra Node Placement

**Issue**: The LeaderWorkerSetOperator CR does NOT support nodeSelector or tolerations configuration for the lws-controller-manager deployment.

**Impact:**
- Operator Subscription pod correctly uses infra nodeSelector/tolerations (configured in Subscription spec.config)
- lws-controller-manager deployment pods run on worker nodes instead of infra nodes
- Prevents following OpenShift best practices for infrastructure workload separation

**Tracking:**
- **JIRA**: [RHOAIENG-55981](https://issues.redhat.com/browse/RHOAIENG-55981) - "LeaderWorkerSetOperator - Add nodeSelector and tolerations configuration"
- **Status**: Open - Feature Request
- **Detailed Documentation**: `JIRA-LeaderWorkerSet-InfraNodes.md`
- **Also Tracked In**: `KNOWN_LIMITATIONS.md` - Operator Pod Placement on Infra Nodes

**Requested API Enhancement:**
```yaml
apiVersion: operator.openshift.io/v1
kind: LeaderWorkerSetOperator
metadata:
  name: cluster
spec:
  logLevel: Normal
  operatorLogLevel: Normal
  nodePlacement:  # Requested feature (not currently available)
    nodeSelector:
      node-role.kubernetes.io/infra: ''
    tolerations:
    - key: node-role.kubernetes.io/infra
      operator: Exists
```

**Current Workarounds:**
- ❌ Manual deployment patching: Reverted by operator reconciliation
- ❌ unsupportedConfigOverrides: Blocks cluster upgrades, unsupported

**Verification:**
```bash
# Check current pod placement
oc get pods -n openshift-lws-operator -o wide

# Check node roles
oc get node <node-name> --show-labels | grep node-role

# Expected: lws-controller-manager pods on worker nodes (limitation)
# Expected: openshift-lws-operator pod on infra node (correct)
```

### LeaderWorkerSet API (Workload CRD)

The LeaderWorkerSet API (separate from the operator CR) is used to deploy AI/ML workloads:

**CRD**: `leaderworkersets.leaderworkerset.x-k8s.io`

**Purpose**: Deploys pods grouped into units with one leader and multiple workers, ideal for:
- Multi-host LLM inference (model sharding across GPUs)
- Distributed training workloads
- Leader-worker patterns with coordinated scaling

**Example Use Case**: Deploy a sharded LLM across 4 GPUs on 2 nodes
```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: llm-inference
  namespace: ai-workloads
spec:
  replicas: 2  # 2 groups (leader + workers)
  leaderWorkerTemplate:
    size: 2  # 2 pods per group (1 leader + 1 worker)
    leaderTemplate:
      spec:
        containers:
        - name: llm-leader
          # Leader pod configuration
    workerTemplate:
      spec:
        containers:
        - name: llm-worker
          # Worker pod configuration
```

**Documentation**: See [Red Hat OpenShift AI workloads - Leader Worker Set Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/ai_workloads/leader-worker-set-operator)

**Version Management:**

Operator channel managed via `cluster-versions` ConfigMap:
- `lws: "stable-v1.0"` (ConfigMap - actual deployed version)
- Subscription: `leader-worker-set` (package name in Red Hat Operators catalog)

**Installation**: Part of the `ai` gitops-base, deployed in profiles: `ocp-ai`, `ocp-reference`

**Configuration Status**: Re-enabled as of 2026-04-07 (previously disabled for testing). Deployed with known API limitation for controller-manager pod placement (see above).

## AI Embedding Service

**Purpose**: Shared infrastructure for generating text embeddings using the granite-embedding-english-r2 model. Provides 768-dimensional vector representations for semantic search and RAG applications.

**Pattern**: Shared service architecture - One GPU serving multiple consumers across namespaces.

**Namespace**: `ai-embedding-service`

**Key Components:**

### Shared Service Architecture

**Design Decision**: Deployed as a shared service rather than per-application deployment.

**Benefits**:
- **Resource Efficiency**: One GPU serves multiple workloads (pipelines, applications)
- **Separation of Concerns**: Infrastructure isolated from applications
- **Independent Lifecycle**: Model updates don't require application redeployment
- **Cost Optimization**: Reduced GPU allocation for demo/lab environments

**Consumers**:
- `uc-ai-generation-llm-rag` - RAG pipeline embedding generation
- `uc-llamastack` - Future embedding integration
- Custom applications via RBAC grants

### InferenceService: granite-embedding

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: granite-embedding
  namespace: ai-embedding-service
  annotations:
    opendatahub.io/model-type: embedding
    security.opendatahub.io/enable-auth: "true"
spec:
  predictor:
    model:
      args:
      - --dtype=half
      - --max-model-len=8192
      - --gpu-memory-utilization=0.70
      modelFormat:
        name: vLLM
      runtime: granite-embedding
      storageUri: oci://quay.io/redhat-ai-services/modelcar-catalog:granite-embedding-english-r2
      resources:
        limits:
          nvidia.com/gpu: "1"
          memory: 12Gi
```

**Model Specifications**:
- **Model**: granite-embedding-english-r2
- **Parameters**: 149M
- **Embedding Dimension**: 768
- **Max Context Length**: 8192 tokens
- **Runtime**: vLLM (optimized for batch inference)
- **Hardware**: NVIDIA Tesla T4 GPU (typical)

### ServiceAccount and Token Authentication

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: granite-embedding-sa
  namespace: ai-embedding-service
---
apiVersion: v1
kind: Secret
metadata:
  name: granite-embedding-sa-token
  namespace: ai-embedding-service
  annotations:
    kubernetes.io/service-account.name: granite-embedding-sa
type: kubernetes.io/service-account-token
```

**Why ServiceAccount Token Secret**:
- KServe InferenceServices require bearer token authentication
- ServiceAccount tokens provide secure, namespace-scoped access
- Secret type `kubernetes.io/service-account-token` auto-generates long-lived token
- Required annotation links Secret to ServiceAccount

**Note**: Long-lived tokens are acceptable for service-to-service communication in trusted cluster environments.

### Cross-Namespace RBAC

**Pattern**: Grant access to consumer namespaces via Role + RoleBinding.

```yaml
# Role in ai-embedding-service namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: inferenceservice-user
  namespace: ai-embedding-service
rules:
- apiGroups: [serving.kserve.io]
  resources: [inferenceservices]
  verbs: [get, list]
---
# RoleBinding grants access to consumer ServiceAccounts
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: allow-pipeline-access
  namespace: ai-embedding-service
roleRef:
  kind: Role
  name: inferenceservice-user
subjects:
- kind: ServiceAccount
  name: default  # Consumer's default ServiceAccount
  namespace: ai-generation-llm-rag  # Consumer's namespace
- kind: ServiceAccount
  name: pipeline-runner-pipelines  # CRITICAL: Pipeline pods use this SA, not default
  namespace: ai-generation-llm-rag
```

**CRITICAL**: Pipeline pods in RHOAI use ServiceAccount `pipeline-runner-pipelines`, NOT `default`. Both ServiceAccounts must be granted access to prevent 403 Forbidden errors during pipeline execution.

**When to Grant Access**:
- Create separate RoleBinding for each consumer namespace
- Include ALL ServiceAccounts used by consumer workloads (default + pipeline-runner-pipelines for DSPA namespaces)
- Use minimal permissions (get, list only - no create/update/delete)
- Consumer ServiceAccount uses its own token (automatic Kubernetes injection)

### Internal Service Endpoint

**URL**: `https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443`

**Why Internal Service**:
- No external Route needed (cluster-internal traffic only)
- Automatic mTLS via KServe service mesh
- ServiceAccount token authentication
- Lower latency (no ingress/egress overhead)

**API Endpoint**: `/v1/embeddings` (OpenAI-compatible)

**Example Request**:
```python
import requests

# Read ServiceAccount token (auto-mounted in pods)
with open('/var/run/secrets/kubernetes.io/serviceaccount/token', 'r') as f:
    token = f.read().strip()

response = requests.post(
    "https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443/v1/embeddings",
    headers={"Authorization": f"Bearer {token}"},
    json={
        "input": ["Text to embed", "Another text"],
        "model": "granite-embedding"
    },
    verify=False  # Self-signed cert for internal service
)

embeddings = [item['embedding'] for item in response.json()['data']]
# Each embedding is a list of 768 floats
```

### ServingRuntime Configuration

```yaml
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: granite-embedding
  namespace: ai-embedding-service
spec:
  supportedModelFormats:
  - name: vllm
    version: "1"
  containers:
  - name: kserve-container
    image: quay.io/modh/vllm@sha256:...
    args:
    - --model=/mnt/models
    - --port=8080
    - --task=embed
    # Additional vLLM args passed from InferenceService
```

**Key Configuration**:
- **Task**: `embed` (embedding generation, not text generation)
- **Port**: 8080 (KServe standard)
- **Image**: Red Hat-supported vLLM container
- **GPU**: Required for production performance

### Verification

```bash
# Check InferenceService status
oc get inferenceservice granite-embedding -n ai-embedding-service

# Check pods
oc get pods -n ai-embedding-service

# Test embedding generation (from a pod in consumer namespace)
oc exec -n ai-generation-llm-rag <pod-name> -- python3 -c "
import requests
token = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
r = requests.post(
    'https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443/v1/embeddings',
    headers={'Authorization': f'Bearer {token}'},
    json={'input': ['test'], 'model': 'granite-embedding'},
    verify=False
)
print(f'Embedding dimension: {len(r.json()[\"data\"][0][\"embedding\"])}')
"
```

**Expected Output**: `Embedding dimension: 768`

### Performance Characteristics

**Throughput**:
- Single request: ~10ms per embedding (GPU)
- Batch request (32 texts): ~100ms total (~3ms per embedding)
- **Recommendation**: Batch 16-64 texts per request for optimal GPU utilization

**Resource Usage**:
- GPU Memory: ~4GB (model weights) + variable (inference)
- System Memory: ~12GB total
- vCPU: 500m request, 2 core limit

**Scaling**:
- Current: Single replica (sufficient for demo/lab)
- Production: HPA based on GPU utilization or request latency
- Multi-replica: Load balanced via KServe service mesh

### Installation

**GitOps Base**: `ai` (in `gitops-bases/ai/ai-embedding-service-appset.yaml`)

**Profiles**: `ocp-ai`, `ocp-standard`, `ocp-reference`

**Dependencies**:
- Red Hat OpenShift AI Operator (for KServe/ServingRuntime)
- GPU operator (for NVIDIA GPU support)
- Service Mesh (for mTLS)

**Version Management**: InferenceService uses OCI image tag from Red Hat AI Services model catalog.

---

## UC AI Generation LLM RAG

**Purpose**: Complete RAG (Retrieval-Augmented Generation) pipeline infrastructure for document processing, embedding generation, and vector storage.

**Pattern**: Two-stage pipeline architecture with shared external resources.

**Namespaces**:
- `ai-generation-llm-rag` - DSPA and pipeline execution
- `external-db-generation-llm-rag` - External databases (MariaDB, PostgreSQL)

**Key Components:**

### Two-Stage RAG Pipeline Architecture

**Design Decision**: Separate document processing from embedding generation/storage.

**Stage 1: chunk-data Pipeline**
- **Purpose**: Convert PDFs to semantic chunks using Docling
- **Input**: PDF files (URL or S3)
- **Output**: `*_chunks.jsonl` files in Minio storage
- **Steps**:
  1. Import PDFs (download from URL or S3)
  2. Download Docling models (layout analysis, OCR)
  3. Split PDFs for parallel processing
  4. Convert PDFs to JSON/Markdown (Docling)
  5. Chunk documents into semantic units

**Stage 2: convert-store-embeddings Pipeline**
- **Purpose**: Generate embeddings and store in pgvector
- **Input**: Chunks directory from Stage 1
- **Output**: Embeddings stored in PostgreSQL `document_chunks` table
- **Steps**:
  1. Collect all `*_chunks.jsonl` files
  2. Generate 768-dim embeddings (granite-embedding service)
  3. Store in PostgreSQL with HNSW indexing

**Why Two Stages**:
- ✅ Stage 1 is from upstream opendatahub-io/data-processing (don't modify 1050-line compiled YAML)
- ✅ Stage 2 is modular and reusable (works with any chunk JSONL input)
- ✅ Independent testing and deployment
- ✅ Can chain manually or automate with workflow orchestration

### Pipeline: chunk-data

**Full Name**: `chunk-data` (formerly `data-processing-docling-standard-pipeline`)

**Source**: Based on [opendatahub-io/data-processing](https://github.com/opendatahub-io/data-processing/tree/main/kubeflow-pipelines/docling-standard)

**ConfigMap**: `pipeline-chunk-data` (1050-line KFP v2 YAML)

**Parameters**:
```yaml
num_splits: 3  # Number of parallel processing splits
pdf_filenames: "doc1.pdf,doc2.pdf,doc3.pdf"
pdf_base_url: "https://example.com/pdfs"
pdf_from_s3: false

# Docling conversion parameters
docling_pdf_backend: "dlparse_v4"
docling_table_mode: "accurate"
docling_ocr: true
docling_num_threads: 4

# Chunking parameters (REQUIRED for RAG)
docling_chunk_enabled: true
docling_chunk_max_tokens: 512
docling_chunk_merge_peers: true
```

**Critical Parameter**: `docling_chunk_enabled: true` - MUST be enabled for RAG workflow.

**Output Artifact**: Chunks stored in ODF NooBaa S3 at `minio://mlpipeline/v2/artifacts/{run_id}/for-loop-1/output_path` (KFP v2 URI scheme - actual backend is ObjectBucketClaim `pipeline-artifacts`)

### Pipeline: convert-store-embeddings

**Full Name**: `convert-store-embeddings` (formerly `rag-embedding-storage-pipeline`)

**Source**: Custom pipeline created for this project (see `/tmp/rag_embedding_storage_pipeline.py`)

**ConfigMap**: `pipeline-convert-store-embeddings` (495-line KFP v2 YAML)

**Parameters**:
```yaml
# Input from Stage 1
chunks_directory: ""  # Path to chunk output from chunk-data pipeline

# Embedding service configuration
embedding_endpoint: "https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443"
embedding_batch_size: 32  # Chunks per API call (optimize for GPU)

# PostgreSQL + pgvector configuration
postgres_host: "rag-postgresql.external-db-generation-llm-rag.svc.cluster.local"
postgres_port: 5432
postgres_database: "ragdb"
postgres_user: "raguser"
postgres_password: ""  # From Secret
postgres_table_name: "document_chunks"
```

**Components**:
1. **collect-chunks**: Merge all `*_chunks.jsonl` files into single dataset
2. **generate-embeddings**: Batch generate 768-dim vectors via granite-embedding
3. **store-in-pgvector**: Insert into PostgreSQL with HNSW index

**Output**: Embeddings stored in `document_chunks` table with cosine similarity indexing.

### PostgreSQL + pgvector Database

**Deployment**: `rag-postgresql` in `external-db-generation-llm-rag` namespace

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-postgresql
  namespace: external-db-generation-llm-rag
spec:
  template:
    spec:
      containers:
      - name: postgresql
        image: pgvector/pgvector:pg16
        env:
        - name: POSTGRES_DB
          value: ragdb
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: rag-postgresql-credentials
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: rag-postgresql-credentials
              key: POSTGRES_PASSWORD
        lifecycle:
          postStart:
            exec:
              command:
              - /bin/bash
              - -c
              - |
                until pg_isready -U raguser -d ragdb; do sleep 1; done
                psql -U raguser -d ragdb -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

**Key Features**:
- **Image**: `pgvector/pgvector:pg16` (PostgreSQL 16 with pgvector pre-installed)
- **Extension**: pgvector 0.8.2 (auto-initialized via lifecycle hook)
- **Storage**: 10Gi PVC (gp3-csi on AWS)
- **Credentials**: Secret replicated to both namespaces

**Why External Namespace**:
- Databases outlive pipeline runs (persistent storage)
- Shared across multiple pipeline instances
- Clear separation of data tier from compute tier

### Document Chunks Table Schema

```sql
CREATE TABLE document_chunks (
    id SERIAL PRIMARY KEY,
    text TEXT NOT NULL,
    embedding vector(768) NOT NULL,
    source VARCHAR(1024),
    chunk_index INTEGER,
    metadata JSONB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- HNSW index for fast cosine similarity search
CREATE INDEX document_chunks_embedding_idx
ON document_chunks USING hnsw (embedding vector_cosine_ops);
```

**Index Type**: HNSW (Hierarchical Navigable Small World)
- **Performance**: Sub-second search on 100K+ vectors
- **Distance Metric**: Cosine similarity (best for embeddings)
- **Build Time**: Minimal (optimized for inserts)

### Pipeline Upload Jobs

**Pattern**: PostSync ArgoCD hooks that upload pipelines to DSPA.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: upload-pipeline-chunk-data
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      initContainers:
      - name: fetch-pipeline
        image: registry.redhat.io/openshift4/ose-cli:latest
        command:
        - /bin/bash
        - -c
        - |
          oc get configmap pipeline-chunk-data -n ai-generation-llm-rag \
            -o jsonpath='{.data.pipeline\.yaml}' > /pipeline/pipeline.yaml
      containers:
      - name: upload-pipeline
        image: registry.access.redhat.com/ubi9/python-311:latest
        command:
        - python3
        - /scripts/upload-pipeline.py
```

**Upload Script Features**:
- Extracts pipeline name from YAML `pipelineInfo.name` field
- Calculates SHA256 hash of pipeline YAML
- Creates versioned uploads: `v-{hash}` (e.g., `v-678e27c67458`)
- Idempotent: Skips upload if version already exists
- Handles both KFP API response formats (`versions` and `pipeline_versions`)

**Upload Flow**:
1. ArgoCD syncs → PostSync hook triggers Job
2. Init container fetches pipeline YAML from ConfigMap
3. Main container uploads to DSPA API with ServiceAccount token
4. Pipeline appears in RHOAI Data Science Pipelines UI

### Cross-Namespace Resource Access

**Pattern**: Secret replication for database credentials.

```yaml
# Original Secret in external-db-generation-llm-rag
apiVersion: v1
kind: Secret
metadata:
  name: rag-postgresql-credentials
  namespace: external-db-generation-llm-rag
stringData:
  POSTGRES_DB: ragdb
  POSTGRES_USER: raguser
  POSTGRES_PASSWORD: changeme-demo-only

---
# Replicated Secret in ai-generation-llm-rag
apiVersion: v1
kind: Secret
metadata:
  name: rag-postgresql-credentials
  namespace: ai-generation-llm-rag
stringData:
  POSTGRES_DB: ragdb
  POSTGRES_USER: raguser
  POSTGRES_PASSWORD: changeme-demo-only
```

**Why Replication**:
- Pipeline tasks run in `ai-generation-llm-rag` namespace
- Cannot reference Secrets across namespaces in pod specs
- GitOps manages both copies (single source of truth in Git)

**Security Note**: Demo credentials only. Production should use AWS Secrets Manager or Vault.

### ODF Object Storage (ObjectBucketClaim)

**Pattern**: Use ODF NooBaa for pipeline artifact storage instead of embedded Minio.

```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: pipeline-artifacts
  namespace: ai-generation-llm-rag
spec:
  bucketName: ai-generation-llm-rag-pipelines
  storageClassName: openshift-storage.noobaa.io
```

**Auto-Generated Resources**:
- **Secret**: `pipeline-artifacts` - Contains `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`
- **ConfigMap**: `pipeline-artifacts` - Contains `BUCKET_HOST`, `BUCKET_NAME`, `BUCKET_PORT`
- **ObjectBucket**: `obc-ai-generation-llm-rag-pipeline-artifacts` - Backing NooBaa bucket

**DSPA Configuration**:
```yaml
spec:
  objectStorage:
    externalStorage:
      host: s3.openshift-storage.svc
      port: "443"
      bucket: "ai-generation-llm-rag-pipelines"
      scheme: https
      s3CredentialsSecret:
        accessKey: AWS_ACCESS_KEY_ID
        secretKey: AWS_SECRET_ACCESS_KEY
        secretName: pipeline-artifacts
```

**Why ODF OBC vs Embedded Minio**:
- ✅ Production-ready storage (ODF-backed)
- ✅ Auto-scaling with NooBaa
- ✅ S3-compatible API (no vendor lock-in)
- ✅ Separate lifecycle from DSPA (data persists across DSPA redeploys)
- ✅ Credentials auto-managed by OBC operator

**Important**: KFP v2 artifact URIs use `minio://mlpipeline/` prefix (protocol scheme) regardless of actual backend. This is **not** embedded Minio - the backend is ODF NooBaa S3-compatible storage.

**Verification**:
```bash
# Check OBC status
oc get obc pipeline-artifacts -n ai-generation-llm-rag

# Check auto-generated Secret
oc get secret pipeline-artifacts -n ai-generation-llm-rag -o jsonpath='{.data}' | jq 'keys'

# Verify DSPA is using ODF endpoint
oc get pod -n ai-generation-llm-rag -l app=ds-pipeline-pipelines -o name | head -1 | \
  xargs oc exec -n ai-generation-llm-rag -- env | grep OBJECTSTORECONFIG_HOST
# Expected: OBJECTSTORECONFIG_HOST=s3.openshift-storage.svc
```

### RBAC: Pipeline ConfigMap Access

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pipeline-configmap-reader
  namespace: ai-generation-llm-rag
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames:
  - pipeline-chunk-data
  - pipeline-convert-store-embeddings
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pipeline-configmap-reader
  namespace: ai-generation-llm-rag
subjects:
- kind: ServiceAccount
  name: pipeline-uploader
  namespace: openshift-gitops
```

**Purpose**: Upload Jobs read pipeline YAML from ConfigMaps before uploading to DSPA.

### Verification

```bash
# Check DSPA status
oc get dspa pipelines -n ai-generation-llm-rag

# Check PostgreSQL
oc exec -n external-db-generation-llm-rag deployment/rag-postgresql -- \
  psql -U raguser -d ragdb -c "\dx vector"

# Check pipelines uploaded
oc exec -n ai-generation-llm-rag deployment/ds-pipeline-pipelines -c ds-pipeline-api-server -- \
  bash -c "TOKEN=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) && \
  curl -sk -H 'Authorization: Bearer \$TOKEN' \
  https://localhost:8443/apis/v2beta1/pipelines | python3 -m json.tool"

# Check upload Jobs
oc get job -n openshift-gitops | grep upload-pipeline

# Query stored embeddings (after pipeline runs)
oc exec -n external-db-generation-llm-rag deployment/rag-postgresql -- \
  psql -U raguser -d ragdb -c "SELECT COUNT(*), AVG(ARRAY_LENGTH(embedding::real[], 1)) AS avg_dim FROM document_chunks;"
```

### Installation

**GitOps Base**: `ai` (in `gitops-bases/ai/uc-ai-generation-llm-rag-appset.yaml`)

**Profiles**: `ocp-ai`, `ocp-standard`, `ocp-reference`

**Dependencies**:
- Red Hat OpenShift AI Operator (for DSPA)
- AI Embedding Service (for embedding generation)
- OpenShift GitOps (for pipeline upload Jobs)

**External Dependencies**:
- MariaDB: DSPA metadata storage (in `external-db-generation-llm-rag` namespace)
- PostgreSQL + pgvector: Vector storage (in `external-db-generation-llm-rag` namespace)

### Related Documentation

See `docs/claude/rag-retrieval-guide.md` for:
- Complete RAG retrieval flow
- Semantic search examples
- Integration with LLM applications
- Production optimization guidelines

### Known Issues and Fixes

#### chunk-data Pipeline: HuggingFace Cache Permission Error (FIXED)

**Issue**: Pipeline fails with `PermissionError` when downloading tokenizer models.

**Root Cause**:
- Red Hat Docling image sets `HF_HOME=/tmp/`
- OpenShift pods run as non-root with restricted `/tmp/` write access
- Pipeline tries to download `sentence-transformers/all-MiniLM-L6-v2` → Permission denied

**Fix Applied** (2 parts):

**Part 1: RHOAI KFP v2 Compatibility** (commit `04cde66`):
```yaml
# CORRECT: env in executor container spec
executors:
  exec-docling-chunk:
    container:
      env:
      - name: HF_HOME
        value: /.cache
      image: registry.redhat.io/rhai/docling-cuda-rhel9:3.2.1
```

**Why**: RHOAI's KFP v2 implementation doesn't support env in `platforms.kubernetes.deploymentSpec.executors`. Environment variables must be in the executor's container spec.

**Error without fix**: `failed to unmarshal kubernetes config: proto: (line 1:2): unknown field "env"`

**Part 2: Correct Cache Path** (commit `d254ba6`):
```yaml
env:
- name: HF_HOME
  value: /.cache  # CORRECT: Actual DSPA mount point
```

**Why**: DSPA mounts `dot-cache-scratch` volume at `/.cache` in the container, not `/mainctrfs/.cache`.

**Error without fix**: `PermissionError: [Errno 13] Permission denied: '/mainctrfs'`

**Verification**:
```bash
# Check volume mount in pipeline pod
oc get pod <pod> -o jsonpath='{.spec.containers[?(@.name=="main")].volumeMounts}' | jq '.[] | select(.name=="dot-cache-scratch")'
# Output: {"mountPath": "/.cache", "name": "dot-cache-scratch"}
```

**Status**: ✅ Fixed and tested successfully (2026-04-10)
- Pipeline run: chunk-data-6ckcz
- Duration: 5 minutes 24 seconds
- All 8 test PDFs converted and chunked successfully

#### convert-store-embeddings Pipeline: 403 Forbidden from Embedding Service (FIXED)

**Issue**: Pipeline fails at generate-embeddings stage with HTTP 403 Forbidden when calling granite-embedding InferenceService.

**Root Cause**:
- Pipeline pods run with ServiceAccount `pipeline-runner-pipelines` (not `default`)
- RoleBinding `allow-pipeline-access` only granted access to `default` ServiceAccount
- Result: Pipeline pods have no RBAC to access InferenceService in ai-embedding-service namespace

**Error Message**:
```
403 Client Error: Forbidden for url: https://granite-embedding-predictor.ai-embedding-service.svc.cluster.local:8443/v1/embeddings
```

**Fix Applied** (commit `eae505d`):

Updated `ai-embedding-service-rb-allow-pipeline-access.yaml` to include both ServiceAccounts:
```yaml
subjects:
- kind: ServiceAccount
  name: default
  namespace: ai-generation-llm-rag
- kind: ServiceAccount
  name: pipeline-runner-pipelines  # ADDED
  namespace: ai-generation-llm-rag
```

**Why Both ServiceAccounts Are Needed**:
- `default`: Used by some DSPA components and custom pods
- `pipeline-runner-pipelines`: Used by KFP v2 pipeline execution pods
- Cannot assume which SA a workload will use - grant both for complete coverage

**Investigation Commands**:
```bash
# Check which ServiceAccount pipeline pods use
oc get pod <pipeline-pod> -n ai-generation-llm-rag -o jsonpath='{.spec.serviceAccountName}'
# Output: pipeline-runner-pipelines

# Verify RoleBinding subjects
oc get rolebinding allow-pipeline-access -n ai-embedding-service -o yaml
```

**Status**: ✅ Fixed and tested successfully (2026-04-10)
- Pipeline run: convert-store-embeddings-8fg6z
- Duration: 4 minutes 16 seconds
- Generated 161 embeddings (768-dim) and stored in PostgreSQL
- Semantic search verified with 0.90 similarity scores

