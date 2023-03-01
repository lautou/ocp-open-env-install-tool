set -e
if [[ $# -lt 9 ]]; then
  echo "Incorrect number of found arguments: $# - Expected: 9"
  exit 1
fi
OCP_DOWNLOAD_BASE_URL=$1
OPENSHIFT_VERSION=$2
CLUSTER_NAME=$3
RHDP_TOP_LEVEL_ROUTE53_DOMAIN=$4
RHOCM_PULL_SECRET=$5
AWS_DEFAULT_REGION=$6
AWS_ACCESS_KEY_ID=$7
AWS_SECRET_ACCESS_KEY=$8
AWS_INSTANCE_TYPE_INFRA_NODES=$9

echo OCP_DOWNLOAD_BASE_URL=$OCP_DOWNLOAD_BASE_URL
echo OPENSHIFT_VERSION=$OPENSHIFT_VERSION
echo CLUSTER_NAME=$CLUSTER_NAME
echo RHDP_TOP_LEVEL_ROUTE53_DOMAIN=$RHDP_TOP_LEVEL_ROUTE53_DOMAIN
echo RHOCM_PULL_SECRET=$RHOCM_PULL_SECRET
echo AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
echo AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
echo AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
echo AWS_INSTANCE_TYPE_INFRA_NODES=$AWS_INSTANCE_TYPE_INFRA_NODES

OC_TARGZ_FILE=openshift-client-linux-$OPENSHIFT_VERSION.tar.gz
INSTALLER_TARGZ_FILE=openshift-install-linux-$OPENSHIFT_VERSION.tar.gz
INSTALL_DIRNAME=cluster-install
if [[ "$OSTYPE" == "darwin"* ]]; then
  BASE64_OPTS="-b0"
else
  BASE64_OPTS="-w0"
fi
CHRONY_CONF_B64="$(cat day1_config/chrony.conf | base64 $BASE64_OPTS)"

echo "Installing some important packages..."
sudo yum install -y wget httpd-tools https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm

echo "Install snap package..."
sudo yum install -y snapd
sudo systemctl enable --now snapd.socket
# We restart snap service, so we can use snap command in this session. Otherwise, a restart of SSH session would be necessary.
sudo systemctl restart snapd.seeded.service

echo "Install yq package..."
sudo snap install yq
# In order to get the PATH updated for yq package, we have to restart the SSH session.
# To avoid this, we force profiles reload to update PATH in this current session.  
. /etc/profile

echo "Installing CLI..."
wget $OCP_DOWNLOAD_BASE_URL/$OPENSHIFT_VERSION/$OC_TARGZ_FILE -O $OC_TARGZ_FILE
if [[ $? -ne 0 ]]; then
  echo "Something was wrong when downloading CLI for OpenShift version: $OPENSHIFT_VERSION. Ensure version exists."
  exit 10
fi
sudo tar -xvf $OC_TARGZ_FILE -C /usr/bin oc kubectl

echo "Set up bash completion for the CLI"
sudo sh -c '/usr/bin/oc completion bash >/etc/bash_completion.d/openshift'

echo "Installing the installer..."
wget $OCP_DOWNLOAD_BASE_URL/$OPENSHIFT_VERSION/$INSTALLER_TARGZ_FILE -O $INSTALLER_TARGZ_FILE
if [[ $? -ne 0 ]]; then
  echo "Something was wrong when downloading installer for OpenShift version: $OPENSHIFT_VERSION. Ensure version exists."
  exit 11
fi
tar -xvf $INSTALLER_TARGZ_FILE openshift-install

if [[ -f $INSTALL_DIRNAME/terraform.tfstate ]]; then
  echo "A previous cluster installation has been detected. So we destroy the cluster first before recreating it."
  ./openshift-install destroy cluster --dir $INSTALL_DIRNAME
  rm -rf $INSTALL_DIRNAME
fi

mkdir -p $INSTALL_DIRNAME .aws
echo "Generating install-config.yaml file from template..."
yq ".baseDomain = \"${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}\" \
  | .metadata.name = \"$CLUSTER_NAME\" \
  | .platform.aws.region = \"$AWS_DEFAULT_REGION\" \
  | .pullSecret = \"${RHOCM_PULL_SECRET//\"/\\\"}\"" \
  install-config_template.yaml > $INSTALL_DIRNAME/install-config.yaml

echo "Generating AWS credentials file from template..."
cat credentials_template | sed s/\$AWS_ACCESS_KEY_ID/$AWS_ACCESS_KEY_ID/ | sed s/\$AWS_SECRET_ACCESS_KEY/${AWS_SECRET_ACCESS_KEY//\//\\\/}/ > .aws/credentials

echo "Generating manifests..."
./openshift-install create manifests --dir $INSTALL_DIRNAME

echo "Creating MachineConfig for chrony configuration..."
yq ".spec.config.storage.files[0].contents.source = \"data:text/plain;charset=utf-8;base64,$CHRONY_CONF_B64\"" day1_config/machineconfig/masters-chrony-configuration_template.yaml > $INSTALL_DIRNAME/openshift/99_openshift-machineconfig_99-masters-chrony.yaml
yq ".spec.config.storage.files[0].contents.source = \"data:text/plain;charset=utf-8;base64,$CHRONY_CONF_B64\"" day1_config/machineconfig/workers-chrony-configuration_template.yaml > $INSTALL_DIRNAME/openshift/99_openshift-machineconfig_99-workers-chrony.yaml

echo "Creating the MachineSet for infra nodes..."
for i in {0..2}; do
  MS_INFRA_NAME=$(yq '.metadata.name' $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml | sed s/worker/infra/)
  yq ".metadata.name = \"$MS_INFRA_NAME\" \
    | .spec.selector.matchLabels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_INFRA_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_INFRA_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-role\"] = \"infra\" \
    | .spec.template.spec.metadata.labels.\"node-role.kubernetes.io/infra\" = \"\" \
    | .spec.template.spec.providerSpec.value.instanceType = \"$AWS_INSTANCE_TYPE_INFRA_NODES\" \
    | .spec.template.spec.taints += [{\"key\": \"node-role.kubernetes.io/infra\", \"effect\": \"NoSchedule\"}]" \
    $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml > $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_infra-machineset-$i.yaml
done

echo "Adding network configuration manifest..."
cp day1_config/network/*.yaml $INSTALL_DIRNAME/manifests

echo "Creating the cluster..."
./openshift-install create cluster --dir $INSTALL_DIRNAME

echo "Exporting admin TLS credentials..."
echo "export KUBECONFIG=$HOME/$INSTALL_DIRNAME/auth/kubeconfig" >> .bashrc
export KUBECONFIG=$HOME/$INSTALL_DIRNAME/auth/kubeconfig

echo "Creating htpasswd file"
htpasswd -c -b -B htpasswd admin redhat
htpasswd -b -B htpasswd andrew r3dh4t1!
htpasswd -b -B htpasswd karla r3dh4t1!
htpasswd -b -B htpasswd marina r3dh4t1!

echo "Creating HTPasswd Secret"
oc create secret generic htpass-secret --from-file=htpasswd=htpasswd -n openshift-config --dry-run -o yaml | oc apply -f -

echo "Configuring HTPassw identity provider"
oc apply -f oauth-cluster.yaml

echo "Giving cluster-admin role to admin user"
oc adm policy add-cluster-role-to-user cluster-admin admin

echo "Remove kubeadmin user"
oc delete secrets kubeadmin -n kube-system --ignore-not-found=true

echo "----------------------------"
echo "Your cluster API URL is:"
oc whoami --show-server
echo "----------------------------"
echo "Your cluster console URL is:"
oc whoami --show-console
echo "----------------------------"


