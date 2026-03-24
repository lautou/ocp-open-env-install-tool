# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is an OpenShift Container Platform (OCP) installation tool designed for Red Hat Demo Platform AWS Blank Open Environment labs. It automates cluster provisioning on AWS with extensive Day 2 configuration through a Profile-Based GitOps architecture.

Supports both **IPI** (Installer-Provisioned Infrastructure) and **UPI** (User-Provisioned Infrastructure) installation methods.

## Documentation Philosophy

**IMPORTANT**: This CLAUDE.md file is AI context documentation, NOT human-facing documentation (see README.md for that).

**What gets documented here:**
- ✅ **Patterns and anti-patterns** - Shared resource patterns, Pure Job patterns, failed approaches
- ✅ **Non-discoverable knowledge** - OLM naming conventions, operator limitations, design rationale
- ✅ **Architecture and flows** - GitOps "Lego" model, installation sequence, recovery mechanisms
- ✅ **Gotchas and workarounds** - Known bugs, accepted limitations, special configurations
- ✅ **Complex components** - Those with special patterns or non-obvious behavior

**What does NOT get documented here:**
- ❌ **Simple components** - Standard operator deployments with no special configuration
- ❌ **Discoverable information** - Namespace names, channel versions (readable from manifests/cluster)
- ❌ **Component catalogs** - Complete lists of all components (discoverable via file system)
- ❌ **Basic usage** - User-facing instructions (belongs in README.md)

**Rationale:** AI assistants can dynamically discover simple information (Read/Glob/Grep). Documentation should capture knowledge that CANNOT be easily discovered - patterns, rationale, failed attempts, and non-obvious constraints.

**For audits:** If a component is undocumented in "Component-Specific Notes", it means it follows standard patterns with no special behavior. This is intentional, not a documentation gap.

## Key Commands

### Installation

```bash
# Use default configuration (config/ocp-standard.config)
./init_openshift_installation_lab_cluster.sh

# Use specific configuration file
./init_openshift_installation_lab_cluster.sh --config-file my-cluster.config

# Skip confirmation prompt (for automation/CI-CD)
./init_openshift_installation_lab_cluster.sh --yes --config-file my-cluster.config

# Show help
./init_openshift_installation_lab_cluster.sh --help
```

**Safety Confirmation Prompt:**

Before starting any new installation (not session recovery), the script displays a confirmation prompt showing:
- Cluster name, AWS region, config file
- GitOps profile path and install type
- Warning about AWS resource deletion (VPCs, S3, EC2, Route53, IAM, Secrets)

User must explicitly type 'y' or 'Y' to proceed (default: No). Use `--yes` flag to skip for automation.

### Helper Scripts

```bash
# Approve pending cluster CSRs (for node recovery after shutdown)
./scripts/approve_cluster_csrs.sh <BASTION_HOST> <SSH_KEY>
# Example:
./scripts/approve_cluster_csrs.sh ec2-x-x-x-x.compute.amazonaws.com output/bastion_mycluster.pem

# Manually clean AWS resources (use with caution - normally auto-invoked)
./scripts/clean_aws_tenant.sh <AWS_KEY> <AWS_SECRET> <REGION> <CLUSTER_NAME> <DOMAIN>
```

## Architecture

### Split-Configuration Model

The tool uses a two-tier configuration system:

1. **`config/common.config`** - Shared variables across all clusters:
   - `OPENSHIFT_VERSION` - OCP version to install
   - `OCP_ADMIN_PASSWORD`, `OCP_NON_ADMIN_PASSWORD` - Cluster credentials
   - `GIT_REPO_URL`, `GIT_REPO_REVISION` - GitOps repository settings
   - `ENABLE_DAY2_GITOPS_CONFIG` - Enable/disable Day 2 ArgoCD deployment

2. **`config/<profile>.config`** - Cluster-specific settings:
   - `CLUSTER_NAME` - Name of this cluster
   - `AWS_DEFAULT_REGION` - Target AWS region
   - `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` - AWS credentials
   - `RHDP_TOP_LEVEL_ROUTE53_DOMAIN` - Base domain (e.g., `.sandbox1234.opentlc.com`)
   - `GITOPS_PROFILE_PATH` - Path to GitOps profile (e.g., `gitops-profiles/ocp-standard`)
   - Node configuration: `AWS_WORKERS_COUNT`, `AWS_INSTANCE_TYPE_*_NODES`, etc.
   - `INSTALL_TYPE` - "IPI" or "UPI"

**To create a new configuration:**
```bash
cp config_examples/ocp-standard.config.example config/my-cluster.config
# Edit config/my-cluster.config with your settings
```

### GitOps "Lego" Architecture

Three-layer modular system for Day 2 configuration:

1. **Components** (`components/`) - The "Bricks"
   - Individual application definitions (e.g., `rhacs`, `openshift-logging`)
   - Structure: `components/<name>/base` and `components/<name>/overlays/<variant>`
   - Examples: `openshift-logging/overlays/1x.small`, `odf/overlays/full-aws-performance`

2. **Bases** (`gitops-bases/`) - The "Groups"
   - ArgoCD ApplicationSets that bundle components together
   - Organized by function: `core`, `storage`, `logging`, `acs`, `acm`, `ai`, `netobserv`, `ossm`
   - Structure: `gitops-bases/<category>/<variant>/applicationset.yaml`
   - Example: `gitops-bases/logging/pico` includes minimal logging components

3. **Profiles** (`gitops-profiles/`) - The "Menu"
   - Top-level Kustomize manifests that compose multiple bases
   - Each profile is a complete cluster configuration
   - Structure: `gitops-profiles/<profile-name>/kustomization.yaml`
   - Examples:
     - `ocp-standard` - Core + OSSM + MCG storage + minimal logging + netobserv
     - `ocp-standard-secured` - Standard + ACS SecuredCluster (spoke for security scanning)
     - `ocp-standard-managed` - Standard + ACM Klusterlet (spoke for multi-cluster management)
     - `ocp-ai` - Standard + RHOAI + GPU operators + Kueue
     - `ocp-acs-central` - Standard + ACS Central server
     - `ocp-acm-hub` - Standard + ACM Hub server
     - `ocp-odf-full-aws-performance` - Core + full ODF with performance node sizing

**The profile specified in `GITOPS_PROFILE_PATH` determines which Day 2 components are installed.**

### Installation Flow

