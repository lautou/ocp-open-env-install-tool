# Component-Specific Configuration

**Purpose**: Detailed configuration patterns and special behaviors for GitOps components.

**Note**: Only components with non-standard patterns or special requirements are documented here. Simple operator deployments without special configuration are intentionally omitted (discoverable via filesystem).

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
         memory: 4Gi  # Increased from default 3Gi
       requests:
         cpu: 250m
         memory: 2Gi  # Increased from default 1Gi
   ```

   **Why 4Gi memory?**
   - Default 3Gi causes OOMKilled crashes (exit code 137) in production clusters
   - Controller manages 25-30+ applications with complex CRDs
   - Memory usage spikes during reconciliation of large ApplicationSets
   - 4Gi provides stable operation with headroom for growth

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

   **Additional ClusterRole Grants**:

   ArgoCD requires explicit RBAC permissions for resources not managed by OLM (Operator Lifecycle Manager). The following ClusterRoles grant the ArgoCD application controller ServiceAccount permissions to manage specific resource types.

   **a) Gateway API Resources** (`components/rhoai/base/cluster-clusterrole-gateway-api-manager.yaml`):

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
   metadata:
     name: gateway-api-manager
   rules:
   - apiGroups:
     - gateway.networking.k8s.io
     resources:
     - gateways
     - gatewayclasses
     - httproutes
     - grpcroutes
     - referencegrants
     verbs:
     - '*'
   ```

   **Why needed:**
   - Gateway API CRDs installed by cluster (not by OLM operator)
   - No OLM-generated aggregate RBAC roles exist
   - Without these permissions, ArgoCD cannot create Gateway resources
   - Affects: RHOAI (MaaS Gateway), RHCL (Kuadrant Gateways)

   **Bound to:** `openshift-gitops-argocd-application-controller` ServiceAccount

   **Location:** Defined in `rhoai` component (co-located with Gateway CR)

   **b) Other Operator-Specific ClusterRoles**:

   Additional ClusterRoles grant permissions for operator-managed resources:
   - `cert-manager-operator`: Manage cert-manager CRs (Certificate, ClusterIssuer)
   - `console-plugin-manager`: Patch Console CR for plugin enablement
   - `cleanup-operator`: Delete installer pods in kube-system
   - `ack-config-operator`: Manage ACK Route53 configuration
   - `gpu-machineset-operator`: Manage GPU MachineSets
   - `maas-gateway-operator`: Read DNS config for MaaS Gateway domain discovery

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
         image: registry.redhat.io/openshift-gitops-1/argocd-rhel8@sha256:e9b0f843...
         # ServiceAccount token auto-mounted at /var/run/secrets/kubernetes.io/serviceaccount/
       volumes:
       - name: cmp-plugin
         configMap:
           name: cmp-plugin  # Plugin definition
   ```

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
- RBAC: `components/cluster-network/base/cluster-clusterrole-manage-network-policies.yaml` (ArgoCD permissions)

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

**Pattern**: Static manifest + ignoreDifferences for shared resource

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
- `ignoreDifferences` prevents ArgoCD from managing OpenShift-controlled fields
- CMP placeholder replaced with actual API domain at build time

**ignoreDifferences in ApplicationSet**:
```yaml
ignoreDifferences:
- group: config.openshift.io
  kind: APIServer
  name: cluster
  jsonPointers:
  - /metadata/annotations     # OpenShift-managed
  - /metadata/ownerReferences # OpenShift-managed
  - /spec/audit               # OpenShift-managed
```

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
spec:
  profile: all                        # Full Tekton components with console integration
  targetNamespace: openshift-pipelines  # Deploy components to standard OpenShift namespace
```

**Why explicit configuration:**
- `profile: all` ensures TektonAddon is installed (console CLI downloads, quick starts, YAML samples)
- `targetNamespace: openshift-pipelines` uses the standard OpenShift namespace (operator default is `tekton-pipelines`)
- Both fields are managed by GitOps (no ignoreDifferences)

**Version Note**: In OpenShift Pipelines 1.20+, the `basic` profile was enhanced to include Tekton Results (previously only in `all` profile).

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

**Pattern**: Dynamic Job with cluster domain injection

Models as a Service requires a Gateway API resource for exposing model endpoints:

```yaml
# Created by: components/rhoai/base/openshift-gitops-job-create-maas-gateway.yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: data-science-gateway-class  # RHOAI's Gateway controller
  listeners:
    - allowedRoutes:
        namespaces:
          from: All  # Cross-namespace routing for model serving
      hostname: maas-api.apps.<cluster-domain>
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - kind: Secret
            name: ingress-certificates  # Let's Encrypt wildcard cert
        mode: Terminate
```

**Job Implementation:**
- Extracts cluster domain from `dns.config.openshift.io/cluster`
- Creates Gateway with dynamically generated hostname
- Uses RHOAI's `data-science-gateway-class` GatewayClass
- References Let's Encrypt certificate created by cert-manager
- Runs with `Force=true` for retriggerable execution

**Gateway Status:**
- Creates AWS ELB LoadBalancer service
- Assigns external hostname: `<uuid>.eu-central-1.elb.amazonaws.com`
- Internal service: `maas-default-gateway-data-science-gateway-class.openshift-ingress.svc.cluster.local:443`
- Supports HTTPRoute and GRPCRoute attachments

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
    maxCount: 8Gi
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

**Installation**: Part of the `ai` gitops-base, deployed in profile: `ocp-ai`
