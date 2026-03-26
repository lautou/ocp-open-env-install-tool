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
- **[monitoring.md](docs/claude/monitoring.md)** - Alertmanager, alert silences, Insights recommendations
- **[known-bugs.md](docs/claude/known-bugs.md)** - False-positive alerts and upstream bugs
- **[installation.md](docs/claude/installation.md)** - Installation flow, session recovery, profiles
- **[security.md](docs/claude/security.md)** - AWS Secrets Manager, Job QoS, tenant isolation
- **[troubleshooting.md](docs/claude/troubleshooting.md)** - Common issues and debugging

**Project audit**: Complete codebase analysis available:
- **[AUDIT.md](AUDIT.md)** - Comprehensive project audit (structure, components, GitOps architecture, Jobs, security, documentation, known issues, recommendations)

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

## Component Notes

**IMPORTANT**: Most component details moved to external docs.

**For component-specific configuration**: Read [components.md](docs/claude/components.md)

**Documented components** (non-standard patterns):
- Console Plugins - Pure Patch Jobs (shared resource)
- OpenShift GitOps - 4Gi memory, retry limit 10, RBAC, resource exclusions
- cert-manager - IngressController Job, Certificate provisioning with pod readiness
- ODF - Dynamic Job with ConfigMap channel management
- OpenShift Pipelines - TektonConfig profile behavior
- ACK Route53 - Dynamic config injection Job
- Cluster Observability - Required namespace label
- RHCL (Kuadrant) - 4 operators, OLM-generated names, complete observability stack (kube-state-metrics, Grafana, operator ServiceMonitors)
- Keycloak (RHBK) - Operator subscription only (no instances deployed)
- RHOAI - DataScienceCluster, OdhDashboardConfig direct management, MaaS Gateway

**Troubleshooting components**: See [troubleshooting.md](docs/claude/troubleshooting.md)

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
