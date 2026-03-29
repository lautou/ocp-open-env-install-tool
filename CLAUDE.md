# CLAUDE.md

AI context documentation for Claude Code (claude.ai/code) when working with this repository.

## Overview

OpenShift Container Platform (OCP) installation tool for Red Hat Demo Platform AWS Blank Open Environment labs. Automates cluster provisioning on AWS with Day 2 configuration via Profile-Based GitOps architecture.

**Install methods**: IPI (Installer-Provisioned Infrastructure) | UPI (User-Provisioned Infrastructure)

## Documentation Philosophy

**IMPORTANT**: This file = AI context (not human docs - see README.md).

**What gets documented:**
- ✅ Patterns/anti-patterns - Shared resource patterns, Pure Job patterns, failed approaches
- ✅ Non-discoverable knowledge - OLM naming, operator limitations, design rationale
- ✅ Architecture/flows - GitOps "Lego" model, installation sequence, recovery
- ✅ Gotchas/workarounds - Known bugs, limitations, special configs

**What does NOT get documented:**
- ❌ Simple components - Standard operator deployments
- ❌ Discoverable info - Namespace names, channel versions (Read/Glob/Grep)
- ❌ Component catalogs - Complete lists (discoverable via filesystem)
- ❌ Basic usage - User instructions (README.md)

**Rationale**: AI can discover simple info dynamically. Document knowledge that CANNOT be easily discovered.

**Externalized docs**: Complex topics moved to `docs/claude/`:
- **[components.md](docs/claude/components.md)** - Component-specific configuration patterns
- **[jobs.md](docs/claude/jobs.md)** - Job architecture, ArgoCD hooks, development guide (21 Jobs)
- **[monitoring.md](docs/claude/monitoring.md)** - Alertmanager, alert silences, Insights recommendations
- **[known-bugs.md](docs/claude/known-bugs.md)** - False-positive alerts and upstream bugs
- **[installation.md](docs/claude/installation.md)** - Installation flow, session recovery, profiles
- **[security.md](docs/claude/security.md)** - AWS Secrets Manager, Job QoS, tenant isolation
- **[troubleshooting.md](docs/claude/troubleshooting.md)** - Common issues and debugging

**Project audit**: Complete codebase analysis available:
- **[AUDIT.md](AUDIT.md)** - Comprehensive project audit (structure, components, GitOps architecture, Jobs, security, documentation, known issues, recommendations)
  - **Status**: ✅ COMPLETE (2026-03-27) - 🎉 **100% resolution rate (9/9 issues resolved)**
  - **Achievement**: ALL critical/high/medium/low priority issues resolved
  - **Outstanding issues**: 0 - All technical debt eliminated

**Before working on specific topics, read the relevant external doc.**

## YAML Formatting Standards

**CRITICAL**: All Kubernetes YAML manifests and Kustomize files MUST follow alphabetical ordering rules.

### Kustomization Files

**Rule**: `resources`, `components`, and `bases` lists in `kustomization.yaml` files MUST be sorted alphabetically.

```yaml
# ✅ CORRECT
resources:
- ../../common
- cluster-namespace-monitoring.yaml
- monitoring-deployment-app.yaml
- monitoring-service-app.yaml
- monitoring-serviceaccount-app.yaml

# ❌ WRONG
resources:
- ../../common
- monitoring-service-app.yaml
- cluster-namespace-monitoring.yaml
- monitoring-serviceaccount-app.yaml
- monitoring-deployment-app.yaml
```

**Rationale**:
- Easier to find specific resources in lists
- Reduces merge conflicts when adding new resources
- Consistent ordering across the project
- Better maintainability

### Kubernetes Manifests

**Standard field order** (not strictly alphabetical, but conventional):
1. `apiVersion`
2. `kind`
3. `metadata`
4. `spec`
5. `status` (if present)

**Within nested objects**: Fields should generally be alphabetically ordered unless there's a strong readability reason (e.g., grouping related fields).

**Exception**: Standard Kubernetes resource order (apiVersion, kind, metadata, spec) takes precedence over strict alphabetical ordering at the root level.

**Enforcement**: When generating new YAML files, ensure alphabetical ordering for list fields and consider alphabetical ordering for dictionary keys within spec sections.

## Key Commands

```bash
# Install cluster (default config)
./init_openshift_installation_lab_cluster.sh

# Custom config
./init_openshift_installation_lab_cluster.sh --config-file my-cluster.config

# Automation (skip prompt)
./init_openshift_installation_lab_cluster.sh --yes --config-file my-cluster.config

# Helper: Approve CSRs after hibernation
./scripts/approve_cluster_csrs.sh <BASTION_HOST> <SSH_KEY>

# Helper: Clean AWS resources
./scripts/clean_aws_tenant.sh <AWS_KEY> <AWS_SECRET> <REGION> <CLUSTER_NAME> <DOMAIN>
```

