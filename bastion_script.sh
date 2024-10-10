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
AWS_INSTANCE_TYPE_STORAGE_NODES=${10}

OC_TARGZ_FILE=openshift-client-linux-$OPENSHIFT_VERSION.tar.gz
INSTALLER_TARGZ_FILE=openshift-install-linux-$OPENSHIFT_VERSION.tar.gz
INSTALL_DIRNAME=cluster-install
if [[ "$OSTYPE" == "darwin"* ]]; then
  BASE64_OPTS="-b0"
else
  BASE64_OPTS="-w0"
fi
CHRONY_CONF_B64="$(cat day1_config/chrony.conf | base64 $BASE64_OPTS)"
SSH_KEY_PATH=/home/ec2-user/.ssh/id_rsa
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

# Load AWS library
. aws_lib.bash

echo "Installing some important packages..."
sudo yum install -y wget httpd-tools unzip 

echo "Install yq package..."
sudo wget -nv -O /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
sudo chmod +x /usr/bin/yq

echo "Installing aws CLI..."
wget -nv -O awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
unzip -q awscliv2.zip
sudo ./aws/install

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

if [[ -f $INSTALL_DIRNAME/terraform.tfstate ]]; then
  echo "A previous cluster installation has been detected. So we destroy the cluster first before recreating it."
  ./openshift-install destroy cluster --dir $INSTALL_DIRNAME
  rm -rf $INSTALL_DIRNAME
fi

mkdir -p $INSTALL_DIRNAME .aws
echo "Generating install-config.yaml file from template..."
ssh-keygen -q -N '' -f $SSH_KEY_PATH <<<y
SSH_KEY="$(cat $SSH_KEY_PATH.pub)"
yq ".baseDomain = \"${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}\" \
  | .metadata.name = \"$CLUSTER_NAME\" \
  | .platform.aws.region = \"$AWS_DEFAULT_REGION\" \
  | .pullSecret = \"${RHOCM_PULL_SECRET//\"/\\\"}\" \
  | .sshKey = \"$SSH_KEY\"" \
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
  MS_STORAGE_NAME=$(yq '.metadata.name' $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml | sed s/worker/storage/)
  yq ".metadata.name = \"$MS_INFRA_NAME\" \
    | .spec.selector.matchLabels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_INFRA_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_INFRA_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-role\"] = \"infra\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-type\"] = \"infra\" \
    | .spec.template.spec.metadata.labels.\"node-role.kubernetes.io/infra\" = \"\" \
    | .spec.template.spec.providerSpec.value.instanceType = \"$AWS_INSTANCE_TYPE_INFRA_NODES\" \
    | .spec.template.spec.taints += [{\"key\": \"node-role.kubernetes.io/infra\", \"effect\": \"NoSchedule\"}]" \
    $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml > $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_infra-machineset-$i.yaml
  yq ".metadata.name = \"$MS_STORAGE_NAME\" \
    | .spec.selector.matchLabels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_STORAGE_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_STORAGE_NAME\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-role\"] = \"infra\" \
    | .spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-type\"] = \"infra\" \
    | .spec.template.spec.metadata.labels.\"node-role.kubernetes.io/infra\" = \"\" \
    | .spec.template.spec.metadata.labels.\"cluster.ocs.openshift.io/openshift-storage\" = \"\" \
    | .spec.template.spec.providerSpec.value.instanceType = \"$AWS_INSTANCE_TYPE_STORAGE_NODES\" \
    | .spec.template.spec.taints += [{\"key\": \"node.ocs.openshift.io/storage\", \"value\": \"true\", \"effect\": \"NoSchedule\"}]" \
    $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_worker-machineset-$i.yaml > $INSTALL_DIRNAME/openshift/99_openshift-cluster-api_storage-machineset-$i.yaml
done

