# Installation Flow and Session Management

**Purpose**: Guide to cluster installation process, session recovery, and output management.

## Installation Flow

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

## Session Recovery

The tool supports robust recovery from network interruptions:

- **Session files** stored in `output/`:
  - `.bastion_session_<config>.info` - SSH connection details
  - `.bastion_provisioning_<config>.info` - Bastion instance ID during creation
- **Recovery behavior**:
  - Re-running the script detects active sessions and prompts to resume
  - Reattaches to existing tmux session on bastion
  - Detects partially-provisioned bastion instances and resumes waiting

## Output Directory Structure

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

## Helper Scripts

```bash
# Approve pending cluster CSRs (for node recovery after shutdown)
./scripts/approve_cluster_csrs.sh <BASTION_HOST> <SSH_KEY>
# Example:
./scripts/approve_cluster_csrs.sh ec2-x-x-x-x.compute.amazonaws.com output/bastion_mycluster.pem

# Manually clean AWS resources (use with caution - normally auto-invoked)
./scripts/clean_aws_tenant.sh <AWS_KEY> <AWS_SECRET> <REGION> <CLUSTER_NAME> <DOMAIN>
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