**Safety prompt**: Cluster name, region, profile, AWS deletion warning. Type 'y' to proceed. `--yes` skips.

## Architecture

### Config Structure

**Two-tier config**:
1. `config/common.config` - Shared: OCP version, passwords, Git repo, Day 2 toggle
2. `config/<profile>.config` - Cluster-specific: Name, AWS creds, region, domain, GITOPS_PROFILE_PATH, node config, INSTALL_TYPE

**Create new config**: `cp config_examples/ocp-standard.config.example config/my-cluster.config`

### GitOps "Lego" Architecture

Three-layer modular system:

1. **Components** (`components/`) - Individual apps (e.g., `rhacs`, `openshift-logging`)
   - Structure: `components/<name>/base` + `components/<name>/overlays/<variant>`

2. **Bases** (`gitops-bases/`) - ApplicationSets bundling components
   - Categories: `core`, `storage`, `logging`, `acs`, `acm`, `ai`, `netobserv`, `ossm`
   - Structure: `gitops-bases/<category>/<variant>/applicationset.yaml`

3. **Profiles** (`gitops-profiles/`) - Top-level Kustomize manifests
   - Examples: `ocp-standard`, `ocp-ai`, `ocp-acs-central`, `ocp-acm-hub`
   - Structure: `gitops-profiles/<profile>/kustomization.yaml`

**Profile determines Day 2 components installed.**

**Details**: See [installation.md](docs/claude/installation.md) for install flow, session recovery, profile creation.

### Component Overlay Naming Conventions

**Overlay Types and Patterns:**

Components use overlays to support multiple deployment configurations. Naming conventions vary by use case:

#### 1. Default Overlay Pattern
**Pattern:** `default`
**Usage:** Standard deployment configuration (22 components)
**Examples:**
- `components/cert-manager/overlays/default`
- `components/cluster-monitoring/overlays/default`
- `components/rhoai/overlays/default`

**When to use:** Single deployment mode, no variants needed

---

#### 2. Size Variant Pattern
**Pattern:** `{size}` where size = `pico` | `extra-small` | `small` | `medium` | `large`
**Usage:** Scale-based deployments
**Component:** openshift-logging

**Rationale:** Different clusters need different log retention/storage based on workload

**Examples:**
```
components/openshift-logging/overlays/
├── 1x.pico/         # Minimal (demo/dev)
├── 1x.extra-small/  # Very small workloads
├── 1x.small/        # Development clusters
└── 1x.medium/       # Production clusters
```

**Naming notes:**
- `1x.` prefix indicates node count multiplier (reserved for future scaling)
- Size names are self-documenting for capacity planning

---

#### 3. Performance Profile Pattern
**Pattern:** `{profile}` where profile = `lean` | `balanced` | `performance`
**Usage:** Resource allocation optimization
**Component:** openshift-storage (ODF)

**Rationale:** Different storage performance tiers for different workload requirements

**Examples:**
```
components/openshift-storage/overlays/
├── mcg-only/               # Object storage only (no block/file)
├── full-aws-lean/          # Minimal resource allocation
├── full-aws-balanced/      # Default resource allocation
└── full-aws-performance/   # High-performance storage
```

**Naming notes:**
- `full-aws-*` indicates complete ODF stack on AWS
- `mcg-only` is descriptive exception (Multi-Cloud Gateway only)

---

#### 4. Deployment Mode Pattern
**Pattern:** `{mode}` where mode describes operational role
**Usage:** Multi-cluster architectures
**Components:** rhacm (ACM), rhacs (ACS)

**Rationale:** Different components depending on cluster role in multi-cluster topology

**Examples:**
```
components/rhacm/overlays/
├── hub/      # Central management cluster
└── managed/  # Spoke/managed clusters

components/rhacs/overlays/
├── central/  # Central security operations
└── secured/  # Protected/monitored clusters
```

**Naming notes:**
- Mode names reflect cluster role in architecture
- Maps to upstream product terminology (hub/managed, central/secured)

---

#### 5. Feature Variant Pattern
**Pattern:** `with-{feature}` for optional integrations
**Usage:** Optional feature enablement
**Component:** network-observability

**Rationale:** Optional dependencies (e.g., external storage backends)

**Examples:**
```
components/network-observability/overlays/
├── default/    # Standard deployment (embedded storage)
└── with-loki/  # Integration with Loki backend
```

