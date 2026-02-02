# OpenShift Container Platform setup on Red Hat Demo Platform Open Environment Lab for Red Hat Consulting team

The purpose of this project is to help the Red Hat Consulting team quickly setup an OpenShift cluster using an AWS Blank Open Environment [Red Hat Demo Platform](https://demo.redhat.com) item.

It supports both **IPI (Installer-Provisioned Infrastructure)** and **UPI (User-Provisioned Infrastructure)** methods for installation on AWS.

The entire installation process, including Day 2 configuration, takes about 1 hour or more.

This OCP installation includes a rich set of optional Day 2 components deployed via a **Profile-Based GitOps Architecture**, such as:
* **Storage:** OpenShift Data Foundation (ODF) in MultiCloud Gateway only (MCG) or Full modes (Lean, Balanced, Performance).
* **Integration:** OpenShift Service Mesh.
* **Observability:** Logging (Pico, Small, Medium), Loki, Monitoring, Tempo, OpenTelemetry, Network Observability (with or without Loki).
* **Security:** Red Hat Advanced Cluster Security (ACS) - Central or Secured Cluster modes.
* **Management:** Red Hat Advanced Cluster Management (ACM) - Hub or Managed modes.
* **AI/ML:** Red Hat OpenShift AI (RHOAI), Nvidia GPU Operator, Kueue.
* **CI/CD:** OpenShift GitOps, Pipelines, Builds.
* **Utilities:** cert-manager, Sealed Secrets, WebTerminal, Node Feature Discovery.

---

## ✨ Key Features

* **Multi-Configuration Support:** Manage different cluster types (e.g., `standard`, `odf-full`, `ai`, `acs-central`) from a single codebase using dedicated config files.
* **Clean Workspace:** All runtime artifacts (keys, logs, sessions) are isolated in an `output/` directory.
* **Parallel Execution:** Run multiple cluster installations simultaneously on different AWS accounts or regions without conflict.
* **Robust Recovery:**
    * **Auto-Resume:** If your network drops, simply rerun the script to reattach to the session.
    * **Provisioning Recovery:** Detects existing Bastion instances to avoid duplication.
* **Modular GitOps:** Uses a "Lego-like" Component + Base + Profile architecture (Kustomize) for flexible composition.

---

## 📦 Prerequisites

* An active **AWS Blank Open Environment** service from the [Red Hat Demo Platform](https://demo.redhat.com).
* A `pull-secret.txt` file from the [Red Hat Hybrid Cloud console](https://console.redhat.com/openshift/install). **Place this file in the root of the project.**
* The following CLI tools installed on your workstation:
    * `oc` (OpenShift Client)
    * `git`
    * `yq` (the [mikefarah/yq](https://github.com/mikefarah/yq) implementation)
    * `podman` (for checking credentials)
    * `aws` (AWS CLI)
* If using Day 2 GitOps with private repositories, ensure you have your Git credentials ready in your configuration file.

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

If no argument is provided, it defaults to `config/ocp-default.config`.

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

This script is automatically called by the init script but can be run manually to force-clean resources related to a cluster name in a region. **Use with caution.**

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

