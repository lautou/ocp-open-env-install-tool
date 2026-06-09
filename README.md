# OpenShift Container Platform setup on Red Hat Demo Platform Open Environment Lab for Red Hat Consulting team

The purpose of this project is to help the Red Hat Consulting team quickly setup an OpenShift cluster using an AWS Blank Open Environment [Red Hat Demo Platform](https://demo.redhat.com) item.

It supports both **IPI (Installer-Provisioned Infrastructure)** and **UPI (User-Provisioned Infrastructure)** methods for installation on AWS.

The entire installation process, including Day 2 configuration, takes about 1 hour or more.

This OCP installation includes a rich set of optional Day 2 components deployed via a **Profile-Based GitOps Architecture**, such as:
* **Storage:** OpenShift Data Foundation (ODF) in MultiCloud Gateway only (MCG) or Full modes (Lean, Balanced, Performance).
* **Integration:** OpenShift Service Mesh, Red Hat Connectivity Link (Kuadrant API Gateway), Red Hat build of Keycloak operator (RHBK - no instances).
* **Observability:** Logging (Pico, Small, Medium), Loki, Monitoring, Tempo, OpenTelemetry, Network Observability (with or without Loki).
* **Security:** Red Hat Advanced Cluster Security (ACS) - Central or Secured Cluster modes.
* **Management:** Red Hat Advanced Cluster Management (ACM) - Hub or Managed modes.
* **AI/ML:** Red Hat OpenShift AI (RHOAI), Nvidia GPU Operator, Kueue.
* **CI/CD:** OpenShift GitOps, Pipelines, Builds.
* **Utilities:** cert-manager, Sealed Secrets, WebTerminal, Node Feature Discovery, AWS Controllers for Kubernetes (ACK) Route53.

---

## ✨ Key Features

* **Multi-Configuration Support:** Manage different cluster types (e.g., `standard`, `odf-full`, `ai`, `acs-central`) from a single codebase using dedicated config files.
* **Clean Workspace:** All runtime artifacts (keys, logs, sessions) are isolated in an `output/` directory.
* **Parallel Execution:** Run multiple cluster installations simultaneously on different AWS accounts or regions without conflict.
* **Robust Recovery:**
    * **Auto-Resume:** If your network drops, simply rerun the script to reattach to the session.
    * **Provisioning Recovery:** Detects existing Bastion instances to avoid duplication.
* **Modular GitOps:** Uses a "Lego-like" Component + Base + Profile architecture (Kustomize) for flexible composition.
* **Production-Ready Security:**
    * **Least-Privilege RBAC:** All 20 GitOps Jobs use dedicated ServiceAccounts with minimal permissions (0 cluster-admin usage).
    * **Zero-Trust Network Isolation:** AdminNetworkPolicy + BaselineAdminNetworkPolicy for namespace-level network security.
    * **Secrets Management:** AWS Secrets Manager integration for credential handling.
    * **Air-Gap Compatible:** Uses Red Hat registry images exclusively.

---

## 🚀 Quick Start — Step by Step

> **New user? Follow these steps in order. Skipping any step will break the installation.**

### Step 1 — Fork or Clone the Repository

**Option A: Use as-is (no customization)**
```bash
git clone https://github.com/lautou/ocp-open-env-install-tool.git
cd ocp-open-env-install-tool
```

**Option B: Fork first (recommended — allows you to customize GitOps profiles)**
1. Fork this repository on GitHub to your own org/account
2. Clone your fork:
```bash
git clone https://github.com/<your-org>/ocp-open-env-install-tool.git
cd ocp-open-env-install-tool
```
> ⚠️ If you forked, you **must** update `GIT_REPO_URL` in `config/common.config` (Step 3) to point to your fork — otherwise ArgoCD will sync from the upstream repo, not yours.

### Step 2 — Always Pull Before Running

Every time you run the installer, **pull the latest version first**. Running an outdated version can cause cryptic failures (missing RBAC, outdated CRDs, etc.):

```bash
git pull origin master   # or your target branch
```

### Step 3 — Create Your Configuration Files

The `config/` directory does **not exist** by default — you must create it.

```bash
# Create the config directory
mkdir -p config

# 1. Create the shared common config (required)
cp config_examples/common.config.example config/common.config

# 2. Create a cluster-specific config (choose the profile matching your use case)
cp config_examples/ocp-ai.config.example config/ocp-ai.config        # AI/ML profile
# or
cp config_examples/ocp-standard.config.example config/ocp-standard.config  # Standard profile
```

Then **edit both files** with your values:

```bash
# In config/common.config — mandatory fields:
# - OCP_ADMIN_PASSWORD / OCP_NON_ADMIN_PASSWORD  → cluster passwords
# - GIT_REPO_URL                                 → YOUR fork URL (if forked)
# - GIT_REPO_REVISION                            → branch (default: master)

# In config/ocp-ai.config — mandatory fields:
# - CLUSTER_NAME         → e.g. "myocp"
# - AWS_DEFAULT_REGION   → e.g. "eu-central-1"
# - AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY → from RHDP environment
# - RHDP_TOP_LEVEL_ROUTE53_DOMAIN → from RHDP environment (e.g. ".sandbox1234.opentlc.com")
```

### Step 4 — Add Your Pull Secret

Download your pull secret from [console.redhat.com](https://console.redhat.com/openshift/install) and place it in the project root:

```bash
# The file must be named exactly pull-secret.txt at the project root
ls pull-secret.txt   # verify it exists
```

### Step 5 — Install CLI Tools

Ensure these tools are installed on your workstation:

| Tool | Purpose | macOS install |
|------|---------|--------------|
| `oc` | OpenShift CLI | `brew install openshift-cli` |
| `git` | Version control | pre-installed |
| `yq` | YAML processing ([mikefarah/yq](https://github.com/mikefarah/yq)) | `brew install yq` |
| `podman` | Registry credential check | `brew install podman` |
| `aws` | AWS CLI | `brew install awscli` |

### Step 6 — Run

```bash
./init_openshift_installation_lab_cluster.sh --config-file ocp-ai.config
```

> The installation takes **~1 hour**. If your connection drops, re-run the same command — the script auto-resumes.

---

## 📦 Prerequisites (Summary)

* An active **AWS Blank Open Environment** from [Red Hat Demo Platform](https://demo.redhat.com)
* `pull-secret.txt` in the project root
* `config/common.config` and `config/<profile>.config` created and filled in
* CLI tools: `oc`, `git`, `yq`, `podman`, `aws`
* *(If forked)* `GIT_REPO_URL` updated in `config/common.config`

---

## 📂 Directory Structure

* **`init_openshift_installation_lab_cluster.sh`**: The main entry point script.
* **`config/`**: Directory for your active configuration files (`.config`).
* **`config_examples/`**: Templates for creating new configurations.
* **`scripts/`**: Helper scripts (`bastion_script.sh`, `clean_aws_tenant.sh`, `approve_cluster_csrs.sh`, etc.).
* **`output/`**: (Ignored by Git) Stores all runtime artifacts: SSH keys, logs, session info, and upload staging folders.
* **`components/`**: The "Bricks" - Raw Kustomize definitions for applications.
* **`gitops-bases/`**: The "Groups" - ApplicationSets grouping components together.
* **`gitops-profiles/`**: The "Menu" - Kustomize entry points that select specific bases.

---

## ⚙️ Configuration

The tool uses a **Split-Configuration** model to support multiple environments while sharing common variables.

### 1. Setup Common Configuration
Shared variables (e.g., OpenShift Version, Base Domain, Passwords) live here.

```bash
cp config_examples/common.config.example config/common.config
# Edit config/common.config with your preferred defaults and credentials
```
### **2\. Create a Cluster Configuration**

Choose an example from `config_examples/` and copy it to `config/`.

**Example: Creating a Full ODF Performance Cluster**

Bash

```
cp config_examples/ocp-odf-full-aws-performance.config.example config/my-odf-cluster.config
```

**Key Variables in Config Files:**

* `CLUSTER_NAME`: Name of your cluster.  
* `AWS_DEFAULT_REGION`: Target region.  
* `GITOPS_PROFILE_PATH`: Points to the specific GitOps profile to deploy (e.g., `gitops-profiles/odf-full-aws-performance`).

---

## **🚀 Usage**

### **1\. Run with a Specific Configuration (Recommended)**

This uses the settings defined in your custom config file inside the `config/` directory.

Bash

```
./init_openshift_installation_lab_cluster.sh --config-file my-odf-cluster.config
```

### **2\. Run Default Installation**

If no argument is provided, it defaults to `config/ocp-standard.config`.

Bash

```
./init_openshift_installation_lab_cluster.sh
```

### **3\. Help**

Display available options.

Bash

```
./init_openshift_installation_lab_cluster.sh --help
```

---

## **🛠️ Helper Scripts**

The `scripts/` directory contains useful tools for Day 2 operations and maintenance.

### **🛡️ Approve Cluster CSRs (`approve_cluster_csrs.sh`)**

If your cluster certificates expire or nodes are stuck in `NotReady` (e.g., after a shutdown), run this script to auto-approve pending CSRs.

Bash

```
# Usage: ./scripts/approve_cluster_csrs.sh <BASTION_HOST> <SSH_KEY>
./scripts/approve_cluster_csrs.sh ec2-x-x-x-x.compute.amazonaws.com output/bastion_mycluster.pem
```

### **🧹 Clean AWS Tenant (`clean_aws_tenant.sh`)**

This script is automatically called by the init script but can be run manually to force-clean resources related to a cluster name in a region.

```bash
# Usage: ./scripts/clean_aws_tenant.sh <AWS_KEY> <AWS_SECRET> <REGION> <CLUSTER_NAME> <DOMAIN>
./scripts/clean_aws_tenant.sh $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY us-east-2 mycluster sandbox1234.opentlc.com
```

⚠️ **WARNING**: This script deletes **ALL** S3 buckets in the AWS tenant, not just cluster-tagged buckets. This is intentional for Red Hat Demo Platform dedicated tenants where the AWS account contains only demo cluster resources. **Do NOT run in shared/production AWS accounts.**

---

## **🏗️ GitOps Architecture**

This project uses a modular "App of Apps" pattern controlled by Kustomize profiles.

1. **Components (`components/`)**: Individual applications (e.g., `rhacs`, `openshift-logging`). They may contain `overlays` for specific flavors (e.g., `logging/overlays/1x.small`).  
2. **Bases (`gitops-bases/`)**: ArgoCD ApplicationSets that group components. For example, `bases/acs/central` installs the Operator AND the Central instance.  
3. **Profiles (`gitops-profiles/`)**: The top-level Kustomize file referenced by your config (`GITOPS_PROFILE_PATH`). It mixes and matches bases.

**Example: "Standard Secured" Profile**

* Base: `core` (System components)  
* Base: `storage/mcg-only` (Lightweight storage)  
* Base: `logging/pico` (Minimal logging)  
* Base: `netobserv/default` (Network Observability without Loki)  
* Base: `acs/secured` (Sensor connecting to a Central)

## **🔄 Session Recovery**

* **Disconnected?** Just run the exact same command again. The script will detect the active session and ask if you want to resume.  
* **Bastion Provisioning Stuck?** If you killed the script while the Bastion was creating, run it again. It will detect the pending Instance ID and resume waiting for it to be ready.

---

## **FAQ**

### **Why on Red Hat Demo Platform Lab?**

* It allows provisioning an OCP environment rapidly with zero paperwork.  
* **Limitation**: AWS Blank Open Environment service lifetime is usually limited (e.g., 30 hours). Be cautious\!

### **How do I customize the GitOps repo?**

The default configuration points to the upstream repository. To make changes (like pinning specific operator versions or adding custom apps):

1. **Fork** this repository.
2. Update `GIT_REPO_URL` in `config/common.config` to point to your fork.
3. Run the installation. ArgoCD will now sync from your fork.

---

## 🔒 Security Considerations

### AWS Secrets Manager Integration

**✅ IMPLEMENTED**: AWS credentials are now **securely stored in AWS Secrets Manager** instead of being passed to the bastion in plaintext.

**How It Works:**
1. **Simple Config**: You edit AWS credentials in `config/*.config` files (workflow unchanged)
2. **Automatic Upload**: The installer stores credentials in AWS Secrets Manager
3. **Secure Retrieval**: Bastion retrieves credentials using IAM instance profile (not from uploaded files)
4. **Automatic Cleanup**: Secrets are deleted when cleaning the environment

**Security Benefits:**
- ✅ **Encrypted Storage**: Secrets Manager encrypts credentials at rest with AWS KMS
- ✅ **Secure Transit**: Retrieved via TLS (AWS API)
- ✅ **No Plaintext Upload**: Credentials NOT sent to bastion in config files
- ✅ **IAM-Based Access**: Only the bastion instance can read its secret
- ✅ **Audit Trail**: CloudTrail logs all secret access
- ✅ **Automatic Deletion**: Secrets purged during cleanup (idempotent)

**What's Still in Config Files:**
- ⚠️ **Local config files** still contain AWS credentials (needed for initial AWS setup from your workstation)
- ⚠️ **Cluster passwords** (`OCP_ADMIN_PASSWORD`, `OCP_NON_ADMIN_PASSWORD`) remain in `config/common.config`

This is acceptable for RHDP demo/lab environments (30h lifespan, dedicated tenants, single-user).

**Best Practices:**
1. **Use temporary credentials**: Generate short-lived IAM credentials from RHDP (auto-expire with environment)
2. **Delete local configs**: Remove `config/*.config` files after cluster destruction
3. **Verify cleanup**: Ensure `clean_aws_tenant.sh` completes successfully
4. **Clean output/**: Delete `output/` directory after teardown

**For Production Use:**
The tool already uses AWS Secrets Manager for credentials. For production adaptation:
- ✅ Secrets Manager is production-ready
- ⚠️ Consider adding OCP passwords to Secrets Manager
- ✅ Enable credential rotation policies
- ✅ Use dedicated IAM users with minimal permissions

### Least-Privilege RBAC for Jobs

**✅ PRODUCTION-READY**: All GitOps automation Jobs use dedicated ServiceAccounts with minimal permissions.

**Implementation:**
- **20 Jobs** deployed via GitOps for Day 2 configuration
- **13 Dedicated ServiceAccounts** with task-specific permissions
- **0 cluster-admin usage** (all Jobs use least-privilege RBAC)
- **Namespace-scoped Roles** preferred over cluster-scoped permissions

**Security Improvements:**
- ✅ **~95-99% permission reduction** per Job (vs cluster-admin)
- ✅ **Blast radius containment** - Compromised Job cannot access unrelated resources
- ✅ **Audit compliance** - Clear permission boundaries
- ✅ **Production-ready** - No overly permissive access

**Examples:**
- `console-plugin-manager` - ONLY console.operator.openshift.io patch (~99% reduction)
- `cert-manager-operator` - cert-manager.io + specific namespaces (~95% reduction)
- `loki-s3-secret-creator` - Secret create/update in logging/netobserv only (~95% reduction)

See `docs/claude/security.md` for detailed RBAC implementation.

### Zero-Trust Network Isolation

**✅ IMPLEMENTED**: AdminNetworkPolicy (ANP) + BaselineAdminNetworkPolicy (BANP) for namespace-level network security.

**Architecture:**
- **AdminNetworkPolicy** (priority 10, highest) - Explicit Allow rules for cluster services
- **NetworkPolicy** (medium priority) - User/developer policies
- **BaselineAdminNetworkPolicy** (lowest priority) - Default deny fallback

**Security Benefits:**
- ✅ **Zero-trust by default** - All traffic denied unless explicitly allowed
- ✅ **Guaranteed cluster services** - DNS, monitoring, ingress cannot be blocked
- ✅ **Opt-in per namespace** - Label `network-policy.gitops/enforce: "true"` to enable
- ✅ **90% resource reduction** - 2 policies vs 72+ NetworkPolicy objects

**Critical Implementation Detail:**
- Kubernetes API access requires `nodes:` selector (not IP-based rules)
- OVN-Kubernetes performs DNAT before ANP evaluation
- See `CLAUDE.md` "Network Isolation with AdminNetworkPolicy" section