**Naming notes:**
- `with-*` prefix indicates additive feature
- Base functionality in `default`, enhanced in `with-*`

---

#### 6. Profile-Specific Pattern
**Pattern:** `{profile-name}` matching gitops-profile
**Usage:** Namespace isolation for specific deployment profiles
**Components:** openshift-pipelines, webterminal

**Rationale:** Avoid OLM install plan grouping issues (see KNOWN_LIMITATIONS.md)

**Examples:**
```
components/openshift-pipelines/overlays/
├── default/  # Standard profile (openshift-operators namespace)
└── ai/       # AI profile (openshift-pipelines-operator namespace)

components/webterminal/overlays/
├── default/  # Standard profile
└── ai/       # AI profile (isolated namespace)
```

**Naming notes:**
- Overlay name matches profile name exactly
- Solves OLM operator co-location conflicts
- See KNOWN_LIMITATIONS.md for detailed rationale

---

### Overlay Selection Guide

**When creating new overlays:**

1. **Single variant needed?** → Use `default`
2. **Multiple sizes/scales?** → Use size pattern (`pico`, `small`, `medium`, etc.)
3. **Performance tiers?** → Use profile pattern (`lean`, `balanced`, `performance`)
4. **Multi-cluster roles?** → Use mode pattern (`hub`, `managed`, `central`, `secured`)
5. **Optional features?** → Use `with-{feature}` pattern
6. **Profile isolation?** → Use profile name pattern (requires KNOWN_LIMITATIONS.md entry)

**Consistency guidelines:**
- Use lowercase, hyphen-separated names
- Make names self-documenting (avoid abbreviations)
- Document rationale for non-standard patterns in component README or KNOWN_LIMITATIONS.md
- Update this section when introducing new naming patterns

### Dynamic Cluster Configuration (CMP Plugin)

**Purpose**: Automatically discovers cluster domain and region, replacing placeholders in manifests at ArgoCD build time.

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

**TIMESTAMP behavior** (DEPRECATED - Removed from Certificate manifests):
- **NOT cached per commit**: CMP runs `date +%s` (current time), generates NEW timestamp on every Git sync
- **Causes certificate regeneration**: Every Git commit (even unrelated changes) triggers new cert requests
- **Let's Encrypt rate limits**: Risk of hitting 5 certificates/domain/week limit with frequent commits
- **Removed from usage**: TIMESTAMP no longer used in Certificate dnsNames (2026-03-29)
- **Reason**: Let's Encrypt DNS-01 validation does not require unique dnsNames per deployment

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

**Why TIMESTAMP was removed**:
- CMP plugin generates current Unix timestamp (`date +%s`), NOT commit-based
- Every Git sync (even documentation changes) regenerates TIMESTAMP
- Changed Certificate dnsNames trigger new cert-manager requests to Let's Encrypt
- Let's Encrypt DNS-01 validation does NOT require unique dnsNames
- Static dnsNames (`apps.*.opentlc.com`, `*.apps.*.opentlc.com`) work correctly

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

**Details**: See [components.md](docs/claude/components.md) OpenShift GitOps section for complete implementation details.

## Important Notes

- **Required**: `pull-secret.txt` in project root (console.redhat.com)
- **Prerequisites**: `oc`, `git`, `yq`, `podman`, `aws` CLI
- **AWS Tenant Isolation**: Tool assumes **dedicated AWS tenant** (demo/lab only). `clean_aws_tenant.sh` deletes **ALL S3 buckets** without filtering. ⚠️ **DO NOT USE IN SHARED AWS ACCOUNTS**
- **Profile paths**: `GITOPS_PROFILE_PATH` must point to existing profile in `gitops-profiles/`
- **Git repo**: Fork and update `GIT_REPO_URL` in `common.config` for custom changes
- **Critical components**: Never remove `cluster-ingress`, `cluster-oauth`, `openshift-config`, `openshift-gitops-admin-config` from ApplicationSets

**Security**: See [security.md](docs/claude/security.md) for AWS Secrets Manager integration, Job QoS patterns.

## GitOps Patterns

### ❌ Static Manifest + ignoreDifferences (DOES NOT WORK)

**CRITICAL**: Pattern is logically contradictory.

```yaml
# Static manifest declares:
spec:
  field: value

# ignoreDifferences says:
ignoreDifferences:
- jsonPointers:
  - /spec/field  # "Ignore this field"
```

**Result**: ArgoCD **NEVER APPLIES** the field → Field never configured ❌

**Failures**: IngressController defaultCertificate, Console plugins

**Use instead**: Pure Jobs for runtime patching (proven reliable)

