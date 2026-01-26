# OpenShift Container Platform setup on Red Hat Demo Platform Open Environment Lab for Red Hat Consulting team

The purpose of this project is to help the Red Hat Consulting team quickly setup an OpenShift cluster using an AWS Blank Open Environment [Red Hat Demo Platform](https://demo.redhat.com) item.

It supports both **IPI (Installer-Provisioned Infrastructure)** and **UPI (User-Provisioned Infrastructure)** methods for installation on AWS.

The entire installation process, including Day 2 configuration, takes about 1 hour or more.

This OCP installation includes a rich set of optional Day 2 components deployed via a **Profile-Based GitOps Architecture**, such as:
* **Storage:** OpenShift Data Foundation (ODF) in Managed (MCG) or Full modes.
* **Integration:** OpenShift Service Mesh
* **Observability:** Logging, Loki, Monitoring, Tempo, OpenTelemetry, Network Observability.
* **CI/CD:** OpenShift GitOps, Pipelines, Builds.
* **Utilities:** cert-manager, Sealed Secrets, WebTerminal, Node Feature Discovery.

---

## ✨ Key Features

* **Multi-Profile Support:** Manage different cluster types (e.g., `standard`, `odf-full`, `ai-lab`) from a single codebase.
* **Parallel Execution:** Run multiple cluster installations simultaneously on different AWS accounts or regions without conflict.
* **Robust Recovery:**
    * **Auto-Resume:** If your network drops, simply rerun the script to reattach to the session.
    * **Provisioning Recovery:** If the script crashes while creating the Bastion, it detects the existing instance and resumes instead of creating a "ghost" bastion.
* **Modular GitOps:** Uses a Component + Profile architecture (Kustomize) instead of monolithic configuration.

---

## 📦 Prerequisites

* An active **AWS Blank Open Environment** service from the [Red Hat Demo Platform](https://demo.redhat.com).
* A `pull-secret.txt` file from the [Red Hat Hybrid Cloud console](https://console.redhat.com/openshift/install). **Place this file in the root of the project.**
* The following CLI tools installed: `oc`, `git`, `yq` (the [mikefarah/yq](https://github.com/mikefarah/yq) implementation), `podman`, and `aws`.
* If using Day 2 GitOps with private repositories, ensure you have your Git credentials ready (see Configuration).

---

## ⚙️ Configuration

The tool uses a **Split-Configuration** model to support multiple profiles while sharing common variables.

### 1. Common Configuration (`common.config`)
Put shared variables here (e.g., OpenShift Version, Base Domain, Passwords, generic GitOps settings).

```bash
cp common.config.example common.config
# Edit common.config with your preferred defaults
```

### 2. Profile Configuration (`profiles/*.config`)
Create specific profiles for different cluster types (e.g., ODF-enabled, GPU nodes, different regions).

**Setup:**

```bash
mkdir -p profiles
cp profiles/odf-full-aws.config.example profiles/my-odf-lab.config
```

**Key Variables in Profiles:**

* `CLUSTER_NAME`: Name of your cluster.

* `AWS_DEFAULT_REGION`: Target region.

* `GITOPS_PROFILE_PATH`: Points to the GitOps profile to deploy (e.g., `gitops-profiles/odf-full-aws`).

### 3. Default Configuration (`ocp_rhdp.config`)
This is the legacy default profile used if no argument is provided.

```Bash
cp ocp_rhdp.config.example ocp_rhdp.config
```

## 🚀 Usage
### 1. Default Installation
Runs using `ocp_rhdp.config` combined with `common.config`.

``` Bash
./init_openshift_installation_lab_cluster.sh
```

### 2. Specific Profile Installation
Runs a specific configuration. The script creates unique session files and keys, allowing you to run this in parallel with other clusters.

``` Bash
./init_openshift_installation_lab_cluster.sh --profile-file profiles/my-odf-lab.config
```

### 3. Help

``` Bash
./init_openshift_installation_lab_cluster.sh --help
```

## 🏗️ GitOps Architecture
This project uses a modular "App of Apps" pattern controlled by Kustomize profiles.

### Directory Structure
* `components/`: The "Bricks". Contains the raw Kustomize definitions for each application (e.g., `cert-manager`, `loki`, `openshift-storage`).

* `components/openshift-storage` contains overlays for `mcg-only` and `full`.

* `gitops-bases/`: The "Groups". Contains `ApplicationSet` definitions that group components together (e.g., `applicationset-core.yaml`, `applicationset-storage-full.yaml`).

* `gitops-profiles/`: The "Menu". These are the Kustomize entry points pointed to by `GITOPS_PROFILE_PATH`.

* `gitops-profiles/standard`: Deploys Core + MCG Storage.

* `gitops-profiles/odf-full-aws`: Deploys Core + Full ODF Storage.

### How to add a new Component?
* Add the Kustomize manifests to `components/<my-app>`.

* Add the application to `gitops-bases/applicationset-core.yaml` (if standard) or create a new specific ApplicationSet.

* Ensure your target profile in `gitops-profiles/` includes the relevant base.

## 🛠️ How it Works
* **Initialization**: The script merges `common.config` and your selected profile.

* **Bastion Provisioning**: It provisions an EC2 Bastion with all required tools (oc, aws, yq, etc.) pre-installed via UserData.

* **File Transfer**: It uploads the merged config and the `components/` directory to the Bastion.

* **Execution**: It starts a `tmux` session on the Bastion to run the installation.

* **Bootstrap**: Once OCP is installed, it deploys a single **Bootstrap Application** to ArgoCD, which syncs your selected `gitops-profile`.

## 🔄 Session Recovery
* **Disconnected?** Just run the exact same command again. The script will detect the active session and ask if you want to resume.

* **Bastion Provisioning Stuck?** If you killed the script while the Bastion was creating, run it again. It will detect the pending Instance ID and resume waiting for it to be ready.

## FAQ
### Why on Red Hat Demo Platform Lab?
* It allows provisioning an OCP environment rapidly with 0 paperwork.

* **Limitation**: AWS Blank Open Environment service lifetime is usually limited (e.g., 30 hours). Be cautious!

### How do I customize the GitOps repo?
The default configuration points to the upstream repository. To make changes (like pinning specific operator versions):

* Fork this repository.

* Update `GIT_REPO_URL` in `common.config` to point to your fork.

* Run the installation. ArgoCD will now sync from your fork.