1. **Main Script** (`init_openshift_installation_lab_cluster.sh`):
   - Loads `config/common.config` and specified cluster config
   - Creates `output/` directory structure for artifacts
   - Checks for existing session state (enables resume capability)
   - Provisions EC2 Bastion instance with UserData script
   - Uploads files to bastion: configs, scripts, pull-secret, CloudFormation templates
   - Establishes SSH session and executes `bastion_script.sh` in tmux

2. **Bastion Script** (`scripts/bastion_script.sh`):
   - Verifies prerequisites (oc, openshift-install, aws, yq, etc.)
   - Configures AWS CLI with credentials
   - **IPI Mode**: Runs `openshift-install create cluster`
   - **UPI Mode**: Deploys CloudFormation stacks in sequence:
     1. Network (VPC, subnets)
     2. Load Balancer
     3. Security Groups
     4. Bootstrap node
     5. Control plane nodes
     6. Worker node groups (uses `aws_lib.sh` for stack management)
   - Creates Day 1 MachineConfigs (chrony, network settings)
   - Waits for cluster bootstrap completion
   - Configures htpasswd authentication
   - Deploys Day 2 GitOps if `ENABLE_DAY2_GITOPS_CONFIG=true`

3. **GitOps Deployment**:
   - Installs OpenShift GitOps operator
   - Applies `day2_config/applications/bootstrap-application.yaml` pointing to selected profile
   - ArgoCD syncs all ApplicationSets from the profile's bases
   - Each ApplicationSet deploys its component applications

### Session Recovery

The tool supports robust recovery from network interruptions:

- **Session files** stored in `output/`:
  - `.bastion_session_<config>.info` - SSH connection details
  - `.bastion_provisioning_<config>.info` - Bastion instance ID during creation
- **Recovery behavior**:
  - Re-running the script detects active sessions and prompts to resume
  - Reattaches to existing tmux session on bastion
  - Detects partially-provisioned bastion instances and resumes waiting

### Output Directory Structure

All runtime artifacts isolated in `output/` (gitignored):

```
output/
├── bastion_<config>.pem              # SSH private key for bastion
├── .bastion_session_<config>.info    # Session state (host, key path, config)
├── .bastion_provisioning_<config>.info  # Instance ID during provisioning
└── _upload_to_bastion_<config>/      # Staging folder uploaded to bastion
    ├── ocp_rhdp.config               # Merged config for bastion
    ├── pull-secret.txt
    ├── bastion_script.sh
    ├── aws_lib.sh
    ├── cloudformation_templates/
    ├── day1_config/
    └── day2_config/
```

## Working with GitOps Profiles

### Creating a New Profile

1. Create profile directory and kustomization:
```bash
mkdir -p gitops-profiles/my-new-profile
```

2. Create `gitops-profiles/my-new-profile/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../gitops-bases/core
  - ../../gitops-bases/storage/odf-full-aws-balanced
  - ../../gitops-bases/logging/small
  - ../../gitops-bases/acs/secured
```

3. Create corresponding config file:
```bash
cp config_examples/ocp-standard.config.example config/my-profile.config
# Set GITOPS_PROFILE_PATH="gitops-profiles/my-new-profile"
```

### Creating a New Base

1. Create base directory:
```bash
mkdir -p gitops-bases/<category>/<variant>
```

2. Create ApplicationSet manifest:
```bash
# See gitops-bases/core/applicationset.yaml as reference
# Lists components in spec.generators.list.elements
# Points to components/<item>/overlays/<variant> paths
```

### Modifying Components

Components follow standard Kustomize structure:
- `components/<name>/base/` - Base manifests
- `components/<name>/overlays/<variant>/` - Variant-specific patches

ApplicationSets reference: `components/<item>/overlays/<overlay-name>`

## Important Notes

- **Required file**: `pull-secret.txt` must exist in project root (from console.redhat.com)
- **Prerequisites**: Ensure `oc`, `git`, `yq`, `podman`, `aws` CLI tools are installed locally
- **AWS credentials**: Must be valid for Red Hat Demo Platform Blank Open Environment
- **AWS Tenant Isolation**: This tool assumes a **dedicated AWS tenant** for OCP clusters only. The cleanup script (`clean_aws_tenant.sh`) intentionally deletes **ALL S3 buckets** in the tenant without filtering, as the tenant should contain no production resources beyond the demo cluster. Do NOT use in shared AWS accounts.
- **Profile paths**: `GITOPS_PROFILE_PATH` must point to existing profile in `gitops-profiles/`
- **Git repo**: Default points to upstream; fork and update `GIT_REPO_URL` in `common.config` for custom changes
- **CloudFormation**: Only used for UPI installations; templates in `cloudformation_templates/`
- **Day 1 configs**: MachineConfigs and network settings in `day1_config/` applied during installation
- **Critical components**: Never remove `cluster-ingress`, `cluster-oauth`, `openshift-config`, or `openshift-gitops-admin-config` from base ApplicationSets

## Security Considerations

### AWS Secrets Manager Integration

**✅ IMPLEMENTED**: AWS credentials are stored in **AWS Secrets Manager** instead of being passed as plaintext to the bastion.

**How It Works:**

1. **Config Files**: You still edit AWS credentials in `config/*.config` files (simple workflow)
2. **Secret Storage**: `init_openshift_installation_lab_cluster.sh` stores credentials in AWS Secrets Manager
3. **IAM Role**: Bastion EC2 instance gets an IAM instance profile with permission to read the secret
4. **Bastion Retrieval**: `bastion_script.sh` retrieves credentials from Secrets Manager (not from uploaded config)
5. **Automatic Cleanup**: `clean_aws_tenant.sh` deletes ALL secrets when cleaning the environment

**Security Benefits:**

✅ **No plaintext upload**: AWS credentials are NOT uploaded to bastion in config files
✅ **No process environment exposure**: Credentials not visible in `/proc/$PID/environ` from config
✅ **Encrypted at rest**: Secrets Manager encrypts data with AWS KMS
✅ **Encrypted in transit**: Retrieved via TLS (AWS API calls)
✅ **Audit trail**: CloudTrail logs all secret access
✅ **IAM-based access**: Only bastion instance profile can read the secret
✅ **Automatic deletion**: Secrets purged during environment cleanup (idempotent)

**What's Still in Plaintext:**

⚠️ **Cluster passwords** (`OCP_ADMIN_PASSWORD`, `OCP_NON_ADMIN_PASSWORD`) remain in `config/common.config`:
- These are NOT AWS credentials (no AWS resource access)
- Only used to configure OCP cluster authentication
- Acceptable risk for demo/lab environments (30h lifespan, dedicated clusters)