### ✅ Shared Resources with ignoreDifferences (WORKS)

**Pattern**: Cluster-scoped resources **partially managed by OpenShift** + **partially configured by GitOps**.

**Use when**:
- Resource exists at cluster scope (created by installer/operators)
- GitOps configures **subset of fields**
- OpenShift manages other fields
- ArgoCD detects drift, tries delete/recreate → deletion **blocked** (protected resource)

**Example**: Network CR
```yaml
# gitops-bases/core/applicationset.yaml
ignoreDifferences:
  - group: config.openshift.io
    kind: Network
    name: cluster
    jsonPointers:
      - /spec/clusterNetwork  # OpenShift-managed
      - /spec/serviceNetwork  # OpenShift-managed
      - /spec/networkType     # OpenShift-managed
```

**Result**: ArgoCD ignores OpenShift fields, manages only `networkDiagnostics`, no deletion attempts.

**Key difference from failed pattern**: Ignoring fields **NOT in Git** (managed by OpenShift), not fields **IN Git**.

### Job Template Refactoring

**Question**: Extract duplicate Jobs into shared templates (DRY)?

**Answer**: **Kustomize security prevents cross-component sharing**.

**Security restriction**: Resources must be within/below kustomization root. ❌ Cannot reference parent/sibling dirs.

**Decision**: Accept intentional duplication when Kustomize security makes sharing impractical. Favor simplicity + component isolation over DRY absolutism.

**Refactor within same component**: ✅ Create base + overlays with patches
**Cross-component sharing**: ❌ Blocked by Kustomize security

### OLM Subscription installPlanApproval

**Pattern**: Rely on OLM default (omit field from manifests).

**OLM default**: `installPlanApproval: Automatic` (when omitted)

**Project standard**: Omit field from Subscription manifests (25/26 subscriptions)

**Why**: Less boilerplate, standard practice, OLM behavior stable

**Exception**: RHOAI-installed Service Mesh uses `Manual` (controlled by RHOAI operator, not our manifests)

**When to add explicit value**: Only when overriding default to `Manual`

### Network Isolation with AdminNetworkPolicy

**Pattern**: Zero-trust network isolation using AdminNetworkPolicy (ANP) + BaselineAdminNetworkPolicy (BANP)

**Architecture**: Defense-in-depth with three priority tiers
1. **AdminNetworkPolicy** (priority 10, highest) - Explicit Allow rules for cluster services
2. **NetworkPolicy** (medium priority) - User/developer policies (if any)
3. **BaselineAdminNetworkPolicy** (lowest priority) - Default deny fallback

**Opt-in mechanism**: Policies only apply to namespaces labeled `network-policy.gitops/enforce: "true"`

**Resources**:
- `components/cluster-network/base/cluster-adminnetworkpolicy-gitops-standard.yaml`
- `components/cluster-network/base/cluster-baselineadminnetworkpolicy-gitops-baseline.yaml`
- RBAC: `cluster-clusterrole-manage-network-policies.yaml` (ArgoCD permissions)

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

## Component Notes

**IMPORTANT**: Most component details moved to external docs.

**For component-specific configuration**: Read [components.md](docs/claude/components.md)

**Documented components** (non-standard patterns):
- Console Plugins - Pure Patch Jobs (shared resource)
- OpenShift GitOps - 4Gi memory, retry limit 10, RBAC, resource exclusions
- cert-manager - Permanent watchdog Deployment for CM-412, static Certificates with CMP placeholders, certificate usage in cluster-ingress/openshift-config
- ODF - Dynamic Job with ConfigMap channel management
- OpenShift Pipelines - TektonConfig profile behavior
- ACK Route53 - Static Secret with CMP AWS credentials (Job deprecated)
- Cluster Observability - Required namespace label
- RHCL (Kuadrant) - 4 operators, OLM-generated names, complete observability stack (kube-state-metrics, Grafana, operator ServiceMonitors)
- Keycloak (RHBK) - Operator subscription only (no instances deployed)
- RHOAI - DataScienceCluster, OdhDashboardConfig direct management, MaaS Gateway

**Troubleshooting components**: See [troubleshooting.md](docs/claude/troubleshooting.md)

### CertManager Watchdog Deployment

**Purpose**: Permanent monitoring for CertManager operator stuck states (CM-412 workaround)

**Implementation**: Deployment (not Job/CronJob)
- **File**: `components/cert-manager/base/openshift-gitops-deployment-watchdog-certmanager.yaml`
- **Replicas**: 1
- **Resources**: 10m CPU / 64Mi memory (requests), 100m CPU / 128Mi memory (limits)
- **Check interval**: Every 60 seconds

