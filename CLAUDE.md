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

# Show help
./init_openshift_installation_lab_cluster.sh --help
```

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

**Recommendation**: Always explicitly set `profile: all` in `components/openshift-pipelines/base/cluster-tektonconfig-config.yaml` if you want the complete OpenShift Pipelines experience with console integration.

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

## Troubleshooting

- Check bastion UserData logs: `/var/log/cloud-init-output.log` on bastion
- Check installation logs: `~/bastion_execution.log` on bastion (tails automatically in tmux)
- For UPI: CloudFormation stacks follow naming: `<cluster-name>-cfn-<component>`
- CSR issues: Use `approve_cluster_csrs.sh` after cluster hibernation/restart
- AWS cleanup: `clean_aws_tenant.sh` removes all resources matching cluster name