⚠️ **Local config files** still contain AWS credentials for initial setup:
- Required for local AWS CLI access (Secrets Manager API calls, bastion provisioning)
- Protected by local workstation security (file permissions, disk encryption)
- Should be deleted after cluster destruction

**Resources Created:**

For each cluster deployment, the following resources are created and cleaned up:

1. **Secrets Manager Secret**: `ocp-installer/${CLUSTER_NAME}/aws-credentials`
   - Contains: `aws_access_key_id`, `aws_secret_access_key` (JSON)
   - Region: Same as `AWS_DEFAULT_REGION`
   - Deletion: Force delete without recovery period during cleanup

2. **IAM Role**: `ocp-bastion-secrets-reader-${CLUSTER_NAME}`
   - Trust policy: Allows EC2 service to assume role
   - Inline policy: Read-only access to the specific secret
   - Deletion: Inline policies removed, then role deleted during cleanup

3. **IAM Instance Profile**: `ocp-bastion-profile-${CLUSTER_NAME}`
   - Attached to bastion EC2 instance
   - Links to IAM role above
   - Deletion: Role detached, then profile deleted during cleanup

**Idempotent Behavior:**

- **Re-running installation**: Secrets/IAM resources are deleted first, then recreated
- **Failed installations**: Next run cleans up orphaned secrets/roles before starting fresh
- **Multiple clusters**: Each cluster gets its own secret/role (isolated by CLUSTER_NAME)

**Best Practices (Even with Secrets Manager):**

1. **Use temporary credentials**: Generate short-lived IAM credentials from RHDP (auto-expire with environment)
2. **Delete local config files**: Remove `config/*.config` after cluster destruction
3. **Verify cleanup**: Ensure `clean_aws_tenant.sh` completes successfully
4. **Clean output directory**: Delete `output/` directory after teardown

**For Production Adaptation:**

If using this tool as a base for production systems:
- ✅ Secrets Manager integration is already implemented (production-ready for AWS credentials)
- ⚠️ Consider adding OCP passwords to Secrets Manager as well
- ✅ Implement credential rotation policies in Secrets Manager
- ✅ Enable AWS CloudTrail for audit logging
- ✅ Use dedicated IAM users with minimal permissions (not RHDP admin credentials)

### Job Resource Management (BestEffort QoS)

**Pattern**: All GitOps configuration Jobs run without resource limits (BestEffort QoS class).

**Why No Resource Limits:**

This is an **intentional design decision** for Day 2 configuration Jobs:

1. **Short-lived execution**: Jobs complete within minutes during cluster initialization
2. **Non-critical timing**: Day 2 setup is not latency-sensitive
3. **Resource availability**: Demo/lab clusters have adequate capacity during bootstrap
4. **Maximum performance**: Jobs can consume available resources for faster completion
5. **Simplicity**: Avoids complexity of testing and tuning limits for 17+ different Jobs

**Job Lifecycle:**

- ✅ Execute during initial ArgoCD sync (Day 2 configuration phase)
- ✅ Complete and terminate (pods cleaned up automatically)
- ✅ Do not run continuously (unlike Deployments/DaemonSets)
- ✅ Idempotent design allows re-execution if needed

**BestEffort Behavior:**

Without resource requests/limits, Jobs get:
- **QoS Class**: BestEffort (lowest priority for eviction)
- **CPU**: Can use all available CPU if cluster is idle
- **Memory**: Can use all available memory if cluster is idle
- **Eviction**: First to be evicted if cluster resources are exhausted (acceptable for setup jobs)

**When This Pattern is Acceptable:**

- ✅ Demo/lab environments with adequate cluster resources
- ✅ Short-lived bootstrap/setup operations
- ✅ Jobs that complete during initial cluster provisioning
- ✅ Non-production workloads where QoS guarantees are not required

**When to Add Resource Limits:**

- ❌ Production environments with strict resource governance
- ❌ Long-running or recurring Jobs
- ❌ Multi-tenant clusters with resource contention
- ❌ Jobs that must complete within SLA time windows

**Decision**: Keep Jobs at BestEffort QoS for demo/lab use case. Jobs need maximum available resources during Day 2 initialization for fastest completion.

## GitOps Patterns

### ❌ Static Manifest + ignoreDifferences Pattern (DOES NOT WORK)

We experimented with a **Static Manifest + ignoreDifferences** pattern for managing resources with ArgoCD. **This pattern FAILED in practice and should NOT be used.**

**🚨 CRITICAL ISSUE - Pattern is Logically Contradictory:**

**The Problem:**
```yaml
# Static manifest declares desired state:
spec:
  fieldToManage: value

# ignoreDifferences tells ArgoCD:
ignoreDifferences:
- jsonPointers:
  - /spec/fieldToManage  # "Ignore this field in diffs"
```

**Result:** ArgoCD **NEVER APPLIES** the field it's told to ignore.

This creates a **logical contradiction**:
- Static manifest says: "This is the desired state"
- ignoreDifferences says: "Ignore this field"
- ArgoCD behavior: Field is never synced/applied

**Real-world failures:**

1. **IngressController + defaultCertificate:**
   - Static file declared `defaultCertificate: ingress-certificates`
   - ignoreDifferences said "ignore /spec/defaultCertificate"
   - Result: Certificate NEVER configured → SSL errors ❌

2. **Console + plugins (shared resource):**
   - 4 components with static Console manifests
   - Each component overwrites the others
   - Result: Only last component's plugins active ❌

**❌ DO NOT USE THIS PATTERN**

**✅ Use Instead:**
- **Pure Jobs** for runtime patching (proven reliable)
- Let ArgoCD manage fields WITHOUT ignoreDifferences
- Accept that some drift is normal for operator-managed resources

### Job Template Refactoring and Kustomize Security Boundaries

**The Question:** Should we extract duplicate Job definitions into shared templates to follow DRY principles?

**The Answer:** Not always - **Kustomize security model prevents cross-component template sharing**.

**Kustomize Security Restriction:**
Kustomize enforces that all resources must be within or below the kustomization root directory. You **cannot** reference resources from parent or sibling directories:

```yaml
# ❌ DOES NOT WORK - Security violation
resources:
  - ../../common/job-templates/my-job.yaml  # Outside component boundary
  - ../../../shared/templates/job.yaml      # Path traversal blocked
```

**Error message:**
```
error: security; file '/path/to/template.yaml' is not in or below '/path/to/component'
```

**This is intentional** - prevents path traversal attacks and enforces component isolation.

**Duplication Example - Loki S3 Secret Jobs:**