**Monitoring logic**:
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

**Detection criteria** (deployment conditions only):
- `cert-manager-controller-deploymentAvailable`
- `cert-manager-cainjector-deploymentAvailable`
- `cert-manager-webhook-deploymentAvailable`

**Why Deployment over Job/CronJob**:
- ✅ Immediate detection (<60s vs up to 10 minutes with CronJob)
- ✅ Continuous monitoring (not scheduled)
- ✅ Automatic recovery from cluster hibernation
- ✅ Minimal overhead (sleeping pod uses ~10m CPU)
- ✅ Better for infrastructure-critical services

**Certificate management**:
- Certificates are static manifests managed by ArgoCD with CMP placeholders
- Certificate usage (IngressController, APIServer) managed in cluster-ingress/openshift-config components
- Watchdog only ensures CertManager operator stays healthy

**Related**: See CM-412 in [known-bugs.md](docs/claude/known-bugs.md) for background on stuck operator issue.

### Component Structure Exception: components/common/

**Why `components/common/` lacks `base/overlays` structure:**

The `components/common/` directory is a **data source component**, not a deployable component.

**Standard component structure:**
```
components/<name>/
├── base/           # Base Kubernetes manifests
└── overlays/       # Environment-specific variations
    ├── default/
    ├── small/
    └── medium/
```

**`components/common/` structure:**
```
components/common/
└── cluster-versions.yaml  # ConfigMap with operator channel versions
```

**Key differences:**

| Aspect | Standard Component | components/common/ |
|--------|-------------------|-------------------|
| **Purpose** | Deploy operators/apps | Provide shared data |
| **Contains** | Subscription, Deployment, Service | ConfigMap only |
| **Referenced by** | ApplicationSet | Kustomize base in other components |
| **ArgoCD manages?** | Yes | No (data only) |
| **Needs overlays?** | Yes (variants) | No (single source of truth) |

**Usage pattern:**

Every component's `base/kustomization.yaml` references `common`:

```yaml
resources:
- ../../common  # Loads cluster-versions ConfigMap
- subscription.yaml
```

Then uses Kustomize replacements to inject version data:

```yaml
replacements:
- source:
    kind: ConfigMap
    name: cluster-versions
    fieldPath: data.loki
  targets:
  - select:
      kind: Subscription
      name: loki-operator
    fieldPaths:
    - spec.channel
```

**Why not `base/overlays`?**

- ConfigMap contains **single source of truth** for all operator versions
- No environment-specific variations needed (same versions everywhere)
- Acts as a **library/utility**, not a deployable resource
- Never instantiated directly by ArgoCD Applications
- Only used as Kustomize data source

**Similar pattern:** Kustomize configuration generators, not resource deployments.

**When to use this pattern:**
- Shared configuration data consumed by multiple components
- Single source of truth (no variants needed)
- Pure data source with no deployment manifests

## Monitoring and Alerts

**IMPORTANT**: All monitoring content externalized.

**For Alertmanager config, alert silences, known bugs**: Read [monitoring.md](docs/claude/monitoring.md)

**For known false-positive alerts**: Read [known-bugs.md](docs/claude/known-bugs.md)

**Quick reference**:
- Alertmanager managed via GitOps in `cluster-monitoring` component
- Alert silences require **BOTH** routing to null receiver AND Alertmanager API silence
- Automated silences via PostSync Job (5 known bugs silenced automatically)
- User workload monitoring: No separate Alertmanager (routes through cluster Alertmanager)
- Insights recommendations: Suppressed via Alertmanager (routing + silences)

**Before adding alert silences**: Verify bug, document in known-bugs.md, add routing + silence, run audit script.

## Version Management

**Centralized**: `components/common/cluster-versions.yaml` ConfigMap

**Kustomize replacements**: Inject versions into Subscription `spec.channel` fields

**Upgrade pattern**:
1. Update ConfigMap: `cluster-logging: "stable-6.5"`
2. Kustomize injects new channel into subscription
3. OLM upgrades operator automatically

**Components using ConfigMap**:
- Observability: cluster-logging, cluster-observability, grafana, loki
- Infrastructure: ack-route53, nfd
- Storage: odf
- AI: rhoai
- Plus: all RHCL operators

**Fallback channels**: Generic channels in subscriptions (e.g., `stable-3.x`) for future flexibility

**Example**:
```yaml
# cluster-versions ConfigMap
data:
  rhoai: "stable-3.3"  # Actual deployed version

# Subscription
spec:
  channel: stable-3.x  # Fallback/generic

# Kustomize replacement injects: channel: stable-3.3
```
