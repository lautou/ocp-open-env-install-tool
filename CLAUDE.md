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
- **[argocd-patterns-checklist.md](docs/claude/argocd-patterns-checklist.md)** - ⚠️ **CRITICAL**: Required patterns for Applications/CRs (ignoreDifferences, managed-by labels, SkipDryRunOnMissingResource)
- **[argocd-hook-robustness.md](docs/claude/argocd-hook-robustness.md)** - ⚠️ **CRITICAL**: PostSync hook robustness (delete policies, timeouts, deadlock prevention)
- **[components.md](docs/claude/components.md)** - Component-specific configuration patterns (CMP plugin, network policies, cert-manager, ODF, RHCL, ACK, etc.)
- **[jobs.md](docs/claude/jobs.md)** - Job architecture, ArgoCD hooks, development guide (14 Jobs)
- **[kfp-secret-patterns.md](docs/claude/kfp-secret-patterns.md)** - ⚠️ **CRITICAL**: KFP v2 secret injection patterns (platformSpec, task-level vs executor-level config, troubleshooting)
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

### Documentation Maintenance Rules

**⚠️ MANDATORY: Follow these rules when updating documentation**

**1. Keep CLAUDE.md lean** (target: <500 lines)
- ✅ Include: Critical patterns, warnings, summaries
- ❌ Exclude: Detailed examples, full procedures, troubleshooting steps
- **Before adding**: Check if content already exists in external docs

**2. Consolidate before adding**
- **ALWAYS check for redundancy** when user asks to update docs
- If content exists in both CLAUDE.md AND external doc → keep SHORT summary in CLAUDE.md, link to external doc
- If content only in external doc → add cross-reference in CLAUDE.md, DO NOT duplicate

**3. Cross-reference pattern**
```markdown
**Pattern summary** (10-20 lines max)

**Complete guide**: [external-doc.md](docs/claude/external-doc.md)
```

**4. Automatic consolidation trigger**
- User says "update the doc" → **FIRST check for redundancy**, THEN update
- User says "add to CLAUDE.md" → **FIRST check if external doc exists**, THEN decide where to add

**5. Size limits**
- CLAUDE.md: <500 lines (currently ~506)
- Individual sections: <100 lines
- Subsections: <30 lines
- **If exceeded**: Move detailed content to external doc, keep summary + cross-reference