echo "Adding network configuration manifests..."
cp day1_config/network/*.yaml $INSTALL_DIRNAME/manifests

echo "Adding gitops operator configuration manifests..."
cp day1_config/gitops/*.yaml $INSTALL_DIRNAME/manifests

echo "Creating the cluster..."
./openshift-install create cluster --dir $INSTALL_DIRNAME

echo "Exporting admin TLS credentials..."
echo "export KUBECONFIG=$HOME/$INSTALL_DIRNAME/auth/kubeconfig" >> .bashrc
export KUBECONFIG=$HOME/$INSTALL_DIRNAME/auth/kubeconfig

echo "Creating htpasswd file"
#htpasswd -c -b -B htpasswd admin redhat
#htpasswd -b -B htpasswd andrew r3dh4t1!
#htpasswd -b -B htpasswd karla r3dh4t1!
#htpasswd -b -B htpasswd marina r3dh4t1!

echo "Creating HTPasswd Secret"
#oc create secret generic htpass-secret --from-file=htpasswd=htpasswd -n openshift-config --dry-run -o yaml | oc apply -f -

echo "Configuring HTPassw identity provider"
#oc apply -f day2_config/oauth-cluster.yaml

echo "Giving cluster-admin role to admin user"
#oc adm policy add-cluster-role-to-user cluster-admin admin

echo "Remove kubeadmin user"
#oc delete secrets kubeadmin -n kube-system --ignore-not-found=true

echo "Configure ingress controller..."
#oc apply -f day2_config/cluster-ingress-default-ingresscontroller.yaml

echo "Configure images registry..."
#oc apply -f day2_config/images-registry-config-cluster.yaml

echo "Configure cluster monitoring..."
#oc apply -f day2_config/configmap-user-workload-monitoring-config.yaml
#oc apply -f day2_config/configmap-cluster-monitoring-config.yaml

echo "Install ElasticSearch Operator..."
#oc apply -f day2_config/namespace-openshift-redhat-operators.yaml
#oc apply -f day2_config/operator-group-openshift-operators-redhat.yaml
#oc apply -f day2_config/subscription-elastic-search-operator.yaml

echo "Install Loki Operator..."
#oc apply -f day2_config/subscription-loki-operator.yaml

echo "Install OpenShift Logging Operator..."
#oc apply -f day2_config/namespace-openshift-logging.yaml
#oc apply -f day2_config/operator-group-cluster-logging.yaml
#oc apply -f day2_config/subscription-cluster-logging.yaml

echo "Install OpenShift Distributed Tracing Operator..."
#oc apply -f day2_config/namespace-openshift-distributed-tracing.yaml
#oc apply -f day2_config/operator-group-openshift-distributed-tracing.yaml
#oc apply -f day2_config/subscription-openshift-distributed-tracing.yaml

echo "Install OSSM Kiali Operator..."
#oc apply -f day2_config/subscription-kiali-ossm.yaml

echo "Install OpenShift Service Mesh Operator..."
#oc apply -f day2_config/subscription-servicemeshoperator.yaml

echo "Install OpenShift Service Mesh Console Operator..."
#oc apply -f day2_config/subscription-ossmconsole.yaml

echo "Install Network Observability Operator..."
#oc apply -f day2_config/namespace-openshift-netobserv-operator.yaml
#oc apply -f day2_config/operator-group-openshift-netobserv-operator.yaml
#oc apply -f day2_config/subscription-netobserv-operator.yaml

echo "Install Advanced Cluster Management Operator..."
#oc apply -f day2_config/namespace-open-cluster-management.yaml
#oc apply -f day2_config/operator-group-open-cluster-management.yaml
#oc apply -f day2_config/subscription-advanced-cluster-management.yaml

echo "Install Advanced Cluster Security Operator..."
#oc apply -f day2_config/namespace-rhacs-operator.yaml
#oc apply -f day2_config/operator-group-rhacs-operator.yaml
#oc apply -f day2_config/subscription-rhacs-operator.yaml

echo "Install OpenShift GitOps Operator..."
#oc apply -f day2_config/subscription-gitops.yaml

echo "Create S3 bucket for Openshift Logging Loki stack..."
#OL_LOKI_BUCKET=$(create_s3_bucket $(oc get infrastructure cluster -o jsonpath="{.status.infrastructureName}") openshift-logging-lokistack)
echo S3 OpenShift Logging Loki Bucket name: $OL_LOKI_BUCKET

echo "Create secret for OpenShift Logging Loki bucket access..."
#oc create secret generic logging-loki-s3 -n openshift-logging --from-literal=access_key_id=$AWS_ACCESS_KEY_ID --from-literal=access_key_secret=$AWS_SECRET_ACCESS_KEY --from-literal=bucketnames=$OL_LOKI_BUCKET --from-literal=region=$AWS_DEFAULT_REGION --from-literal=endpoint=https://s3.$AWS_DEFAULT_REGION.amazonaws.com

#echo "Create S3 bucket for Network Observability Loki stack..."
#NO_LOKI_BUCKET=$(create_s3_bucket $(oc get infrastructure cluster -o jsonpath="{.status.infrastructureName}") network-observability-lokistack)
#echo S3 Network Observability Loki Bucket name: $NO_LOKI_BUCKET

#echo "Create Network Observability namespace..."
#oc apply -f day2_config/namespace-netobserv.yaml

#echo "Create secret for Network Observability Loki bucket access..."
#oc create secret generic loki-s3 -n netobserv --from-literal=access_key_id=$AWS_ACCESS_KEY_ID --from-literal=access_key_secret=$AWS_SECRET_ACCESS_KEY --from-literal=bucketnames=$NO_LOKI_BUCKET --from-literal=region=$AWS_DEFAULT_REGION --from-literal=endpoint=https://s3.$AWS_DEFAULT_REGION.amazonaws.com

echo "Checking Loki Operator installation is completed..."
#while true; do oc get crd lokistacks.loki.grafana.com 2>/dev/null 1>&2 && break; done

echo "Create Loki Stack for OpenShift Logging..."
#oc apply -f day2_config/lokistack-logging-loki.yaml

#echo "Create Loki Stack for Network Observability..."
#oc apply -f day2_config/lokistack-loki.yaml

echo "Checking OpenShift Logging installation is completed..."
#while true; do oc get crd clusterloggings.logging.openshift.io 2>/dev/null 1>&2 && break; done

echo "Create OpenShift Logging instance"
#oc apply -f day2_config/cluster-logging-instance.yaml

#echo "Create Permissions for Network Observability"
#oc apply -f day2_config/authentication-authorization-network-observability.yaml

#echo "Checking Network Observability is completed..."
#while true; do oc get crd flowcollectors.flows.netobserv.io 2>/dev/null 1>&2 && break; done

#echo "Create FlowCollector for Network Observability"
#oc apply -f day2_config/flowcollector-cluster.yaml

echo "----------------------------"
echo "Your cluster API URL is:"
oc whoami --show-server
echo "----------------------------"
echo "Your cluster console URL is:"
oc whoami --show-console
echo "----------------------------"


