# OpenShift Container Platform setup on Red Hat Demo Platform Open Environment Lab for Red Hat Consulting team

The purpose of this project is to help Red Hat Consulting team to quickly setup an OpenShift cluster using an AWS Blank Open Environment [Red Hat Demo Platform](https://demo.redhat.com) item.

It supports both IPI (Installer-Provisioned Infrastructure) and UPI (User-Provisioned Infrastructure) methods for installation on AWS.

The entire installation process, including Day 2 configuration, takes about 1 hour or more.

This OCP installation includes a rich set of optional Day 2 components deployed via GitOps, such as:
* OpenShift Data Foundation (ODF)
* A complete observability stack (Logging, Monitoring, Tempo, OpenTelemetry)
* A complete CI/CD stack (OpenShift GitOps, Pipelines, Builds)
* Infrastructure utilities (cert-manager, Sealed Secrets, WebTerminal)

## FAQ

### How does it work?
The `init_openshift_installation_lab_cluster.sh` script sets up a bastion host on AWS. This bastion then runs another script (`bastion_script.sh`) to perform the OCP installation (IPI or UPI) and Day 2 configuration using GitOps.

### Why on Red Hat Demo Platform Lab?
* It is the only platform for RedHat associates, among others internal platforms, which allows us to provision an OCP environment rapidly with 0 paperwork.
* It has enough resources so every consultant can provision his own OCP environment without impacting others peoples.

### What are the limitations?
* On Red Hat Demo Platform you can not provision more than three AWS Blank Open Environment service **per user**. You have to consider this before running the script.
* Once instanced, **AWS Blank Open Environment service lifetime is 30 hours**. After that, the service is deleted automatically. This script can help you to install OCP cluster after you request a new AWS Blank Open Environment service. You can extend the service lifetime without any limit, please be cautious with the associated costs!

### Why using AWS Blank Open Environment service and not AWS with Openshift Open Environment service catalog item on Red Hat Demo Platform?
* AWS with Openshift Open Environment only create a very limited cluster (2 workers nodes, no infra nodes).
* AWS with Openshift Open Environment service only create both an admin user and non admin user.
* OCP versions to deploy are very limited.
* You don't have all these drawbacks using AWS Blank Open Environment service item.

### What are the prerequisites?
* An active **AWS Blank Open Environment** service from the [Red Hat Demo Platform](https://demo.redhat.com).
* A `pull-secret.txt` file from the [Red Hat Hybrid Cloud console](https://console.redhat.com/openshift/install). **Place this file in the root of the project.**
* The following CLI tools installed: `oc`, `git`, `yq` (the [mikefarah/yq](https://github.com/mikefarah/yq) implementation), `podman`, and `aws`.
* You need to generate a GitLab access token bound to your Red Hat GitLab Consulting profile (Click on your profile -> Edit Profile -> Access tokens under User settings menu). The access token should only need `read_repository` scope. Note the token name and the generated token secret for `ocp_rhdp.config`.
* If using UPI, a `cloudformation_templates` directory with the required AWS templates.


### What is the `install-config.yaml` file used for installation?
* The `bastion_script.sh` running on the bastion host **dynamically generates** the `install-config.yaml` file within the `cluster-install` directory.
* Customizations for Day 1 are primarily done through `ocp_rhdp.config` variables.

## What is the installed cluster sizing?

The AWS machine sizes used are configured in your `ocp_rhdp.config` file. Node counts (`AWS_WORKERS_COUNT`, `AWS_INFRA_NODES_COUNT`, `AWS_STORAGE_NODES_COUNT`) are also configured in `ocp_rhdp.config`.

### What OpenShift versions have been tested with this project?
* 4.18

Feel free to share the next upcoming versions you have tested here!

## Installation

1.  Order an AWS Blank Open Environment service item on [Red Hat Demo Platform](https://demo.redhat.com).
2.  Clone this repository on your laptop.
    ```bash
    git clone [https://gitlab.consulting.redhat.com/openshift-toolkit/ocp-open-env-install-tool.git](https://gitlab.consulting.redhat.com/openshift-toolkit/ocp-open-env-install-tool.git)
    cd ocp-open-env-install-tool
    ```
3.  **Create your configuration file.** Copy the provided example to create your local, private configuration. This new file is safely ignored by Git.
    ```bash
    cp ocp_rhdp.config.example ocp_rhdp.config
    ```
4.  **Fill the environment variables in `ocp_rhdp.config`.** This is the central place to configure your cluster, including AWS credentials, domain names, and node sizes.

5.  **Run the installation script:**
    ```bash
    ./init_openshift_installation_lab_cluster.sh
    ```
6.  The script will guide you through the process. Monitor the output for the console URL and credentials.

## Git Credentials and Discovery Logic

The script handles Git credentials with the following logic:
* **Specific Credentials:** If you provide `GIT_REPO_TOKEN_NAME` and `GIT_REPO_TOKEN_SECRET` in `ocp_rhdp.config`, they will be used for this repository.
* **Automatic Discovery:** If you leave them empty, the script will attempt to find a matching credential template from the main `openshift-gitops` ArgoCD instance. This is useful if a global credential for `gitlab.consulting.redhat.com` is already configured.
* **Template Credentials:** The `GIT_CREDENTIALS_TEMPLATE_...` variables can be used to configure a generic credential in ArgoCD for accessing other repositories.

## Advanced Customization (Forking Workflow)

The default configuration uses the Red Hat Toolkit repository as the source of truth for all Day 2 components. As you only have read-only access, you cannot directly customize the platform's Kustomize structure.

If you need to modify the platform itself (e.g., change operator versions, add new modules to the `applicationset-cluster.yaml`), you must **fork this repository**.

The workflow is as follows:
1.  **Fork** this `ocp-open-env-install-tool` repository to your own GitLab group or GitHub organization.
2.  Clone your fork locally.
3.  In your `ocp_rhdp.config` file, change the `GIT_REPO_URL` variable to point to **the URL of your fork**.
4.  Run the `./init_openshift_installation_lab_cluster.sh` script.

ArgoCD will now use your fork as the source of truth, and any changes you push to your fork will be automatically applied to your cluster.