**6. Version-controlled rules (META-RULE)**
- **CRITICAL**: All important rules, workflows, and patterns MUST be version-controlled
- ✅ Add to CLAUDE.md or docs/claude/*.md (travels with repo)
- ❌ Do NOT rely only on local memory (machine-specific, doesn't travel)
- **Memory is ephemeral** - Use it for session context, not for permanent knowledge
- **Documentation is permanent** - Use it for rules that must persist across machines/sessions

**Enforcement**: When user asks "update the doc", this triggers:
1. Check: Does this content exist elsewhere?
2. If YES: Consolidate (summary in CLAUDE.md, details in external doc)
3. If NO: Add to appropriate location (CLAUDE.md if critical pattern, external doc if detailed)
4. Update cross-references

**Recent consolidation (2026-04-16)**: Reduced CLAUDE.md from 607 → 446 lines (26% reduction)
- PreDelete hooks: 64 → 15 lines (cross-ref to jobs.md)
- RHOAI deletion: 46 → 20 lines (cross-ref to rhoai-deletion-order.md)
- Jobs pattern: 89 → 25 lines (cross-ref to jobs.md)
- ignoreDifferences examples: 58 → 20 lines (cross-ref to argocd-patterns-checklist.md)

## ⚠️ CRITICAL: Required ArgoCD Patterns

**MUST READ BEFORE CREATING COMPONENTS**: [argocd-patterns-checklist.md](docs/claude/argocd-patterns-checklist.md)

**4 patterns that MUST ALWAYS be included** (see checklist for full details):

1. **ignoreDifferences for cluster-versions ConfigMap**
   - ✅ Required in ALL Application/ApplicationSet definitions
   - Pattern: Ignore `/metadata/annotations` on `cluster-versions` ConfigMap
   - Why: Shared resource used by all components for version tracking

2. **argocd.argoproj.io/managed-by label in Namespaces**
   - ✅ Required in ALL cluster-scoped Namespace resources
   - Pattern: `argocd.argoproj.io/managed-by: openshift-gitops`
   - Why: ArgoCD namespace management and permissions

3. **SkipDryRunOnMissingResource for Operator CRs**
   - ✅ Required in ALL operator Custom Resources
   - Pattern: `argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true`
   - Why: CRD validation fails before operator is deployed → deadlock

4. **Force=true for Jobs (NO hook annotations)**
   - ✅ Required in ALL Jobs
   - Pattern: `argocd.argoproj.io/sync-options: Force=true` (ONLY this annotation)
   - ❌ DO NOT use: `argocd.argoproj.io/hook: PostSync` (causes sync deadlock)
   - ❌ DO NOT use: `argocd.argoproj.io/hook-delete-policy` (only for hooks)
   - ❌ DO NOT use: `argocd.argoproj.io/sync-wave` (only for hooks)
   - Why: Job spec.template is immutable → Force=true enables updates (delete+recreate)
   - Why NO hooks: PostSync hooks block ArgoCD sync until Job completes → infinite wait = deadlock
   - **Regular Jobs**: Sync completes immediately, Job runs independently, Application shows "Synced + Progressing" until Job finishes

**Pre-commit checklist**:
- [ ] Application/ApplicationSet has ignoreDifferences for cluster-versions?
- [ ] Namespace has argocd.argoproj.io/managed-by label?
- [ ] Operator CRs have SkipDryRunOnMissingResource annotation?
- [ ] Jobs have ONLY Force=true (no hook annotations)?

**Failure symptoms if forgotten**:
- Missing ignoreDifferences → Application OutOfSync (but Healthy)
- Missing managed-by → ArgoCD permission errors
- Missing SkipDryRunOnMissingResource → Application stuck OutOfSync/Missing forever
- Missing Force=true on Jobs → "field is immutable" error → Application stuck in retry loop → manual Job deletion required
- Using PostSync hook → Sync deadlock if Job waits forever for dependencies → requires manual Job deletion

## YAML Formatting Standards

**CRITICAL**: All Kubernetes YAML manifests and Kustomize files MUST follow alphabetical ordering and naming convention rules.

### File Naming Conventions

**Mandatory patterns**: All YAML resource files MUST follow standardized naming conventions.

**For detailed naming rules**: See [docs/claude/gitops-specialist-agent.md](docs/claude/gitops-specialist-agent.md) section "YAML File Naming Conventions"

**Quick reference**:
- Namespaced resources: `<namespace>-<type>-<name>.yaml`
- Cluster-scoped resources: `cluster-<type>-<name>.yaml`
- Aliases allowed: sa, cm, svc, deploy, rb, crb, cr (to prevent excessive filename length)
- Special prefix: `TEMPORARY-FIX-` (intentional indicator for upstream bug workarounds)

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
   - Examples: `ocp-standard`, `ocp-ai`, `ocp-reference`, `ocp-acs-central`, `ocp-acm-hub`

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

### ⚠️ CRITICAL: ignoreDifferences Best Practices

**Default approach**: Avoid ignoreDifferences whenever possible.

**When required**:
1. **Test incrementally** - Add one field at a time, verify sync after each
2. **Minimal scope** - Only ignore the specific field causing drift
3. **Document why** - Each ignore needs clear justification
4. **Prefer RBAC** - Explicit ClusterRole permissions often eliminate need for ignores

**Testing workflow**:
```bash
# 1. Remove ignoreDifferences entry
# 2. Push change
# 3. Verify sync status (oc get applicationset <name>)
# 4. Check resource state (oc get <resource> -o yaml)
# 5. Only re-add if genuine conflict confirmed
```

**Recent findings**:
- ✅ APIServer: No ignoreDifferences needed (RBAC sufficient) - 2026-03-30
- ✅ Network: No ignoreDifferences needed (RBAC sufficient) - 2026-03-30
- ✅ cluster-versions ConfigMap: Only `/metadata/annotations` needed (not labels/ownerReferences) - 2026-03-30
- ✅ HardwareProfile: No ignoreDifferences needed (namespace managed-by label sufficient) - 2026-03-30
- ✅ OdhDashboardConfig: No ignoreDifferences needed (namespace managed-by label sufficient) - 2026-03-30
- ✅ RHACM ClusterManagementAddons: Require `/spec/defaultConfigs` AND `/spec/installStrategy` (operator-managed) - 2026-04-08

**Excessive ignores are technical debt** - Test carefully before adding.

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

**Pattern**: Resources **managed by multiple ArgoCD Applications** simultaneously.

**When to use**:
- Multiple Applications reference same resource → each sync updates ArgoCD metadata → sync conflicts
- Operator dynamically manages spec fields → cannot be statically declared in manifests

**Two valid scenarios**:

1. **Shared resource** (e.g., cluster-versions ConfigMap)
   - Ignore `/metadata/annotations` (ArgoCD tracking-id conflicts)
   - Result: All Applications sync without conflicts

2. **Operator-managed fields** (e.g., RHACM ClusterManagementAddons)
   - Ignore `/spec/defaultConfigs` and `/spec/installStrategy` (operator-owned)
   - Result: No auto-heal cycles, operator manages fields independently

**Key insight**: Only ignore when field CANNOT be statically declared (multi-owner or operator-managed)

**Examples and troubleshooting**: See [argocd-patterns-checklist.md](docs/claude/argocd-patterns-checklist.md)

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

### ✅ Jobs Pattern: Regular Jobs (NOT Hooks)

**CRITICAL**: Use regular Jobs with `Force=true` annotation ONLY (NO hook annotations) to avoid sync deadlocks.

**Required annotations**:
```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Force=true  # ONLY this
    # ❌ DO NOT add: argocd.argoproj.io/hook: PostSync
```

**Why NO hook annotations**:
- PostSync hook → ArgoCD waits for Job completion → deadlock if Job waits forever
- Regular Job → Sync completes immediately → Application "Synced + Progressing" → no deadlock

**Pattern**: Jobs wait for dependencies via infinite loops (no timeout needed)
```bash
while ! oc get secret my-dependency -n target-namespace; do
  sleep 5
done
```

**Key benefits**:
- ✅ No sync deadlock - ArgoCD not blocked
- ✅ Self-healing - Job waits patiently for dependencies
- ✅ Updatable - Force=true handles Job immutability
- ⚠️ Trade-off: Race condition (Job may start before dependencies), handled by wait loop

**Examples**: `create-secret-netobserv-loki-s3`, `update-odf-subscriptions-node-selector`, `ack-config-injector`

**Complete guide**: [jobs.md](docs/claude/jobs.md) - Job architecture, comparison tables, development patterns

### ApplicationSet Configuration for PreDelete Hooks

**CRITICAL**: PreDelete hooks only execute during **explicit Application deletion** (`oc delete application`), NOT during ApplicationSet pruning.

**Required ApplicationSet configuration**:
- `spec.syncPolicy.applicationsSync: create-update` - Prevents auto-deletion
- `metadata.finalizers: resources-finalizer.argocd.argoproj.io` - Protects from ApplicationSet deletion
- `template.metadata.finalizers: resources-finalizer.argocd.argoproj.io/background` - Cascade cleanup

**Component removal workflow**:
1. Remove from profile → Application orphaned (not deleted)
2. Explicitly delete: `oc delete application <name>` → PreDelete hook executes
3. Hook completes → Application deleted

**Requirements**: ArgoCD 3.3+ (OpenShift GitOps 1.20+)

**Complete guide**: See [jobs.md](docs/claude/jobs.md) section "PreDelete Hooks and ApplicationSet Configuration"

### Component Deletion Order - CRITICAL for RHOAI

**⚠️ CRITICAL**: When deleting RHOAI, **user workload Applications MUST be deleted BEFORE platform Application**.

**Why**: User workloads (InferenceServices, Notebooks, Pipelines) become NON-FUNCTIONAL after platform removal. They cannot clean up gracefully without CRDs/operators/webhooks.

**Correct deletion order**:
```bash
# 1. User workloads FIRST
oc delete application uc-ai-generation-llm-rag uc-llamastack ai-models-service -n openshift-gitops
sleep 60  # Wait for cleanup

# 2. Platform LAST
oc delete application rhoai -n openshift-gitops  # Triggers PreDelete hook
oc delete applicationset cluster-ai -n openshift-gitops
```

**Wrong order consequences**: Platform deleted first → 10 namespaces stuck Terminating for 75+ min (observed 2026-04-16)

**PreDelete hook**: Includes Step 0 safety net for orphaned workloads, but proper order is still required for graceful cleanup.

**Complete guide**: [rhoai-deletion-order.md](docs/claude/rhoai-deletion-order.md) - Red Hat procedures, troubleshooting, profile switching

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

### OLM Resource API Groups - RHACM Conflict

**Pattern**: Always use explicit API groups for OLM resources in Job scripts and CLI commands.

**CRITICAL on clusters with RHACM installed**: OLM and RHACM share resource type names, causing API group ambiguity.

**The Problem**:
- **OLM**: `subscription.operators.coreos.com` (operator installations)
- **RHACM**: `subscription.apps.open-cluster-management.io` (application deployments)
- Generic `oc get subscription` → defaults to RHACM API
- Jobs have RBAC for OLM API, not RHACM API
- Result: Forbidden errors → infinite wait loops → Jobs never complete

**Always use explicit API groups in Jobs/scripts**:
```bash
# ❌ WRONG - Ambiguous (resolves to RHACM on clusters with ACM)
oc get subscription my-operator -n my-namespace

# ✅ CORRECT - Explicit API group
oc get subscription.operators.coreos.com my-operator -n my-namespace
```

**OLM resources requiring explicit API groups**:
- `subscription.operators.coreos.com` - **CRITICAL** (conflicts with RHACM)
- `csv.operators.coreos.com` (ClusterServiceVersion)
- `installplan.operators.coreos.com`
- `operatorgroup.operators.coreos.com`

**Real failure** (fixed in 8ab206e):
- Job `update-odf-subscriptions-node-selector` stuck 24+ hours in wait loop
- Root cause: `oc get subscription` → Forbidden (wrong API group)
- Fix: Added `.operators.coreos.com` to all commands
- Result: Job completes in 30 seconds instead of infinite loop

**When this matters**:
- ✅ All profiles with RHACM installed (`ocp-reference`, `ocp-acm-hub`)
- ✅ Any cluster where RHACM might be added later
- ✅ Defensive coding (prevents future breakage)

**See**: [jobs.md](docs/claude/jobs.md) "Best Practices" and [troubleshooting.md](docs/claude/troubleshooting.md) "Job Stuck in Infinite Loop"

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

## Development Workflow

### ArgoCD Configuration Changes

**CRITICAL**: After pushing GitOps configuration changes, ALWAYS immediately trigger sync on affected Applications.

**Workflow**:
1. `git push origin master`
2. Immediately patch Application(s) to trigger sync
3. Wait 10-20 seconds for sync to complete
4. Verify sync + health status
5. Report results

**Why**: ArgoCD auto-sync polling interval is 3+ minutes. Immediate sync validates the fix and catches issues right away.

**Applies to**: Component files, kustomization.yaml, Application specs, any GitOps manifest changes.
