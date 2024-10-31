set -e
if [[ $# -lt 8 ]]; then
  echo "Incorrect number of found arguments: $# - Expected: 8"
  exit 1
fi
OCP_DOWNLOAD_BASE_URL=$1
OPENSHIFT_VERSION=$2
AWS_INSTANCE_TYPE_INFRA_NODES=$3
AWS_INSTANCE_TYPE_STORAGE_NODES=$4
GIT_REPO_URL=$5
GIT_CREDENTIALS_TEMPLATE_URL=$6
GIT_CREDENTIALS_TEMPLATE_TOKEN_NAME=$7
GIT_CREDENTIALS_TEMPLATE_TOKEN_SECRET=$8
GIT_REPO_TOKEN_NAME=$9
GIT_REPO_TOKEN_SECRET=${10}

OC_TARGZ_FILE=openshift-client-linux-$OPENSHIFT_VERSION.tar.gz
INSTALLER_TARGZ_FILE=openshift-install-linux-$OPENSHIFT_VERSION.tar.gz
INSTALL_DIRNAME=cluster-install

echo "Installing wget package..."
sudo yum install -y wget

echo "Install yq package..."
sudo wget -nv -O /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/bin/yq

echo "Installing OpenShift CLI..."
wget -nv -O $OC_TARGZ_FILE $OCP_DOWNLOAD_BASE_URL/$OPENSHIFT_VERSION/$OC_TARGZ_FILE
if [[ $? -ne 0 ]]; then
  echo "Something was wrong when downloading OpenShift CLI for OpenShift version: $OPENSHIFT_VERSION. Ensure version exists."
  exit 10
fi
sudo tar -xvf $OC_TARGZ_FILE -C /usr/bin oc kubectl

echo "Set up bash completion for the OpenShift CLI"
sudo sh -c '/usr/bin/oc completion bash >/etc/bash_completion.d/openshift'

echo "Installing the installer..."
wget -nv -O $INSTALLER_TARGZ_FILE $OCP_DOWNLOAD_BASE_URL/$OPENSHIFT_VERSION/$INSTALLER_TARGZ_FILE
if [[ $? -ne 0 ]]; then
  echo "Something was wrong when downloading installer for OpenShift version: $OPENSHIFT_VERSION. Ensure version exists."
  exit 11
fi
tar -xvf $INSTALLER_TARGZ_FILE openshift-install

echo "Generating manifests..."
./openshift-install create manifests --dir $INSTALL_DIRNAME

echo "Creating the MachineSet for infra nodes..."
for i in {0..2}; do
  MS_INFRA_NAME=$(yq '.metadata.name' $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml | sed s/worker/infra/)
  MS_STORAGE_NAME=$(yq '.metadata.name' $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml | sed s/worker/storage/)
  yq ".metadata.name = \"$MS_INFRA_NAME\" \
    | .spec.selector.matchLabels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_INFRA_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_INFRA_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-role\"] = \"infra\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-type\"] = \"infra\" \
    | .spec.template.spec.metadata.labels.\"node-role.kubernetes.io/infra\" = \"\" \
    | .spec.template.spec.providerSpec.value.instanceType = \"$AWS_INSTANCE_TYPE_INFRA_NODES\" \
    | .spec.template.spec.taints += [{\"key\": \"node-role.kubernetes.io/infra\", \"effect\": \"NoSchedule\"},{\"key\": \"node-role.kubernetes.io/infra\", \"effect\": \"NoExecute\"}]" \
    $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml > $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_infra-machineset-$i.yaml
  yq ".metadata.name = \"$MS_STORAGE_NAME\" \
    | .spec.selector.matchLabels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_STORAGE_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_STORAGE_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-role\"] = \"infra\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-type\"] = \"infra\" \
    | .spec.template.spec.metadata.labels.\"node-role.kubernetes.io/infra\" = \"\" \
    | .spec.template.spec.metadata.labels.\"cluster.ocs.openshift.io/openshift-storage\" = \"\" \
    | .spec.template.spec.providerSpec.value.instanceType = \"$AWS_INSTANCE_TYPE_STORAGE_NODES\" \
    | .spec.template.spec.taints += [{\"key\": \"node.ocs.openshift.io/storage\", \"value\": \"true\", \"effect\": \"NoSchedule\"},{\"key\": \"node.ocs.openshift.io/storage\", \"value\": \"true\", \"effect\": \"NoExecute\"}]" \
    $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml > $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_storage-machineset-$i.yaml
done

echo "Adding MachineConfig configuration..."
cp day1_config/machineconfig/*.yaml $INSTALL_DIRNAME/openshift

echo "Adding network configuration manifests..."
cp day1_config/network/*.yaml $INSTALL_DIRNAME/manifests

echo "Adding gitops operator configuration manifests..."
cp day1_config/gitops/*.yaml $INSTALL_DIRNAME/manifests

echo "Creating the cluster..."
./openshift-install create cluster --dir $INSTALL_DIRNAME

echo "Exporting admin TLS credentials..."
echo "export KUBECONFIG=$HOME/$INSTALL_DIRNAME/auth/kubeconfig" >> .bashrc
export KUBECONFIG=$HOME/$INSTALL_DIRNAME/auth/kubeconfig

echo "Remove kubeadmin user"
oc delete secrets kubeadmin -n kube-system --ignore-not-found=true

if [[ $GIT_CREDENTIALS_TEMPLATE_URL ]]; then
  echo "Create git repository credentials template secret for ArgoCD repo"
  oc create secret generic creds-cluster --from-literal username=$GIT_CREDENTIALS_TEMPLATE_TOKEN_NAME --from-literal password=$GIT_CREDENTIALS_TEMPLATE_TOKEN --from-literal url=$GIT_CREDENTIALS_TEMPLATE_URL -n openshift-gitops
  oc label secret creds-cluster argocd.argoproj.io/secret-type=repo-creds -n openshift-gitops
fi

if [[ $GIT_REPO_TOKEN_NAME ]]; then
  echo "Create git repository secret for GitOps git repo"
  oc create secret generic git-app-cluster --from-literal username=$GIT_REPO_TOKEN_NAME --from-literal password=$GIT_REPO_TOKEN_SECRET --from-literal type=git --from-literal url=$GIT_REPO_URL --from-literal project=default -n openshift-gitops
  oc label secret git-app-cluster argocd.argoproj.io/secret-type=repository -n openshift-gitops
fi

echo "Run day2 config through GitOps"
mkdir day2_config/_generated
yq ".spec.source.repoURL = \"$GIT_REPO_URL\"" day2_config/patch_templates/application-patch.yaml > day2_config/_generated/application-patch.yaml
oc create -k day2_config

echo "----------------------------"
echo "Your cluster API URL is:"
oc whoami --show-server
echo "----------------------------"
echo "Your cluster console URL is:"
oc whoami --show-console
echo "----------------------------"