Two components create near-identical Jobs (99% duplication):
- `components/openshift-logging/base/openshift-gitops-job-create-secret-logging-loki-s3.yaml` (41 lines)
- `components/network-observability/overlays/with-loki/openshift-gitops-job-create-secret-netobserv-loki-s3.yaml` (41 lines)

Differences: Only component name (`logging` vs `netobserv`) and namespace (`openshift-logging` vs `netobserv`).

**Why NOT Refactored:**
1. ✅ **Only 2 instances** - "Rule of Three" not yet met (refactor on 3rd occurrence)
2. ✅ **Kustomize security** prevents shared templates across components
3. ✅ **Jobs are stable** - rarely change, low maintenance burden
4. ✅ **Isolation is valuable** - components remain self-contained and portable

**When to Refactor Jobs:**
- ✅ **Within same component** - Create base + overlays with patches
- ✅ **3+ identical jobs** - Consider if duplication cost exceeds complexity cost
- ❌ **Cross-component sharing** - Blocked by Kustomize security model
- ❌ **2 instances only** - Premature optimization, YAGNI principle

**Workarounds for Cross-Component Sharing (not recommended):**
1. **Copy jobs to components/common/** - But common would deploy the template job itself (with placeholders)
2. **Use Kustomize components feature** - Complex, requires every consumer to apply the component
3. **Generator plugins** - Overly complex for simple jobs

**Decision:** Accept intentional duplication when Kustomize security boundaries make sharing impractical. Favor simplicity and component isolation over DRY absolutism.

### OLM Subscription installPlanApproval Pattern

**Pattern**: Rely on OLM default behavior for `installPlanApproval` (omit field from manifests).

**OLM Default Behavior:**
When `installPlanApproval` is not specified in a Subscription manifest, OLM defaults to **`Automatic`** (not `Manual`).

**Source:** OpenShift OLM documentation and observed cluster behavior.

**Project Standard:**

Our Subscription manifests **intentionally omit** the `installPlanApproval` field:

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: my-operator
  namespace: my-namespace
spec:
  channel: stable
  name: my-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  # installPlanApproval: Automatic  ← OMITTED (rely on OLM default)
```

**Why omit instead of explicit `Automatic`?**
1. ✅ **Less boilerplate** - No need to add redundant field to 25+ files
2. ✅ **Standard practice** - Relying on defaults is common in Kubernetes manifests
3. ✅ **OLM behavior is stable** - Default has been `Automatic` for years
4. ✅ **Matches upstream examples** - Red Hat operator documentation examples omit this field

**Current State (26 subscription manifests):**
- 25 subscriptions: Omit `installPlanApproval` → OLM default = `Automatic`
- 1 subscription: Explicit `Automatic` (ack-route53 - copied from community example)

**Exception - RHOAI-Installed Service Mesh:**

The cluster has one subscription with `installPlanApproval: Manual` that is **NOT in our manifests**:
- **Subscription**: `servicemeshoperator3` in `openshift-operators`
- **Source**: Automatically installed by RHOAI 3.3 operator (KServe dependency)
- **Reason for Manual**: RHOAI intentionally sets `Manual` to control Service Mesh upgrade timing
- **Purpose**: Prevents automatic mesh upgrades that could break model serving workloads
- **Owner**: Red Hat OpenShift AI operator (not our GitOps manifests)

This is **expected and correct** behavior for RHOAI with KServe enabled.

**When to Add Explicit installPlanApproval:**
- ✅ **Manual approval required** - When you need to review/test upgrades before applying
- ✅ **Upstream dependency requirement** - When an operator (like RHOAI) needs to control upgrade timing
- ❌ **Just for documentation** - No need to add explicit `Automatic` to all files

**Decision:** Continue relying on OLM default (`Automatic`) for all our manifests. Only add explicit values when overriding the default to `Manual`.

### ✅ Shared Resources with ignoreDifferences Pattern (WORKS)

**Pattern**: For cluster-scoped resources that are **partially managed by OpenShift** and **partially configured by GitOps**, use `ignoreDifferences` to prevent deletion loops.

**When to Use:**
- Resource exists at cluster scope (created by installer or operators)
- GitOps only configures a **subset of fields**
- OpenShift/operators manage other fields
- ArgoCD detects drift and tries to delete/recreate the resource
- Deletion is **blocked** (protected system resource)

**Example: Network CR (`networks.config.openshift.io/cluster`)**

**Problem:**
```yaml
# Git manifest (components/cluster-network/base/cluster-network-cluster.yaml)
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  networkDiagnostics:  # Only this field configured by GitOps
    sourcePlacement:
      nodeSelector:
        node-role.kubernetes.io/infra: ""

# Actual cluster resource (has OpenShift-managed fields)
spec:
  clusterNetwork: [...]      # Managed by installer
  serviceNetwork: [...]       # Managed by installer
  networkType: OVNKubernetes  # Managed by installer
  networkDiagnostics: [...]   # Managed by GitOps
```

**Without ignoreDifferences:**
1. ArgoCD compares Git (minimal spec) vs Cluster (full spec)
2. Detects drift in `clusterNetwork`, `serviceNetwork`, `networkType`
3. Tries to delete and recreate resource to match Git
4. Deletion fails: `"cluster" is forbidden: deleting required networks.config.openshift.io resource, named cluster, is not allowed`
5. DeletionError condition stuck on Application

**Solution:**
```yaml
# gitops-bases/core/applicationset.yaml
ignoreDifferences:
  - group: config.openshift.io
    kind: Network
    name: cluster
    jsonPointers:
      - /spec/clusterNetwork
      - /spec/serviceNetwork
      - /spec/networkType
      - /spec/externalIP
```

**Result:**
- ✅ ArgoCD ignores OpenShift-managed fields
- ✅ No deletion attempts
- ✅ GitOps still manages `networkDiagnostics` field
- ✅ No DeletionError conditions

**Other Candidates for This Pattern:**
- Cluster-scoped CRs with installer-managed fields
- Shared resources modified by multiple controllers
- Protected system resources that cannot be deleted

**❌ NOT the Same as Failed Static + ignoreDifferences Pattern:**
- That pattern tried to use ignoreDifferences to **ignore fields in Git**
- This pattern uses ignoreDifferences to **ignore fields NOT in Git** (managed by OpenShift)
- Key difference: We're not declaring AND ignoring the same field

## Component-Specific Notes

### Console Plugins

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

### OpenShift GitOps (ArgoCD)

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
   ```yaml
   rbac:
     defaultPolicy: ''
     policy: |
       g, system:cluster-admins, role:admin
       g, cluster-admins, role:admin
     scopes: '[groups]'
   ```

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

### cert-manager IngressController

**Pattern**: Pure Patch Job (no static manifests)

**Purpose**: Configure the default OpenShift IngressController to use Let's Encrypt certificates managed by cert-manager.

**Why Job only (no static manifest):**
The Static Manifest + ignoreDifferences pattern was **attempted and FAILED** for IngressController. Here's why:

**Problem with Static + ignoreDifferences:**
```yaml
# Static manifest declares:
spec:
  defaultCertificate:
    name: ingress-certificates

# ignoreDifferences says:
ignoreDifferences:
- kind: IngressController
  jsonPointers:
  - /spec/defaultCertificate  # "Ignore this field"
```

**Result:** ArgoCD **never applies** the field it's told to ignore → Certificate not configured → SSL errors ❌

This is a **logical contradiction**: "Here's the config, but ignore it" = Config never applied.

**Working Implementation (Pure Job):**

Job: `openshift-gitops-job-update-openshift-ingress-operator-ingresscontroller-default.yaml`

1. Waits for cert-manager to create Certificate `ingress` in `openshift-ingress`
2. Waits for Certificate to reach Ready condition (Let's Encrypt issued)
3. Patches IngressController with `defaultCertificate: {name: ingress-certificates}`
4. Triggers rolling update of router pods with new certificate

**Zero-downtime behavior:**
- ✅ IngressController starts with auto-generated wildcard certificate (OpenShift default)
- ✅ Ingress/Routes work immediately with self-signed certificate
- ✅ Job waits for Let's Encrypt certificate to be Ready (2-5 minutes)
- ✅ Patch triggers rolling update of router pods (~30 seconds)
- ✅ High availability maintained during certificate rotation (3 replicas)

**Lesson learned:**
- ❌ Static + ignoreDifferences = Field never applied
- ✅ Pure Job = Reliable, predictable, works correctly

### cert-manager Certificate Provisioning

**Pattern**: Dynamic Job with pod readiness checks

**Purpose**: Create ClusterIssuer and Certificate resources after cert-manager operator is fully initialized.

**Critical Race Condition Fixed:**

The Job (`create-cluster-cert-manager-resources`) previously waited only for CertManager CR deployment conditions, which caused a race condition during cluster bootstrap:

**Problem:**
```bash
# Old approach (BROKEN):
oc wait certmanager cluster \
    --for condition=cert-manager-controller-deploymentAvailable \
    --timeout=120s

# Problem: Deployment conditions check that Deployment resource exists,
# NOT that pods are running or controller is initialized
```

**Timeline of race condition:**
1. CertManager CR shows "deploymentAvailable" (Deployment created)
2. Job creates certificates immediately
3. cert-manager pods haven't started yet (may be 60+ seconds later)
4. cert-manager controller tries to process certificates before ACME client initialized
5. Let's Encrypt order created, but authorization fetch fails with 404
6. cert-manager gives up without retry → 1-hour exponential backoff

**Root Cause:**
- CertManager CR conditions reflect **Deployment readiness** (desired replicas exist)
- **Not pod readiness** (containers running and passing readiness probes)
- **Not controller initialization** (ACME client ready to process certificates)

**Fix Applied:**
```bash
# New approach (FIXED):
oc wait certmanager cluster \
    --for condition=cert-manager-controller-deploymentAvailable \
    --timeout=120s

# ADDED: Wait for pods to be Ready (containers running + readiness probes passing)
oc wait pod -n cert-manager \
    -l app.kubernetes.io/component=controller \
    --for=condition=Ready \
    --timeout=120s

oc wait pod -n cert-manager \
    -l app.kubernetes.io/component=webhook \
    --for=condition=Ready \
    --timeout=120s
```

**Why this works:**
- Pod `Ready` condition ensures containers are running
- cert-manager readiness probe confirms controller is responsive
- ACME client has time to initialize before certificates are created
- Webhook pod must be ready before validating Certificate resources

**Time added:** ~30-60 seconds (pod startup time)

**Evidence from production issue:**
- Cluster deployed 2026-03-22 at 20:09 UTC
- CertManager CR showed "Available" at 20:09:01
- Job created certificates at 20:09:19 (18 seconds later)
- cert-manager pods didn't start until 20:10:26 (77 seconds after CR "ready")
- API certificate failed with "ACME client not initialised" error
- Ingress certificate succeeded 4 minutes later (cluster fully stable by then)
- Auto-retry at 21:09:21 succeeded (1-hour exponential backoff)

**Lesson learned:**
- CertManager CR conditions ≠ cert-manager controller ready
- Always wait for pod `Ready` condition when controller initialization matters
- Deployment conditions only guarantee Deployment resource exists, not pod state

### OpenShift Data Foundation (ODF)

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

### OpenShift Pipelines (Tekton)

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

### AWS Controllers for Kubernetes (ACK) - Route53

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

### Cluster Observability Operator

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

### Red Hat Connectivity Link (RHCL) - Kuadrant

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

**Installation**: Part of the `rh-connectivity-link` gitops-base, included in profiles with API gateway capabilities.

### Red Hat build of Keycloak (RHBK)

**Purpose**: Provides enterprise-grade identity and access management (IAM) with SSO, authentication, and authorization capabilities.

**Installation**: Deployed in `keycloak` namespace with dedicated PostgreSQL database in `databases-keycloak` namespace.

**Namespace**: `keycloak`

**OperatorGroup**: `rhbk-operator`
- Target namespaces: `keycloak` only (single-namespace mode)
- Keycloak CRs can only be created in `keycloak` namespace

**Operator Subscription:**

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: keycloak
spec:
  channel: stable-v26.4
  config:
    nodeSelector:
      node-role.kubernetes.io/infra: ""
    tolerations:
      - key: node-role.kubernetes.io/infra
        operator: Exists
  name: rhbk-operator
  source: redhat-operators
```

**Infrastructure Node Placement:**

RHBK operator pods run on infrastructure nodes via subscription nodeSelector and tolerations.

**PostgreSQL Database:**

The component includes a dedicated PostgreSQL 13 database for Keycloak in the `databases-keycloak` namespace:

**Namespace**: `databases-keycloak`
- Separate namespace for database isolation
- Label: `argocd.argoproj.io/managed-by: openshift-gitops`

**Database Resources:**

1. **Secret**: `keycloak-db`
   - Credentials: `keycloak/keycloak` (user/password)
   - Database name: `keycloak`
   - No sync-wave annotations (simple deployment)

2. **PersistentVolumeClaim**: `keycloak-db`
   - Storage: 5Gi
   - Access Mode: ReadWriteOnce

3. **Service**: `keycloak-db`
   - Port: 5432 (postgresql)
   - Type: ClusterIP
   - Selector: `app.kubernetes.io/name: keycloak-db`

4. **Deployment**: `keycloak-db`
   - Image: `registry.redhat.io/rhel8/postgresql-13:1`
   - Replicas: 1
   - Strategy: Recreate (single replica database)
   - Resources: 100m/128Mi request, 250m/256Mi limit
   - Probes: liveness (tcpSocket), readiness (psql exec)
   - Volume: Persistent storage at `/var/lib/pgsql/data`

**Database Connection Details:**

```
Host: keycloak-db.databases-keycloak.svc
Port: 5432
Database: keycloak
Username: keycloak
Password: keycloak

JDBC URL: jdbc:postgresql://keycloak-db.databases-keycloak.svc:5432/keycloak
```

**Version Management:**

Operator channel managed via `cluster-versions` ConfigMap:
- `rhbk-operator: stable-v26.4`

**Component Structure:**

```
components/keycloak/
├── base/
│   ├── cluster-namespace-keycloak.yaml
│   ├── cluster-namespace-databases-keycloak.yaml
│   ├── keycloak-operatorgroup-rhbk-operator.yaml
│   ├── keycloak-subscription-rhbk-operator.yaml
│   ├── databases-keycloak-secret-keycloak-db.yaml
│   ├── databases-keycloak-pvc-keycloak-db.yaml
│   ├── databases-keycloak-service-keycloak-db.yaml
│   ├── databases-keycloak-serviceaccount-keycloak-db.yaml
│   ├── databases-keycloak-deployment-keycloak-db.yaml
│   └── kustomization.yaml
└── overlays/
    └── default/
        └── kustomization.yaml
```

**Design Decisions:**

1. **Separate Database Namespace**: Isolates database from Keycloak application for security and organization
2. **Single Replica Database**: Recreate strategy ensures data consistency (acceptable for demo/lab environments)
3. **Minimal Labels/Annotations**: Clean manifests without unnecessary metadata
4. **Infrastructure Node Placement**: Operator pods on infra nodes (database on worker nodes - acceptable for demo/lab)
5. **Plain Secret**: Database credentials in unencrypted secret (acceptable for demo/lab with 30h lifespan)

**Keycloak Instance Configuration:**

The component deploys a Keycloak CR with the following configuration:

```yaml
spec:
  instances: 1
  db:
    vendor: postgres
    host: keycloak-db.databases-keycloak.svc
    database: keycloak
    usernameSecret: {name: keycloak-db-secret, key: database-user}
    passwordSecret: {name: keycloak-db-secret, key: database-password}
  http:
    httpEnabled: true  # Backend uses HTTP (route does TLS termination)
  ingress:
    enabled: false     # Using OpenShift Route instead
  hostname:
    strict: false      # Auto-detect hostname from incoming requests
```

**Route Configuration:**

```yaml
spec:
  port:
    targetPort: http   # Service exposes HTTP on port 8080
  tls:
    termination: edge  # TLS termination at route level
    insecureEdgeTerminationPolicy: Redirect
  to:
    kind: Service
    name: keycloak-service
```

**Hostname Management:**

Keycloak uses `hostname.strict: false` to **auto-detect the hostname from incoming HTTP requests**. This eliminates the need for:
- ❌ Hardcoded placeholder hostnames in manifests
- ❌ Dynamic hostname update Jobs
- ❌ ArgoCD ignoreDifferences configuration

The Keycloak operator automatically creates the `keycloak-service` with ports:
- `8080` (http) - Main Keycloak endpoint
- `9000` (management) - Management interface

**Why this works:**
- Route terminates TLS and forwards HTTP to backend service port 8080
- Keycloak receives requests with the actual route hostname in HTTP headers
- With `strict: false`, Keycloak uses that hostname for redirects
- No static configuration or patching needed

**Installation**: Part of the `core` gitops-base, automatically deployed in all profiles.

## Monitoring and Alert Management

### Alertmanager Configuration

The cluster Alertmanager (`alertmanager-main` in `openshift-monitoring`) is managed via GitOps in the `cluster-monitoring` component.

**Location:** `components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml`

**Configuration includes:**
- **Global settings:** HTTP proxy, timeout values
- **Inhibit rules:** Suppress lower-severity alerts when higher-severity alerts are firing
- **Receivers:** Notification endpoints (Default, Watchdog, Critical, null)
- **Routes:** Alert routing logic and silences

### Alert Silences for Known Bugs

**IMPORTANT:** The project maintains a dedicated document for tracking known operator bugs that generate false-positive alerts.

**See:** [`KNOWN_BUGS.md`](KNOWN_BUGS.md) for comprehensive documentation of:
- Silenced alerts and their root causes
- Impact assessment and workarounds
- Upstream bug tracking status
- Verification commands
- Audit procedures

**Current silenced alerts:**
1. **mlflow-operator TargetDown** - RHOAI mlflow-operator v2.0.0 has broken metrics endpoint ServiceMonitor (JIRA: RHOAIENG-54791)
2. **llama-stack PodDisruptionBudgetAtLimit** - RHOAI llama-stack operator PDB with 1 replica (JIRA: RHAIENG-3783)
3. **NooBaa database PodDisruptionBudgetAtLimit** - ODF NooBaa single-replica PostgreSQL PDB (JIRA: DFBUGS-5294)
4. **InsightsRecommendationActive (webhook timeout)** - Kueue webhook timeout recommendation (JIRA: OCPKUEUE-578)
5. **InsightsRecommendationActive (config migration)** - Insights Operator config migration recommendation

### Adding New Alert Silences

**IMPORTANT:** To fully silence an alert, you need BOTH routing configuration AND an Alertmanager silence.

When a new false-positive alert is discovered:

1. **Verify it's actually a bug** (not a real issue requiring a fix)
2. **Document in KNOWN_BUGS.md** with full details
3. **Add route to `null` receiver** in Alertmanager config (prevents notifications)
4. **Create Alertmanager silence via API** (hides from web console)
5. **Run audit script** to ensure no secrets leaked
6. **Commit** (KNOWN_BUGS.md + alertmanager secret)

**Understanding Routing vs Silencing:**

There are two different mechanisms for suppressing alerts:

| Mechanism | Routing to `null` | Alertmanager Silence |
|-----------|------------------|---------------------|
| **What it does** | Routes alert to null receiver | Suppresses alert entirely |
| **Prevents notifications** | ✅ Yes (no email, Slack, etc.) | ✅ Yes |
| **Hides from console** | ❌ No (shows as "active") | ✅ Yes (shows as "suppressed") |
| **Managed by** | GitOps (alertmanager.yaml) | API (ephemeral state) |
| **Survives upgrades** | ✅ Yes (in Git) | ✅ Yes (persisted to PVC) |
| **Survives PVC deletion** | ✅ Yes | ❌ No |
| **Expires** | ❌ Never | ⚠️ After 10 years |

**You need BOTH:**
- Routing ensures no notifications even if silence expires
- Silence hides alert from console UI

**Example routing configuration:**
```yaml
# components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
routes:
  # BUG: [Short description]
  # Component: [Operator name]
  # Issue: [Root cause]
  # Impact: [What happens]
  # Status: [Bug tracker link]
  - matchers:
      - alertname = TargetDown
      - service = broken-metrics-service
      - namespace = operator-namespace
    receiver: 'null'
    continue: false
```

**Example silence creation:**
```bash
# Create silence payload (10-year duration)
cat > /tmp/alert-silence.json <<EOF
{
  "matchers": [
    {"name": "alertname", "value": "TargetDown", "isRegex": false, "isEqual": true},
    {"name": "service", "value": "broken-metrics-service", "isRegex": false, "isEqual": true},
    {"name": "namespace", "value": "operator-namespace", "isRegex": false, "isEqual": true}
  ],
  "startsAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",
  "endsAt": "$(date -u -d '+10 years' +%Y-%m-%dT%H:%M:%S.000Z)",
  "createdBy": "admin",
  "comment": "Known bug: [description] - See KNOWN_BUGS.md"
}
EOF

# Apply via API
oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093 &
sleep 3
curl -X POST -H "Content-Type: application/json" \
  --data @/tmp/alert-silence.json http://localhost:9093/api/v2/silences
```

**See KNOWN_BUGS.md for complete step-by-step instructions.**

### Automated Alert Silences via GitOps

**IMPORTANT:** Alert silences are now **fully automated** via an ArgoCD PostSync Job!

The manual silence creation steps above are kept for reference, but in practice, all known bug silences are created automatically when the cluster-monitoring component syncs.

**How it works:**

1. **PostSync Job** (`openshift-monitoring-job-create-alert-silences.yaml`):
   - Runs automatically after cluster-monitoring ApplicationSet syncs
   - Waits for Alertmanager StatefulSet and pods to be fully ready
   - **Additional 30-second stabilization wait** (ensures API is fully initialized)
   - Creates 10-year silences via Alertmanager API for all known bugs
   - **Retry logic**: 3 attempts per silence with 5-second delays
   - **Verification**: Confirms each silence was created successfully via API query
   - **Final validation**: Verifies 5+ active silences exist before completing
   - **Fails loudly**: Job fails if any silence creation fails (no silent failures)

2. **RBAC Resources**:
   - ServiceAccount: `create-alert-silences`
   - Role: permissions for pods/portforward and statefulsets
   - RoleBinding: connects SA to Role

3. **Known bugs silenced automatically**:
   - mlflow-operator TargetDown (broken metrics endpoint) (JIRA: RHOAIENG-54791)
   - llama-stack PodDisruptionBudgetAtLimit (JIRA: RHAIENG-3783)
   - NooBaa database PodDisruptionBudgetAtLimit (JIRA: DFBUGS-5294)
   - InsightsRecommendationActive (webhook timeout) (JIRA: OCPKUEUE-578)
   - InsightsRecommendationActive (config migration)

**Reliability Improvements (2026-03-23):**

The Job was improved to address timing issues that caused silent failures:

**Problem:** Original Job used `|| true` to mask failures and had no verification. When Alertmanager wasn't fully initialized, silences failed to create but Job reported success.

**Fixed:**
- ✅ **Removed `|| true`** - Failures now propagate properly
- ✅ **Added pod readiness check** - Waits for pods to be Running AND Ready
- ✅ **Added 30-second stabilization wait** - Ensures Alertmanager API is fully initialized
- ✅ **Added retry logic** - 3 attempts per silence with exponential backoff
- ✅ **Added verification** - Queries API to confirm silence exists after creation
- ✅ **Added final validation** - Counts active silences and fails if < 5
- ✅ **Better logging** - Clear success/failure messages for each silence

**Benefits:**
- ✅ **Zero manual intervention** on new cluster deployments
- ✅ **No false-positive alerts visible** from first cluster-admin login
- ✅ **GitOps-managed** - Job is version controlled and reproducible
- ✅ **Fully automated** - works reliably across all environments
- ✅ **Self-healing** - Automatic retry on transient failures
- ✅ **Verifiable** - Job exit code reflects actual success/failure

**Location:** `components/cluster-monitoring/base/openshift-monitoring-job-create-alert-silences.yaml`

**Implementation:** Uses `openshift/cli` image with native bash tools (grep/sed) to parse JSON API responses - no external dependencies required.

### Security - No Secrets in Alertmanager Config

**⚠️ CRITICAL:** The Alertmanager configuration is stored in Git and must NOT contain sensitive data.

**Prohibited:**
- ❌ API tokens or keys
- ❌ Webhook URLs with embedded credentials
- ❌ Email/Slack/PagerDuty passwords
- ❌ Any authentication secrets

**Allowed:**
- ✅ Routing logic (matchers, grouping)
- ✅ Alert silences
- ✅ Inhibit rules
- ✅ Empty receiver placeholders

**Audit script:** `scripts/audit_alertmanager_secrets.sh` (see KNOWN_BUGS.md)

If you need to add actual notification receivers with credentials:
1. Use Kubernetes Secret references in receiver config
2. Store credentials in separate Secrets (not in alertmanager.yaml)
3. Keep alertmanager.yaml credential-free for GitOps

### Alertmanager Behavior

**After changes:**
1. ArgoCD syncs the Secret to cluster
2. Cluster Monitoring Operator detects change
3. Alertmanager pods reload config (~30 seconds)
4. New routes/silences become active
5. Verify in Alertmanager logs: `oc logs -n openshift-monitoring alertmanager-main-0 -c alertmanager`

**Operator interaction:**
- ✅ Cluster Monitoring Operator will NOT reset this Secret (documented exception)
- ✅ Configuration persists across operator restarts and upgrades
- ✅ ArgoCD manages the Secret exclusively (don't use `oc edit`)

### User Workload Monitoring

The project does NOT enable a separate user-workload Alertmanager instance. All alerts (platform + user-defined) route through the cluster Alertmanager (`alertmanager-main`).

**Configuration:** `components/user-workload-monitoring/base/openshift-user-workload-monitoring-configmap-user-workload-monitoring-config.yaml`

**Key settings:**
- Alertmanager storage (10Gi PVC)
- Prometheus storage (40Gi PVC)
- Infrastructure node placement for all components
- **No** dedicated Alertmanager instance (`alertmanager.enabled: false` - default)

### Red Hat Insights Recommendations

Red Hat Insights provides cloud-based analysis and recommendations for OpenShift clusters. Recommendations generate `InsightsRecommendationActive` alerts in the cluster that must be suppressed via Alertmanager.

**Configuration:**
- `components/openshift-config/base/openshift-config-secret-support.yaml` (documentation only)
- `components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml` (alert routing)
- `components/cluster-monitoring/base/openshift-monitoring-job-create-alert-silences.yaml` (automated silences)

**How It Works:**
- Insights Operator runs in `openshift-insights` namespace
- Periodically scans cluster configuration and sends data to Red Hat cloud service
- Red Hat cloud service analyzes data and sends recommendations back to cluster
- Recommendations generate `InsightsRecommendationActive` alerts with `severity: info`
- Recommendations appear in **Red Hat Hybrid Cloud Console**: https://console.redhat.com/openshift/insights/advisor
- **Note:** Insights UI is NOT in local OpenShift web console (only in Red Hat cloud console)
- **CRITICAL:** `disabled_recommendations` in `support` Secret does NOT suppress alerts (documentation only)
- **Alerts must be suppressed via Alertmanager** (routing to null receiver + API silences)

**Suppressing InsightsRecommendationActive Alerts:**

**CRITICAL:** The `disabled_recommendations` field in the `support` Secret does NOT suppress alerts in the OpenShift console. The Red Hat cloud service generates recommendations regardless of local configuration and sends them back to the cluster as Prometheus metrics.

**Working approach** (implemented):

1. **Alertmanager Routing** - Routes alerts to null receiver (prevents notifications):
   ```yaml
   # components/cluster-monitoring/base/openshift-monitoring-secret-alertmanager-main.yaml
   - matchers:
       - alertname = InsightsRecommendationActive
       - description =~ .*webhook.*timeout.*13s.*
     receiver: 'null'
   ```

2. **Alertmanager API Silences** - Fully suppresses alerts (state: "suppressed"):
   - Created automatically by PostSync Job
   - 10-year duration, persisted to Alertmanager PVC
   - Recreated on every cluster deployment
   - See: `components/cluster-monitoring/base/openshift-monitoring-job-create-alert-silences.yaml`

**Currently Suppressed Recommendations:**

1. **Kueue Webhook Timeout** - `webhook_timeout_is_larger_than_default`
   - JIRA: OCPKUEUE-578
   - Reason: Kueue requires extended timeout for complex validations
   - Suppression: Alertmanager routing + API silence

2. **Insights Operator Configuration Location** - `io_415_change_config_location`
   - Issue: Documentation suggests ConfigMap migration in OCP 4.15+
   - Reality: Insights Operator in OCP 4.20 still expects Secret (ConfigMap requires TechPreview feature gates)
   - Reason: Implementation hasn't been updated to match documentation
   - Suppression: Alertmanager routing + API silence

**Why disabled_recommendations doesn't work:**

The `support` Secret's `disabled_recommendations` field is intended to control what data the Insights Operator GATHERS, not what alerts appear in the cluster. However:
- OCP 4.20 appears to ignore this field (may require `InsightsConfig` feature gate)
- Even if honored, it only affects data gathering, not the alerts
- Red Hat cloud service analyzes whatever data it receives and sends recommendations back
- Recommendations become Prometheus metrics (`insights_recommendation_active`) which trigger alerts
- Only Alertmanager can suppress these alerts

**Configuration retained for documentation:**
```yaml
# components/openshift-config/base/openshift-config-secret-support.yaml
# NOTE: This does NOT suppress alerts - kept for documentation only
insights:
  disabled_recommendations:
    - rule_id: "ccx_rules_ocp.external.rules.webhook_timeout_is_larger_than_default"
    - rule_id: "ccx_rules_ocp.external.rules.io_415_change_config_location"
```

**Verification:**

```bash
# Check alert silences are active
oc port-forward -n openshift-monitoring alertmanager-main-0 9093:9093 &
sleep 3
curl -s http://localhost:9093/api/v2/silences | \
  grep -o '"comment":"[^"]*Insights[^"]*"'

# Check InsightsRecommendationActive alerts are suppressed
curl -s http://localhost:9093/api/v2/alerts | \
  python3 -c "import sys, json; alerts = json.load(sys.stdin); \
  [print(f\"{a['labels']['description'][:60]}... => {a['status']['state']}\") \
  for a in alerts if a['labels']['alertname'] == 'InsightsRecommendationActive']"

# Expected output: state should be "suppressed"
# The Insights Operator config has been migrated from secret t... => suppressed
# Configuring the webhook's timeout for Pod API exceeds 13s is... => suppressed

# Check automated silence Job logs
oc logs -n openshift-monitoring job/create-alert-silences | grep -i insights
```

**Insights Recommendations vs Standard Prometheus Alerts:**

| Aspect | Standard Prometheus Alerts | InsightsRecommendationActive Alerts |
|--------|---------------------------|-------------------------------------|
| **Source** | Cluster monitoring stack | Red Hat cloud service via Insights Operator |
| **Alert Suppression** | Alertmanager (routing + silences) | **Same:** Alertmanager (routing + silences) |
| **Management** | components/cluster-monitoring | components/cluster-monitoring |
| **Recommendation Visibility** | N/A | Red Hat console: console.redhat.com/openshift/insights |
| **Reload Time** | ~30 seconds (Alertmanager) | 24-48 hours (Red Hat cloud analysis) |
| **GitOps** | ✅ Partial (routing only, silences via Job) | ✅ Same (routing + automated Job silences) |
| **disabled_recommendations** | N/A | ❌ Does NOT suppress alerts (ineffective) |

## Troubleshooting

- Check bastion UserData logs: `/var/log/cloud-init-output.log` on bastion
- Check installation logs: `~/bastion_execution.log` on bastion (tails automatically in tmux)
- For UPI: CloudFormation stacks follow naming: `<cluster-name>-cfn-<component>`
- CSR issues: Use `approve_cluster_csrs.sh` after cluster hibernation/restart
- AWS cleanup: `clean_aws_tenant.sh` removes all resources matching cluster name
