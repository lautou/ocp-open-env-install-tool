# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is an OpenShift Container Platform (OCP) installation tool designed for Red Hat Demo Platform AWS Blank Open Environment labs. It automates cluster provisioning on AWS with extensive Day 2 configuration through a Profile-Based GitOps architecture.

Supports both **IPI** (Installer-Provisioned Infrastructure) and **UPI** (User-Provisioned Infrastructure) installation methods.

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
     - `ocp-ai` - Standard + RHOAI + GPU operators + Kueue
     - `ocp-acs-central` - Standard + ACS Central server
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
   - Applies `day2_config/applications/app-of-apps.yaml` pointing to selected profile
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
- **Profile paths**: `GITOPS_PROFILE_PATH` must point to existing profile in `gitops-profiles/`
- **Git repo**: Default points to upstream; fork and update `GIT_REPO_URL` in `common.config` for custom changes
- **CloudFormation**: Only used for UPI installations; templates in `cloudformation_templates/`
- **Day 1 configs**: MachineConfigs and network settings in `day1_config/` applied during installation
- **Critical components**: Never remove `cluster-ingress`, `cluster-oauth`, `openshift-config`, or `openshift-gitops-admin-config` from base ApplicationSets

## Component-Specific Notes

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

## Troubleshooting

- Check bastion UserData logs: `/var/log/cloud-init-output.log` on bastion
- Check installation logs: `~/bastion_execution.log` on bastion (tails automatically in tmux)
- For UPI: CloudFormation stacks follow naming: `<cluster-name>-cfn-<component>`
- CSR issues: Use `approve_cluster_csrs.sh` after cluster hibernation/restart
- AWS cleanup: `clean_aws_tenant.sh` removes all resources matching cluster name
