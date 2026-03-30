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
- **[components.md](docs/claude/components.md)** - Component-specific configuration patterns (CMP plugin, network policies, cert-manager, ODF, RHCL, ACK, etc.)
- **[jobs.md](docs/claude/jobs.md)** - Job architecture, ArgoCD hooks, development guide (16 Jobs)
- **[monitoring.md](docs/claude/monitoring.md)** - Alertmanager, alert silences, Insights recommendations
- **[known-bugs.md](docs/claude/known-bugs.md)** - False-positive alerts and upstream bugs
- **[installation.md](docs/claude/installation.md)** - Installation flow, session recovery, profiles
- **[security.md](docs/claude/security.md)** - AWS Secrets Manager, Job QoS, tenant isolation, InfoSec leak detection (.gitleaks.toml)
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

**Rationale**: Easier to find resources, reduces merge conflicts, consistent ordering, better maintainability.

### Kubernetes Manifests

**Standard field order**: `apiVersion`, `kind`, `metadata`, `spec`, `status`

**Within nested objects**: Alphabetically ordered unless strong readability reason exists.

## Architecture

### GitOps "Lego" Architecture

Three-layer modular system:

1. **Components** (`components/`) - Individual apps (e.g., `rhacs`, `openshift-logging`)
   - Structure: `components/<name>/base` + `components/<name>/overlays/<variant>`

2. **Bases** (`gitops-bases/`) - ApplicationSets bundling components
   - Categories: `core`, `storage`, `logging`, `acs`, `acm`, `ai`, `netobserv`, `devops`, `rh-connectivity-link`

3. **Profiles** (`gitops-profiles/`) - Top-level Kustomize manifests selecting which bases/components to deploy
   - Examples: `ocp-standard`, `ocp-ai`, `ocp-acs-central`, `ocp-acm-hub`

**Profile determines Day 2 components installed.**

**Config**: Two-tier system - `config/common.config` (shared) + `config/<profile>.config` (cluster-specific). See `config_examples/` for templates.

**Details**: See [installation.md](docs/claude/installation.md) for install flow, session recovery, profile creation.

### Component Overlay Patterns

Components use overlays for deployment variants. Common patterns:
- `default` - Standard deployment (most common)
- `{size}` - Scale variants (pico, small, medium, large)
- `{mode}` - Multi-cluster roles (hub/managed, central/secured)
- `with-{feature}` - Optional integrations

**Discoverable**: Use Glob/Read to explore `components/*/overlays/` for specific patterns.

### Dynamic Cluster Configuration (CMP Plugin)

**Purpose**: ArgoCD plugin auto-discovers cluster domain/region, replaces `CMP_PLACEHOLDER_*` placeholders at build time.

**Placeholders**:
- `CMP_PLACEHOLDER_OCP_APPS_DOMAIN` - Apps subdomain for Routes
- `CMP_PLACEHOLDER_OCP_API_DOMAIN` - API subdomain
- `CMP_PLACEHOLDER_CLUSTER_REGION` - AWS region
- `CMP_PLACEHOLDER_AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` - AWS credentials
- `CMP_PLACEHOLDER_ROOT_DOMAIN` - Parent domain

**⚠️ DEPRECATED**: `CMP_PLACEHOLDER_TIMESTAMP` removed (causes cert regeneration on every commit, Let's Encrypt rate limits)

**Details**: See [components.md](docs/claude/components.md) OpenShift GitOps section for implementation, RBAC, verification.

## Important Notes

- **Required**: `pull-secret.txt` in project root (console.redhat.com)
- **Prerequisites**: `oc`, `git`, `yq`, `podman`, `aws` CLI
- **AWS Tenant Isolation**: Tool assumes **dedicated AWS tenant** (demo/lab only). `clean_aws_tenant.sh` deletes **ALL S3 buckets** without filtering. ⚠️ **DO NOT USE IN SHARED AWS ACCOUNTS**
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
ignoreDifferences:
  - group: config.openshift.io
    kind: Network
    name: cluster
    jsonPointers:
      - /spec/clusterNetwork  # OpenShift-managed
      - /spec/serviceNetwork  # OpenShift-managed
```

**Result**: ArgoCD ignores OpenShift fields, manages only GitOps-declared fields, no deletion attempts.

**Key difference from failed pattern**: Ignoring fields **NOT in Git** (managed by OpenShift), not fields **IN Git**.

### ✅ SkipDryRunOnMissingResource for Operator CRs (CRITICAL)

**Pattern**: Add `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true` annotation to ALL operator Custom Resources when CRDs are installed by the operator.

**Problem Without Annotation**:

ArgoCD validates ALL resources before applying ANY resources:

1. **Validation Phase**: ArgoCD attempts dry-run on all manifests
2. **CRD Missing**: Operator Custom Resource validation fails (CRD doesn't exist yet)
3. **Sync Aborted**: ArgoCD aborts ENTIRE sync without applying ANY resources
4. **Deadlock**: Operator Subscription never created → CRDs never installed → CR validation always fails

**Result**: Application stuck in OutOfSync/Missing state forever.

**Solution**: Annotation bypasses validation for CRs, allowing Subscription to deploy first.

**When to Use**:

✅ **ALL** Custom Resources when CRDs are installed by operators (cert-manager, ODF, RHOAI, NetworkPolicy, etc.)

❌ **DO NOT USE** for built-in Kubernetes/OpenShift resources

**Critical**: Without this annotation, operator-based components WILL FAIL on fresh cluster deployments.

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

**When to add explicit value**: Only when overriding default to `Manual`

## Component Notes

**IMPORTANT**: Most component details moved to external docs.

**For component-specific configuration**: Read [components.md](docs/claude/components.md)

**Documented in components.md** (non-standard patterns):
- **Console Plugins** - Pure Patch Jobs (shared resource)
- **OpenShift GitOps** - CMP plugin, 4Gi memory, retry limit 10, RBAC, resource exclusions
- **cert-manager** - Permanent watchdog Deployment for CM-412, static Certificates with CMP placeholders
- **cluster-network** - AdminNetworkPolicy/BANP for zero-trust isolation, opt-in via namespace label
- **ODF** - Dynamic Job with ConfigMap channel management
- **RHCL (Kuadrant)** - 4 operators, OLM-generated names, complete observability stack
- **ACK Route53** - Static Secret with CMP AWS credentials
- **RHOAI** - DataScienceCluster, OdhDashboardConfig, MaaS Gateway

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

**Before adding alert silences**: Verify bug, document in known-bugs.md, add routing + silence, run audit script.
