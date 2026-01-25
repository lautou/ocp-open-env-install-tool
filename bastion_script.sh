#!/bin/bash
set -e

BASTION_EXECUTION_LOG="bastion_execution.log"
exec &> >(tee -a "$BASTION_EXECUTION_LOG")

echo "Starting bastion_script.sh execution..."
echo "Date: $(date)"

check_prerequisites() {
  echo "--- Checking Prerequisites (Software installed by UserData) ---"
  local missing_tools=0
  local tools=("wget" "jq" "unzip" "htpasswd" "yq" "aws" "oc" "openshift-install" "tmux")

  for tool in "${tools[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
      echo "❌ ERROR: Required tool '$tool' is missing."
      missing_tools=$((missing_tools + 1))
    else
      echo "✅ Found $tool: $(command -v $tool)"
    fi
  done

  if [ "$missing_tools" -gt 0 ]; then
    echo "⛔ CRITICAL: $missing_tools required tools are missing. UserData provisioning might have failed."
    echo "   Check /var/log/cloud-init-output.log for installation errors."
    exit 1
  fi
  echo "--- All prerequisites met. Proceeding... ---"
}

# 1. Source Config
if [[ ! -f ocp_rhdp.config ]]; then
  echo "ERROR: ocp_rhdp.config not found!"
  exit 1
fi
. ocp_rhdp.config

if [[ -f aws_lib.sh ]]; then
    . aws_lib.sh
else
    echo "ERROR: aws_lib.sh not found."
    exit 1
fi

PULL_SECRET_FILE_PATH="$HOME/pull-secret.txt"
if [ ! -f "$PULL_SECRET_FILE_PATH" ]; then
  echo "ERROR: Pull secret file not found."
  exit 2
fi
PULL_SECRET_CONTENT=$(cat "$PULL_SECRET_FILE_PATH")

GITOPS_OPERATOR_FILE="day2_config/gitops/openshift-gitops-operator.yaml"

# 2. RUN CHECKS (Before doing anything else)
check_prerequisites

# 3. Setup AWS Credentials (User Data runs as root, this runs as ec2-user, so we need config)
echo "Configuring AWS CLI for user $(whoami)..."
mkdir -p ~/.aws
cat <<EOF > ~/.aws/credentials
[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
EOF
chmod 600 ~/.aws/credentials

aws configure set default.region "$AWS_DEFAULT_REGION"
aws configure set default.output json

echo "Verifying AWS CLI identity..."
if ! aws sts get-caller-identity > /dev/null; then
  echo "ERROR: AWS STS GetCallerIdentity failed. Check keys."
  exit 8
fi

# 4. Generate SSH Key
echo "Generating SSH key..."
mkdir -p "$HOME/.ssh"
rm -f "$HOME/.ssh/id_rsa" "$HOME/.ssh/id_rsa.pub"
ssh-keygen -q -N "" -f "$HOME/.ssh/id_rsa" <<<y >/dev/null 2>&1

# 5. Start Installation Logic
INSTALL_DIRNAME="cluster-install"
OCP_INSTALL_PATH="openshift-install" # Now in path
CFN_TEMPLATES_DIR="cloudformation_templates"
CFN_GENERATED_PARAMS_DIR="cfn_generated_parameters"
mkdir -p "$CFN_GENERATED_PARAMS_DIR"

echo "Creating installation directory: $INSTALL_DIRNAME"
rm -rf "$INSTALL_DIRNAME"
mkdir -p "$INSTALL_DIRNAME"

echo "Preparing install-config.yaml..."
SSH_PUB_KEY_FILE_PATH="$HOME/.ssh/id_rsa.pub"
SSH_KEY_CONTENT=$(cat "$SSH_PUB_KEY_FILE_PATH")

cat <<EOF > "$INSTALL_DIRNAME/install-config.yaml"
apiVersion: v1
baseDomain: ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN#.}
metadata:
  name: $CLUSTER_NAME
platform:
  aws:
    region: $AWS_DEFAULT_REGION
pullSecret: '$(echo "$PULL_SECRET_CONTENT" | sed "s/'/'\\\\''/g")'
sshKey: |
  $SSH_KEY_CONTENT
EOF

if [ "$INSTALL_TYPE" == "IPI" ]; then
  cat <<EOF_IPI >> "$INSTALL_DIRNAME/install-config.yaml"
controlPlane:
  name: master
  platform:
    aws:
      type: $AWS_INSTANCE_TYPE_CONTROLPLANE_NODES
compute:
- name: worker
  platform:
    aws:
      type: $AWS_INSTANCE_TYPE_COMPUTE_NODES
  replicas: $AWS_WORKERS_COUNT
EOF_IPI
fi

echo "Generated install-config.yaml"
yq e 'del(.pullSecret)' "$INSTALL_DIRNAME/install-config.yaml"

configure_oauth_secret() {
  echo "--- Configuring OAuth htpasswd secret ---"

  if [[ -z "$OCP_ADMIN_PASSWORD" ]] || [[ -z "$OCP_NON_ADMIN_PASSWORD" ]]; then
    echo "ERROR: OCP passwords not set."
    return 1
  fi

  local htpasswd_file="users.htpasswd"
  trap 'rm -f "$htpasswd_file"' RETURN
  htpasswd -c -B -b "$htpasswd_file" admin "$OCP_ADMIN_PASSWORD"
  local users=("karla" "andrew" "bob" "marina")
  for user in "${users[@]}"; do
    htpasswd -B -b "$htpasswd_file" "$user" "$OCP_NON_ADMIN_PASSWORD"
  done
  if ! oc get ns openshift-config &> /dev/null; then
    echo "ERROR: Namespace openshift-config not found."
    return 1
  fi
  oc create secret generic htpass-secret --from-file=htpasswd="$htpasswd_file" -n openshift-config --dry-run=client -o yaml | oc apply -f -
  oc annotate secret htpass-secret -n openshift-config "argocd.argoproj.io/sync-options=Delete=false" --overwrite
  echo "--- OAuth configured ---"
}

configure_day2_gitops() {
  echo "--- Starting Day2 GitOps ---"
  local day2_success=false

  if ! oc whoami &> /dev/null; then
    echo "ERROR: Day2: Cannot connect to cluster."
    return 1
  fi
  oc whoami

  local cluster_versions_file="argocd/common/cluster-versions.yaml"
  local gitops_version=$(yq '.data.openshift-gitops' "$cluster_versions_file")

  if [[ -n "$gitops_version" ]] && [[ "$gitops_version" != "null" ]]; then
    yq -i 'select(.kind == "Subscription").spec.channel = "'"$gitops_version"'"' "$GITOPS_OPERATOR_FILE"
  else
    echo "WARN: Could not find 'openshift-gitops' version in $cluster_versions_file. Using default from manifest."
  fi

  echo "Day2: Installing OpenShift GitOps Operator..."
  if ! oc create -f "$GITOPS_OPERATOR_FILE"; then
    echo "ERROR: Day2: Failed to apply $GITOPS_OPERATOR_FILE."
    return 1
  fi

  echo "Day2: Waiting for OpenShift GitOps Operator Subscription..."
  if ! oc wait sub openshift-gitops-operator -n openshift-gitops-operator --for jsonpath='{.status.installPlanRef.name}' --timeout 300s; then
    echo "ERROR: Day2: Timeout waiting for GitOps Subscription InstallPlan."
    return 1
  fi
  local day2_install_plan_name=$(oc get sub openshift-gitops-operator -n openshift-gitops-operator -o jsonpath='{.status.installPlanRef.name}')
  local day2_csv_name=$(oc get installplan "$day2_install_plan_name" -n openshift-gitops-operator -o jsonpath='{.spec.clusterServiceVersionNames[0]}')
  echo "Day2: Found InstallPlan: $day2_install_plan_name for CSV: $day2_csv_name."

  echo -n "Day2: Waiting for CSV '$day2_csv_name' to be created..."
  local csv_exists_timeout=120
  while ! oc get csv "$day2_csv_name" -n openshift-gitops-operator > /dev/null 2>&1; do
    csv_exists_timeout=$((csv_exists_timeout - 5))
    if [ "$csv_exists_timeout" -le 0 ]; then
      echo "ERROR: Day2: Timeout waiting for CSV '$day2_csv_name' to be created."
      return 1
    fi
    echo -n "."
    sleep 5
  done
  echo " CSV '$day2_csv_name' created."

  echo -n "Day2: Waiting for OpenShift GitOps Operator CSV '$day2_csv_name' to succeed..."
  if ! oc wait csv "$day2_csv_name" -n openshift-gitops-operator --for jsonpath='{.status.phase}'=Succeeded --timeout 600s > /dev/null; then
    echo "ERROR: Day2: Timeout waiting for GitOps CSV '$day2_csv_name'."
    return 1
  fi
  echo " Day2: OpenShift GitOps Operator successfully installed."

  if [[ -n "$GIT_CREDENTIALS_TEMPLATE_URL" ]] && [[ -n "$GIT_CREDENTIALS_TEMPLATE_TOKEN_NAME" ]] && [[ -n "$GIT_CREDENTIALS_TEMPLATE_TOKEN_SECRET" ]]; then
    echo "Day2: Creating/Updating git repository credentials template secret..."
    oc create secret generic creds-cluster \
      --from-literal=username="$GIT_CREDENTIALS_TEMPLATE_TOKEN_NAME" \
      --from-literal=password="$GIT_CREDENTIALS_TEMPLATE_TOKEN_SECRET" \
      --from-literal=url="$GIT_CREDENTIALS_TEMPLATE_URL" -n openshift-gitops --dry-run=client -o yaml | oc apply -f -
    oc label secret creds-cluster argocd.argoproj.io/secret-type=repo-creds -n openshift-gitops --overwrite
  fi

  if [[ -n "$GIT_REPO_TOKEN_NAME" ]] && [[ -n "$GIT_REPO_TOKEN_SECRET" ]]; then
    echo "Day2: Creating/Updating git repository secret for GitOps repo..."
    oc create secret generic git-app-cluster \
      --from-literal=username="$GIT_REPO_TOKEN_NAME" \
      --from-literal=password="$GIT_REPO_TOKEN_SECRET" \
      --from-literal=type=git \
      --from-literal=url="$GIT_REPO_URL" \
      --from-literal=project=default -n openshift-gitops --dry-run=client -o yaml | oc apply -f -
    oc label secret git-app-cluster argocd.argoproj.io/secret-type=repository -n openshift-gitops --overwrite
  fi

  echo "Day2: Applying Day2 config through GitOps ApplicationSet..."
  if [ ! -d day2_config/_generated ]; then
    mkdir -p day2_config/_generated
  fi
  cat <<EOF_PATCH > day2_config/_generated/applicationset-patch.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster
  namespace: openshift-gitops
spec:
  template:
    spec:
      source:
        repoURL: "$GIT_REPO_URL"
EOF_PATCH
  echo "Day2: Generated patch file day2_config/_generated/applicationset-patch.yaml"

  if oc apply -k day2_config; then
    echo "Day2: Day2 GitOps ApplicationSet applied successfully."
    day2_success=true
  else
    echo "ERROR: Day2: Failed to apply Day2 kustomization."
    oc kustomize day2_config || echo "Day2: oc kustomize day2_config also failed."
    return 1
  fi

  if [[ "$day2_success" == "true" ]]; then
    echo "Day2: Configuration successful. Removing kubeadmin secret..."
    oc delete secrets kubeadmin -n kube-system --ignore-not-found=true
  else
    echo "WARN: Day2: Configuration did not fully succeed. Kubeadmin secret will not be removed by this function."
  fi
  echo "--- Day2 GitOps/ArgoCD Configuration Finished ---"
  return 0 
}

distribute_nodes() {
  local total_nodes=$1
  local num_distributions=$2
  local base_nodes_per_dist=$((total_nodes / num_distributions))
  local remainder_nodes=$((total_nodes % num_distributions))
  local distribution_array=()
  for i in $(seq 1 "$num_distributions"); do distribution_array+=($base_nodes_per_dist); done
  for i in $(seq 1 "$remainder_nodes"); do local idx=$((i - 1)); distribution_array[$idx]=$((${distribution_array[$idx]} + 1)); done
  echo "${distribution_array[@]}"
}

configure_upi_node_roles_and_taints() {
  echo "--- Starting UPI Node Role and Taint Configuration ---"
  if ! oc whoami &> /dev/null; then
    echo "ERROR: UPI Node Config: Cannot connect to cluster. KUBECONFIG: $KUBECONFIG"
    return 1
  fi
  oc whoami

  echo "UPI Node Config: Identifying nodes by checking their EC2 instance tags..."
  ALL_NODES_JSON=$(oc get nodes -o json 2>/dev/null)
  if [ -z "$ALL_NODES_JSON" ]; then
    echo "ERROR: UPI Node Config: Could not get list of nodes from the cluster."
    return 1
  fi

  INFRA_NODES_TO_CONFIGURE=""
  STORAGE_NODES_TO_CONFIGURE=""

  # Loop through all nodes fetched from Kubernetes
  for node_name in $(echo "$ALL_NODES_JSON" | jq -r '.items[].metadata.name'); do
    provider_id=$(echo "$ALL_NODES_JSON" | jq -r ".items[] | select(.metadata.name==\"$node_name\") | .spec.providerID")
    
    if [ -z "$provider_id" ] || [[ "$provider_id" != aws* ]]; then
      echo "UPI Node Config: Skipping node $node_name, providerID ('$provider_id') not found or not an AWS instance."
      continue
    fi
    
    instance_id=$(basename "$provider_id")
    if [ -z "$instance_id" ]; then
        echo "UPI Node Config: Could not extract instance ID from providerID '$provider_id' for node $node_name."
        continue
    fi

    echo "UPI Node Config: Checking EC2 tags for node $node_name (Instance ID: $instance_id)..."
    
    instance_tags_json=$(aws ec2 describe-instances --instance-ids "$instance_id" --query "Reservations[].Instances[].Tags[]" --output json 2>/dev/null)
    if [ -z "$instance_tags_json" ]; then
        echo "UPI Node Config: Could not retrieve tags for instance $instance_id (node $node_name)."
        continue
    fi

    node_group_tag_value=$(echo "$instance_tags_json" | jq -r '.[] | select(.Key=="NodeGroup") | .Value')

    if [ "$node_group_tag_value" == "infra" ]; then
      echo "UPI Node Config: Node $node_name (Instance ID: $instance_id) identified as INFRA via EC2 tag 'NodeGroup=infra'."
      INFRA_NODES_TO_CONFIGURE="$INFRA_NODES_TO_CONFIGURE $node_name"
    elif [ "$node_group_tag_value" == "storage" ]; then
      echo "UPI Node Config: Node $node_name (Instance ID: $instance_id) identified as STORAGE via EC2 tag 'NodeGroup=storage'."
      STORAGE_NODES_TO_CONFIGURE="$STORAGE_NODES_TO_CONFIGURE $node_name"
    else
      echo "UPI Node Config: Node $node_name (Instance ID: $instance_id) is not an infra or storage node based on 'NodeGroup' EC2 tag (value: '$node_group_tag_value'). Skipping role-specific configuration."
    fi
  done

  # Trim leading/trailing whitespace from the accumulated node lists
  INFRA_NODES_TO_CONFIGURE=$(echo "$INFRA_NODES_TO_CONFIGURE" | xargs)
  STORAGE_NODES_TO_CONFIGURE=$(echo "$STORAGE_NODES_TO_CONFIGURE" | xargs)

  if [ -z "$INFRA_NODES_TO_CONFIGURE" ]; then
    echo "UPI Node Config: No infra nodes identified to configure based on EC2 tags."
  else
    echo "UPI Node Config: Will configure infra nodes: [$INFRA_NODES_TO_CONFIGURE]"
    for node_name in $INFRA_NODES_TO_CONFIGURE; do
      echo "UPI Node Config: Configuring infra node: $node_name"
      oc label node "$node_name" node-role.kubernetes.io/infra="" --overwrite || echo "WARN: Failed to apply infra label to $node_name"
      oc adm taint node "$node_name" node-role.kubernetes.io/infra=:NoSchedule --overwrite || echo "WARN: Failed to apply NoSchedule infra taint to $node_name"
      echo "UPI Node Config: Finished configuring infra node: $node_name"
    done
  fi

  if [ -z "$STORAGE_NODES_TO_CONFIGURE" ]; then
    echo "UPI Node Config: No storage nodes identified to configure based on EC2 tags."
  else
    echo "UPI Node Config: Will configure storage nodes: [$STORAGE_NODES_TO_CONFIGURE]"
    for node_name in $STORAGE_NODES_TO_CONFIGURE; do
      echo "UPI Node Config: Configuring storage node: $node_name"
      oc label node "$node_name" node-role.kubernetes.io/infra="" --overwrite || echo "WARN: Failed to apply infra label to storage node $node_name"
      oc label node "$node_name" cluster.ocs.openshift.io/openshift-storage="" --overwrite || echo "WARN: Failed to apply ocs-storage label to $node_name"
      
      # Apply infra taints as storage nodes can also run infra workloads
      oc adm taint node "$node_name" node-role.kubernetes.io/infra=:NoSchedule --overwrite || echo "WARN: Failed to apply NoSchedule infra taint to storage node $node_name"
      
      # Apply OCS/ODF specific taints (consistent with IPI and ODF operator expectations)
      oc adm taint node "$node_name" node.ocs.openshift.io/storage=true:NoSchedule --overwrite || echo "WARN: Failed to apply NoSchedule OCS taint to $node_name"
      
      echo "UPI Node Config: Finished configuring storage node: $node_name"
    done
  fi

  echo "--- UPI Node Role and Taint Configuration Finished ---"
  return 0
}

if [ "$INSTALL_TYPE" == "IPI" ]; then
  echo "-----------------------------------------------------"
  echo "Starting IPI Installation Process"
  echo "-----------------------------------------------------"
  echo "Generating manifests..."
  "$OCP_INSTALL_PATH" create manifests --dir "$INSTALL_DIRNAME"

  mapfile -t AZ_WORKER_MS_FILES < <(find "$INSTALL_DIRNAME/openshift/" -name "99_openshift-cluster-api_worker-machineset-*.yaml" | sort)
  NUM_AZ_WORKER_MS_FILES=${#AZ_WORKER_MS_FILES[@]}
  echo "Found $NUM_AZ_WORKER_MS_FILES base worker MachineSet files."

  echo "Worker distribution is handled by install-config.yaml replicas and installer defaults."

  echo "Creating MachineSets for infra nodes..."
  if [[ "$AWS_INFRA_NODES_COUNT" -gt 0 ]] && [[ "$NUM_AZ_WORKER_MS_FILES" -gt 0 ]]; then
    INFRA_DISTRIBUTION=($(distribute_nodes "$AWS_INFRA_NODES_COUNT" "$NUM_AZ_WORKER_MS_FILES"))
    for i in $(seq 0 $(($NUM_AZ_WORKER_MS_FILES - 1)) ); do
      REPLICAS_FOR_THIS_AZ_MS=${INFRA_DISTRIBUTION[$i]:-0}
      if [[ "$REPLICAS_FOR_THIS_AZ_MS" -eq 0 ]]; then continue; fi

      MS_INFRA_BASE_FILE="${AZ_WORKER_MS_FILES[$i]}"
      if [ -f "$MS_INFRA_BASE_FILE" ]; then
        BASE_MS_NAME=$(yq '.metadata.name' "$MS_INFRA_BASE_FILE")
        MS_INFRA_NAME="${BASE_MS_NAME/worker/infra}"
        MS_INFRA_TARGET_FILE="$INSTALL_DIRNAME/openshift/98_openshift-cluster-api_infra-machineset-$i.yaml"
        cp "$MS_INFRA_BASE_FILE" "$MS_INFRA_TARGET_FILE"
        yq e -i ".metadata.name = \"$MS_INFRA_NAME\"" "$MS_INFRA_TARGET_FILE"
        yq e -i ".spec.replicas = $REPLICAS_FOR_THIS_AZ_MS" "$MS_INFRA_TARGET_FILE"
        yq e -i ".spec.selector.matchLabels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_INFRA_NAME\"" "$MS_INFRA_TARGET_FILE"
        yq e -i ".spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_INFRA_NAME\"" "$MS_INFRA_TARGET_FILE"
        yq e -i ".spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-role\"] = \"infra\"" "$MS_INFRA_TARGET_FILE"
        yq e -i ".spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-type\"] = \"infra\"" "$MS_INFRA_TARGET_FILE"
        yq e -i ".spec.template.spec.metadata.labels.\"node-role.kubernetes.io/infra\" = \"\"" "$MS_INFRA_TARGET_FILE"
        yq e -i ".spec.template.spec.providerSpec.value.instanceType = \"$AWS_INSTANCE_TYPE_INFRA_NODES\"" "$MS_INFRA_TARGET_FILE"
        yq e -i ".spec.template.spec.taints = [{\"key\": \"node-role.kubernetes.io/infra\", \"effect\": \"NoSchedule\"}]" "$MS_INFRA_TARGET_FILE"
        echo "Generated infra MachineSet: $MS_INFRA_TARGET_FILE with $REPLICAS_FOR_THIS_AZ_MS replicas."
      else
        echo "WARNING: Base worker machineset $MS_INFRA_BASE_FILE not found."
      fi
    done
  else
    echo "AWS_INFRA_NODES_COUNT is 0 or no base worker MS files. Skipping infra MachineSet."
  fi

  echo "Creating MachineSet for storage nodes..."
  if [[ "$AWS_STORAGE_NODES_COUNT" -gt 0 ]] && [[ "$NUM_AZ_WORKER_MS_FILES" -gt 0 ]]; then
    STORAGE_DISTRIBUTION=($(distribute_nodes "$AWS_STORAGE_NODES_COUNT" "$NUM_AZ_WORKER_MS_FILES"))
    for i in $(seq 0 $(($NUM_AZ_WORKER_MS_FILES - 1)) ); do
      REPLICAS_FOR_THIS_AZ_MS=${STORAGE_DISTRIBUTION[$i]:-0}
      if [[ "$REPLICAS_FOR_THIS_AZ_MS" -eq 0 ]]; then continue; fi

      MS_STORAGE_BASE_FILE="${AZ_WORKER_MS_FILES[$i]}"
      if [ -f "$MS_STORAGE_BASE_FILE" ]; then
        BASE_MS_NAME=$(yq '.metadata.name' "$MS_STORAGE_BASE_FILE")
        MS_STORAGE_NAME="${BASE_MS_NAME/worker/storage}"
        MS_STORAGE_TARGET_FILE="$INSTALL_DIRNAME/openshift/98_openshift-cluster-api_storage-machineset-$i.yaml"
        cp "$MS_STORAGE_BASE_FILE" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".metadata.name = \"$MS_STORAGE_NAME\"" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.replicas = $REPLICAS_FOR_THIS_AZ_MS" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.selector.matchLabels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_STORAGE_NAME\"" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machineset\"] = \"$MS_STORAGE_NAME\"" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-role\"] = \"infra\"" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.template.metadata.labels[\"machine.openshift.io/cluster-api-machine-type\"] = \"infra\"" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.template.spec.metadata.labels.\"node-role.kubernetes.io/infra\" = \"\"" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.template.spec.metadata.labels.\"cluster.ocs.openshift.io/openshift-storage\" = \"\"" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.template.spec.providerSpec.value.instanceType = \"$AWS_INSTANCE_TYPE_STORAGE_NODES\"" "$MS_STORAGE_TARGET_FILE"
        yq e -i ".spec.template.spec.taints = [{\"key\": \"node.ocs.openshift.io/storage\", \"value\": \"true\", \"effect\": \"NoSchedule\"}]" "$MS_STORAGE_TARGET_FILE"
        echo "Generated storage MachineSet: $MS_STORAGE_TARGET_FILE with $REPLICAS_FOR_THIS_AZ_MS replicas."
      else
        echo "WARNING: Base worker machineset $MS_STORAGE_BASE_FILE not found."
      fi
    done
  else
    echo "AWS_STORAGE_NODES_COUNT is 0 or no base worker MS files. Skipping storage MachineSet."
  fi

  echo "Adding Day1 MachineConfig manifests..."
  if [ -d "day1_config/machineconfig" ] && [ -n "$(ls -A day1_config/machineconfig/*.yaml 2>/dev/null)" ]; then
    cp day1_config/machineconfig/*.yaml "$INSTALL_DIRNAME/openshift/"
  fi

  echo "Adding Day1 network configuration manifests..."
  if [ -d "day1_config/network" ] && [ -n "$(ls -A day1_config/network/*.yaml 2>/dev/null)" ]; then
    cp day1_config/network/*.yaml "$INSTALL_DIRNAME/manifests/"
  fi

  echo "Creating the cluster..."
  "$OCP_INSTALL_PATH" create cluster --dir "$INSTALL_DIRNAME" --log-level=info
  echo "Cluster installation finished."

  KUBECONFIG_PATH="$HOME/$INSTALL_DIRNAME/auth/kubeconfig"
  echo "Exporting KUBECONFIG to $KUBECONFIG_PATH..."
  export KUBECONFIG="$KUBECONFIG_PATH"
  echo "export KUBECONFIG=$KUBECONFIG_PATH" >> "$HOME/.bashrc"

elif [ "$INSTALL_TYPE" == "UPI" ]; then
  echo "-----------------------------------------------------"
  echo "Starting UPI Installation Process"
  echo "-----------------------------------------------------"

  UPI_S3_BUCKET_NAME="${CLUSTER_NAME,,}-$(date +%s)-infra"
  CLUSTER_FQDN_BASE="${CLUSTER_NAME}${RHDP_TOP_LEVEL_ROUTE53_DOMAIN}"
  UPI_MASTER_COUNT=3
  CFN_STACK_PREFIX="${CLUSTER_NAME,,}-cfn"

  echo "Determining RHCOS AMI ID..."
  RHCOS_AMI_ID=$("$OCP_INSTALL_PATH" coreos print-stream-json | jq -r ".architectures.x86_64.images.aws.regions[\"$AWS_DEFAULT_REGION\"].image")
  if [ -z "$RHCOS_AMI_ID" ] || [ "$RHCOS_AMI_ID" == "null" ]; then echo "ERROR: Failed to determine RHCOS AMI ID."; exit 16; fi
  echo "Using RHCOS AMI ID: $RHCOS_AMI_ID."

  echo "Generating installation manifests..."
  "$OCP_INSTALL_PATH" create manifests --dir "$INSTALL_DIRNAME" --log-level=info
  echo "Installation manifests generated."

  echo "Removing managed control plane and worker Machine manifest files..."
  rm -f "$INSTALL_DIRNAME"/openshift/99_openshift-cluster-api_master-machines-*.yaml
  rm -f "$INSTALL_DIRNAME"/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml
  rm -f "$INSTALL_DIRNAME"/openshift/99_openshift-cluster-api_worker-machineset-*.yaml
  echo "Managed manifest files removed."

  echo "Generating ignition configs..."
  "$OCP_INSTALL_PATH" create ignition-configs --dir "$INSTALL_DIRNAME" --log-level=info
  echo "Ignition configs generated."

  INFRASTRUCTURE_NAME=$(jq -r .infraID "$INSTALL_DIRNAME/metadata.json")
  if [ -z "$INFRASTRUCTURE_NAME" ]; then echo "ERROR: Failed to extract infraID."; exit 18; fi
  echo "Using InfrastructureName: $INFRASTRUCTURE_NAME"

  echo "Creating S3 bucket '$UPI_S3_BUCKET_NAME' and uploading bootstrap.ign..."
  aws s3 mb "s3://${UPI_S3_BUCKET_NAME}" --region "$AWS_DEFAULT_REGION"
  aws s3 cp "$INSTALL_DIRNAME/bootstrap.ign" "s3://${UPI_S3_BUCKET_NAME}/bootstrap.ign"
  echo "Bootstrap ignition uploaded to S3."

  echo "Initiating CloudFormation stack deployments for UPI..."
  HOSTED_ZONE_NAME_R53="${RHDP_TOP_LEVEL_ROUTE53_DOMAIN#.}"

  VPC_NETWORK_STACK_NAME="${CFN_STACK_PREFIX}-network"
  VPC_TEMPLATE_FILE="${CFN_TEMPLATES_DIR}/01-vpc-network.yaml"
  VPC_PARAMETERS_JSON_FILE="${CFN_TEMPLATES_DIR}/vpc-parameters.json"
  if [ ! -f "$VPC_TEMPLATE_FILE" ] || [ ! -f "$VPC_PARAMETERS_JSON_FILE" ]; then echo "ERROR: VPC template or parameters missing."; exit 19; fi
  create_stack_and_wait "$VPC_NETWORK_STACK_NAME" "$VPC_TEMPLATE_FILE" "$VPC_PARAMETERS_JSON_FILE" "Key=ClusterName,Value=$CLUSTER_NAME Key=InstallType,Value=UPI Key=Role,Value=Network"
  NETWORK_STACK_OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$VPC_NETWORK_STACK_NAME" --query "Stacks[0].Outputs")
  VPC_ID_FROM_CFN=$(echo "$NETWORK_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="VpcId") | .OutputValue')
  PUBLIC_SUBNET_IDS_FROM_CFN_STR=$(echo "$NETWORK_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="PublicSubnetIds") | .OutputValue')
  PRIVATE_SUBNET_IDS_FROM_CFN_STR=$(echo "$NETWORK_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="PrivateSubnetIds") | .OutputValue')
  IFS=',' read -r -a PUBLIC_SUBNET_IDS_ARRAY <<< "$PUBLIC_SUBNET_IDS_FROM_CFN_STR"
  IFS=',' read -r -a PRIVATE_SUBNET_IDS_ARRAY <<< "$PRIVATE_SUBNET_IDS_FROM_CFN_STR"
  NUM_UPI_AZS=${#PRIVATE_SUBNET_IDS_ARRAY[@]}
  echo "Network stack deployed. Found $NUM_UPI_AZS private subnets."

  LOADBALANCER_STACK_NAME="${CFN_STACK_PREFIX}-loadbalancer"
  LOADBALANCER_TEMPLATE_FILE="${CFN_TEMPLATES_DIR}/02-loadbalancer.yaml"
  LOADBALANCER_PARAMETERS_JSON_FILE_TEMP="${CFN_GENERATED_PARAMS_DIR}/loadbalancer-params.json"
  HOSTED_ZONE_ID_R53=$(aws route53 list-hosted-zones-by-name --dns-name "$HOSTED_ZONE_NAME_R53" --query "HostedZones[?Name=='$HOSTED_ZONE_NAME_R53.'].Id" --output text | sed 's#.*/##')
  if [ -z "$HOSTED_ZONE_ID_R53" ]; then echo "ERROR: Hosted Zone ID for $HOSTED_ZONE_NAME_R53 not found."; exit 20; fi
  jq -n --arg cn "$CLUSTER_NAME" --arg in "$INFRASTRUCTURE_NAME" --arg hzi "$HOSTED_ZONE_ID_R53" --arg hzn "$HOSTED_ZONE_NAME_R53" --arg psids "$PUBLIC_SUBNET_IDS_FROM_CFN_STR" --arg pvids "$PRIVATE_SUBNET_IDS_FROM_CFN_STR" --arg vpcid "$VPC_ID_FROM_CFN" '[{"ParameterKey":"ClusterName","ParameterValue":$cn},{"ParameterKey":"InfrastructureName","ParameterValue":$in},{"ParameterKey":"HostedZoneId","ParameterValue":$hzi},{"ParameterKey":"HostedZoneName","ParameterValue":$hzn},{"ParameterKey":"PublicSubnets","ParameterValue":$psids},{"ParameterKey":"PrivateSubnets","ParameterValue":$pvids},{"ParameterKey":"VpcId","ParameterValue":$vpcid}]' > "$LOADBALANCER_PARAMETERS_JSON_FILE_TEMP"
  if [ ! -f "$LOADBALANCER_TEMPLATE_FILE" ]; then echo "ERROR: LoadBalancer template missing."; exit 21; fi
  create_stack_and_wait "$LOADBALANCER_STACK_NAME" "$LOADBALANCER_TEMPLATE_FILE" "$LOADBALANCER_PARAMETERS_JSON_FILE_TEMP" "Key=ClusterName,Value=$CLUSTER_NAME Key=InstallType,Value=UPI Key=Role,Value=LoadBalancer"
  LOADBALANCER_STACK_OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$LOADBALANCER_STACK_NAME" --query "Stacks[0].Outputs")
  EXTERNAL_API_TARGET_GROUP_ARN=$(echo "$LOADBALANCER_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="ExternalApiTargetGroupArn") | .OutputValue')
  INTERNAL_API_TARGET_GROUP_ARN=$(echo "$LOADBALANCER_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="InternalApiTargetGroupArn") | .OutputValue')
  INTERNAL_SERVICE_TARGET_GROUP_ARN=$(echo "$LOADBALANCER_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="InternalServiceTargetGroupArn") | .OutputValue')
  REGISTER_NLB_IP_TARGETS_LAMBDA_ARN=$(echo "$LOADBALANCER_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="RegisterNlbIpTargetsLambda") | .OutputValue')
  PRIVATE_HOSTED_ZONE_ID_FROM_LB_STACK=$(echo "$LOADBALANCER_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="PrivateHostedZoneId") | .OutputValue')
  echo "LoadBalancer stack deployed."

  SECURITY_STACK_NAME="${CFN_STACK_PREFIX}-security"
  SECURITY_TEMPLATE_FILE="${CFN_TEMPLATES_DIR}/03-security.yaml"
  SECURITY_PARAMETERS_JSON_FILE_TEMP="${CFN_GENERATED_PARAMS_DIR}/security-params.json"
  VPC_CIDR_FOR_SECURITY_STACK=$(jq -r '.[] | select(.ParameterKey=="VpcCidr") | .ParameterValue' "$VPC_PARAMETERS_JSON_FILE")
  jq -n --arg infra_name "$INFRASTRUCTURE_NAME" --arg vpc_cidr "$VPC_CIDR_FOR_SECURITY_STACK" --arg private_subnets "$PRIVATE_SUBNET_IDS_FROM_CFN_STR" --arg vpc_id "$VPC_ID_FROM_CFN" '[{"ParameterKey":"InfrastructureName","ParameterValue":$infra_name},{"ParameterKey":"VpcCidr","ParameterValue":$vpc_cidr},{"ParameterKey":"PrivateSubnets","ParameterValue":$private_subnets},{"ParameterKey":"VpcId","ParameterValue":$vpc_id}]' > "$SECURITY_PARAMETERS_JSON_FILE_TEMP"
  if [ ! -f "$SECURITY_TEMPLATE_FILE" ]; then echo "ERROR: Security template missing."; exit 22; fi
  create_stack_and_wait "$SECURITY_STACK_NAME" "$SECURITY_TEMPLATE_FILE" "$SECURITY_PARAMETERS_JSON_FILE_TEMP" "Key=ClusterName,Value=$CLUSTER_NAME Key=InstallType,Value=UPI Key=Role,Value=Security"
  SECURITY_STACK_OUTPUTS=$(aws cloudformation describe-stacks --stack-name "$SECURITY_STACK_NAME" --query "Stacks[0].Outputs")
  MASTER_SECURITY_GROUP_ID=$(echo "$SECURITY_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="MasterSecurityGroupId") | .OutputValue')
  WORKER_SECURITY_GROUP_ID=$(echo "$SECURITY_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="WorkerSecurityGroupId") | .OutputValue')
  MASTER_INSTANCE_PROFILE_NAME_PARAM_VAL=$(echo "$SECURITY_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="MasterInstanceProfile") | .OutputValue')
  WORKER_INSTANCE_PROFILE_NAME_PARAM_VAL=$(echo "$SECURITY_STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="WorkerInstanceProfile") | .OutputValue')
  echo "Security stack deployed."

  echo "Initiating parallel CloudFormation stack deployments for UPI (Bootstrap, Masters, Nodegroups)..."
  declare -a STACK_PIDS=()

  BOOTSTRAP_STACK_NAME="${CFN_STACK_PREFIX}-bootstrap"
  BOOTSTRAP_TEMPLATE_FILE="${CFN_TEMPLATES_DIR}/04-bootstrap.yaml"
  BOOTSTRAP_PARAMETERS_JSON_FILE_TEMP="${CFN_GENERATED_PARAMS_DIR}/bootstrap-params.json"
  PUBLIC_SUBNET_FOR_BOOTSTRAP=${PUBLIC_SUBNET_IDS_ARRAY[0]}
  jq -n --arg infra_name "$INFRASTRUCTURE_NAME" --arg rhcos_ami "$RHCOS_AMI_ID" --arg ssh_cidr "0.0.0.0/0" --arg pub_subnet "$PUBLIC_SUBNET_FOR_BOOTSTRAP" --arg master_sgid "$MASTER_SECURITY_GROUP_ID" --arg vpc_id "$VPC_ID_FROM_CFN" --arg bootstrap_ign_loc "s3://${UPI_S3_BUCKET_NAME}/bootstrap.ign" --arg auto_reg_elb "yes" --arg reg_lambda_arn "$REGISTER_NLB_IP_TARGETS_LAMBDA_ARN" --arg ext_api_tg_arn "$EXTERNAL_API_TARGET_GROUP_ARN" --arg int_api_tg_arn "$INTERNAL_API_TARGET_GROUP_ARN" --arg int_svc_tg_arn "$INTERNAL_SERVICE_TARGET_GROUP_ARN" '[{"ParameterKey":"InfrastructureName","ParameterValue":$infra_name},{"ParameterKey":"RhcosAmi","ParameterValue":$rhcos_ami},{"ParameterKey":"AllowedBootstrapSshCidr","ParameterValue":$ssh_cidr},{"ParameterKey":"PublicSubnet","ParameterValue":$pub_subnet},{"ParameterKey":"MasterSecurityGroupId","ParameterValue":$master_sgid},{"ParameterKey":"VpcId","ParameterValue":$vpc_id},{"ParameterKey":"BootstrapIgnitionLocation","ParameterValue":$bootstrap_ign_loc},{"ParameterKey":"AutoRegisterELB","ParameterValue":$auto_reg_elb},{"ParameterKey":"RegisterNlbIpTargetsLambdaArn","ParameterValue":$reg_lambda_arn},{"ParameterKey":"ExternalApiTargetGroupArn","ParameterValue":$ext_api_tg_arn},{"ParameterKey":"InternalApiTargetGroupArn","ParameterValue":$int_api_tg_arn},{"ParameterKey":"InternalServiceTargetGroupArn","ParameterValue":$int_svc_tg_arn}]' > "$BOOTSTRAP_PARAMETERS_JSON_FILE_TEMP"
  if [ ! -f "$BOOTSTRAP_TEMPLATE_FILE" ]; then echo "ERROR: Bootstrap template missing."; exit 23; fi

  echo "Starting Bootstrap stack ($BOOTSTRAP_STACK_NAME) deployment in background..."
  create_stack_and_wait "$BOOTSTRAP_STACK_NAME" "$BOOTSTRAP_TEMPLATE_FILE" "$BOOTSTRAP_PARAMETERS_JSON_FILE_TEMP" "Key=ClusterName,Value=$CLUSTER_NAME Key=InstallType,Value=UPI Key=Role,Value=Bootstrap" &
  STACK_PIDS+=($!)
  echo "Bootstrap stack ($BOOTSTRAP_STACK_NAME) deployment initiated in background (PID: ${STACK_PIDS[${#STACK_PIDS[@]}-1]})."

  MASTERS_STACK_NAME="${CFN_STACK_PREFIX}-masters"
  MASTERS_TEMPLATE_FILE="${CFN_TEMPLATES_DIR}/05-control-plane.yaml"
  MASTERS_PARAMETERS_JSON_FILE_TEMP="${CFN_GENERATED_PARAMS_DIR}/masters-params.json"
  PRIVATE_HOSTED_ZONE_NAME_FOR_MASTERS="${CLUSTER_NAME}.${HOSTED_ZONE_NAME_R53}"
  CERTIFICATE_AUTHORITIES_DATA=$(jq -r '.ignition.security.tls.certificateAuthorities[0].source // ""' "$INSTALL_DIRNAME/master.ign")
  jq -n --arg infra_name "$INFRASTRUCTURE_NAME" --arg rhcos_ami "$RHCOS_AMI_ID" --arg auto_dns "yes" --arg priv_hz_id "$PRIVATE_HOSTED_ZONE_ID_FROM_LB_STACK" --arg priv_hz_name "$PRIVATE_HOSTED_ZONE_NAME_FOR_MASTERS" --arg master0_subnet "${PRIVATE_SUBNET_IDS_ARRAY[0]}" --arg master1_subnet "${PRIVATE_SUBNET_IDS_ARRAY[1]}" --arg master2_subnet "${PRIVATE_SUBNET_IDS_ARRAY[2]}" --arg master_sgid "$MASTER_SECURITY_GROUP_ID" --arg ign_loc "https://api-int.${CLUSTER_FQDN_BASE}:22623/config/master" --arg cert_auth "$CERTIFICATE_AUTHORITIES_DATA" --arg master_profile_name "$MASTER_INSTANCE_PROFILE_NAME_PARAM_VAL" --arg master_inst_type "$AWS_INSTANCE_TYPE_CONTROLPLANE_NODES" --arg auto_reg_elb "yes" --arg reg_lambda_arn "$REGISTER_NLB_IP_TARGETS_LAMBDA_ARN" --arg ext_api_tg_arn "$EXTERNAL_API_TARGET_GROUP_ARN" --arg int_api_tg_arn "$INTERNAL_API_TARGET_GROUP_ARN" --arg int_svc_tg_arn "$INTERNAL_SERVICE_TARGET_GROUP_ARN" '[{"ParameterKey":"InfrastructureName","ParameterValue":$infra_name},{"ParameterKey":"RhcosAmi","ParameterValue":$rhcos_ami},{"ParameterKey":"AutoRegisterDNS","ParameterValue":$auto_dns},{"ParameterKey":"PrivateHostedZoneId","ParameterValue":$priv_hz_id},{"ParameterKey":"PrivateHostedZoneName","ParameterValue":$priv_hz_name},{"ParameterKey":"Master0Subnet","ParameterValue":$master0_subnet},{"ParameterKey":"Master1Subnet","ParameterValue":$master1_subnet},{"ParameterKey":"Master2Subnet","ParameterValue":$master2_subnet},{"ParameterKey":"MasterSecurityGroupId","ParameterValue":$master_sgid},{"ParameterKey":"IgnitionLocation","ParameterValue":$ign_loc},{"ParameterKey":"CertificateAuthorities","ParameterValue":$cert_auth},{"ParameterKey":"MasterInstanceProfileName","ParameterValue":$master_profile_name},{"ParameterKey":"MasterInstanceType","ParameterValue":$master_inst_type},{"ParameterKey":"AutoRegisterELB","ParameterValue":$auto_reg_elb},{"ParameterKey":"RegisterNlbIpTargetsLambdaArn","ParameterValue":$reg_lambda_arn},{"ParameterKey":"ExternalApiTargetGroupArn","ParameterValue":$ext_api_tg_arn},{"ParameterKey":"InternalApiTargetGroupArn","ParameterValue":$int_api_tg_arn},{"ParameterKey":"InternalServiceTargetGroupArn","ParameterValue":$int_svc_tg_arn}]' > "$MASTERS_PARAMETERS_JSON_FILE_TEMP"
  if [ ! -f "$MASTERS_TEMPLATE_FILE" ]; then echo "ERROR: Masters template missing."; exit 24; fi

  echo "Starting Masters stack ($MASTERS_STACK_NAME) deployment in background..."
  create_stack_and_wait "$MASTERS_STACK_NAME" "$MASTERS_TEMPLATE_FILE" "$MASTERS_PARAMETERS_JSON_FILE_TEMP" "Key=ClusterName,Value=$CLUSTER_NAME Key=InstallType,Value=UPI Key=Role,Value=Masters" &
  STACK_PIDS+=($!)
  echo "Masters stack ($MASTERS_STACK_NAME) deployment initiated in background (PID: ${STACK_PIDS[${#STACK_PIDS[@]}-1]})."

  NODEGROUP_TEMPLATE_FILE="${CFN_TEMPLATES_DIR}/06-nodegroup.yaml"
  NODE_ROLES=("worker" "infra" "storage")
  NODE_COUNTS=("$AWS_WORKERS_COUNT" "$AWS_INFRA_NODES_COUNT" "$AWS_STORAGE_NODES_COUNT")
  INSTANCE_TYPES=("$AWS_INSTANCE_TYPE_COMPUTE_NODES" "$AWS_INSTANCE_TYPE_INFRA_NODES" "$AWS_INSTANCE_TYPE_STORAGE_NODES")

  for idx in ${!NODE_ROLES[@]}; do
    ROLE_NAME=${NODE_ROLES[$idx]}
    TOTAL_DESIRED_NODES=${NODE_COUNTS[$idx]}
    INSTANCE_TYPE=${INSTANCE_TYPES[$idx]}

    if [[ "$TOTAL_DESIRED_NODES" -gt 0 ]] && [[ "$NUM_UPI_AZS" -gt 0 ]]; then
      echo "Distributing $TOTAL_DESIRED_NODES $ROLE_NAME nodes across $NUM_UPI_AZS AZs for parallel deployment..."
      NODE_DISTRIBUTION_PER_AZ=($(distribute_nodes "$TOTAL_DESIRED_NODES" "$NUM_UPI_AZS"))

      for az_idx in $(seq 0 $(($NUM_UPI_AZS - 1)) ); do
        DESIRED_COUNT_FOR_THIS_AZ=${NODE_DISTRIBUTION_PER_AZ[$az_idx]:-0}
        if [[ "$DESIRED_COUNT_FOR_THIS_AZ" -eq 0 ]]; then continue; fi

        CURRENT_SUBNET_ID=${PRIVATE_SUBNET_IDS_ARRAY[$az_idx]}
        AZ_NAME_SUFFIX=$(aws ec2 describe-subnets --subnet-ids "$CURRENT_SUBNET_ID" --query "Subnets[0].AvailabilityZone" --output text | sed 's/.*-//')
        NODE_GROUP_STACK_NAME="${CFN_STACK_PREFIX}-nodegroup-${ROLE_NAME}-${AZ_NAME_SUFFIX}"
        NODE_GROUP_PARAMETERS_FILE="${CFN_GENERATED_PARAMS_DIR}/nodegroup-${ROLE_NAME}-${AZ_NAME_SUFFIX}-params.json"
        safe_cert_auth_data_ng="${CERTIFICATE_AUTHORITIES_DATA:-" "}"

        jq_args_ng=(
            -n
            --arg infra_name "$INFRASTRUCTURE_NAME"
            --arg node_group_name "$ROLE_NAME"
            --arg az_suffix_val "$AZ_NAME_SUFFIX"
            --arg rhcos_ami "$RHCOS_AMI_ID"
            --arg subnet_id "$CURRENT_SUBNET_ID"
            --arg node_sgid "$WORKER_SECURITY_GROUP_ID"
            --arg ign_loc "https://api-int.${CLUSTER_FQDN_BASE}:22623/config/worker"
            --arg cert_auth "$safe_cert_auth_data_ng"
            --arg node_profile_name "$WORKER_INSTANCE_PROFILE_NAME_PARAM_VAL"
            --arg instance_type "$INSTANCE_TYPE"
            --arg desired_count "$DESIRED_COUNT_FOR_THIS_AZ"
        )
        json_template_ng='
        [
          {"ParameterKey":"InfrastructureName",    "ParameterValue":$infra_name},
          {"ParameterKey":"NodeGroupName",         "ParameterValue":$node_group_name},
          {"ParameterKey":"AZSuffix",              "ParameterValue":$az_suffix_val},
          {"ParameterKey":"RhcosAmi",              "ParameterValue":$rhcos_ami},
          {"ParameterKey":"Subnet",                "ParameterValue":$subnet_id},
          {"ParameterKey":"NodeSecurityGroupId",   "ParameterValue":$node_sgid},
          {"ParameterKey":"IgnitionLocation",      "ParameterValue":$ign_loc},
          {"ParameterKey":"CertificateAuthorities","ParameterValue":$cert_auth},
          {"ParameterKey":"NodeInstanceProfileName","ParameterValue":$node_profile_name},
          {"ParameterKey":"InstanceType",          "ParameterValue":$instance_type},
          {"ParameterKey":"DesiredNodeCount",      "ParameterValue":$desired_count}
        ]
        '
        jq "${jq_args_ng[@]}" "$json_template_ng" > "$NODE_GROUP_PARAMETERS_FILE"
        if [ ! -f "$NODEGROUP_TEMPLATE_FILE" ]; then echo "ERROR: Node Group template missing for $ROLE_NAME."; exit 250; fi

        echo "Starting Node Group stack ($NODE_GROUP_STACK_NAME) deployment in background..."
        create_stack_and_wait "$NODE_GROUP_STACK_NAME" "$NODEGROUP_TEMPLATE_FILE" "$NODE_GROUP_PARAMETERS_FILE" "Key=ClusterName,Value=$CLUSTER_NAME Key=InstallType,Value=UPI Key=Role,Value=$ROLE_NAME Key=NodeGroup,Value=$ROLE_NAME Key=AZSuffix,Value=$AZ_NAME_SUFFIX" &
        STACK_PIDS+=($!)
        echo "Node Group stack ($NODE_GROUP_STACK_NAME) deployment initiated in background (PID: ${STACK_PIDS[${#STACK_PIDS[@]}-1]})."
      done
    else
      echo "Total desired $ROLE_NAME nodes is 0 or no AZs available. Skipping $ROLE_NAME node group for parallel deployment."
    fi
  done

  echo "Waiting for all parallel stack deployments (Bootstrap, Masters, Nodegroups) to complete..."
  PARALLEL_FAILURES=0
  for pid in "${STACK_PIDS[@]}"; do
    if wait "$pid"; then
      echo "Background stack deployment (PID: $pid) completed successfully."
    else
      echo "ERROR: Background stack deployment (PID: $pid) failed."
      PARALLEL_FAILURES=$((PARALLEL_FAILURES + 1))
    fi
  done

  if [ "$PARALLEL_FAILURES" -gt 0 ]; then
    echo "ERROR: $PARALLEL_FAILURES parallel stack deployment(s) failed. Check logs above. Aborting."
    exit 30
  fi
  echo "All parallel stack deployments (Bootstrap, Masters, Nodegroups) completed."

  KUBECONFIG_PATH="$HOME/$INSTALL_DIRNAME/auth/kubeconfig"
  echo "Exporting KUBECONFIG to $KUBECONFIG_PATH..."
  export KUBECONFIG="$KUBECONFIG_PATH"
  echo "export KUBECONFIG=$KUBECONFIG_PATH" >> "$HOME/.bashrc"

  echo "Waiting for cluster bootstrap to complete..."
  "$OCP_INSTALL_PATH" wait-for bootstrap-complete --dir "$INSTALL_DIRNAME" --log-level=info
  
  EXPECTED_NODES_TOTAL=$((UPI_MASTER_COUNT + AWS_WORKERS_COUNT + AWS_INFRA_NODES_COUNT + AWS_STORAGE_NODES_COUNT))
  echo "Expecting $EXPECTED_NODES_TOTAL nodes."
  CSR_COUNT=0
  MAX_CSR_CHECKS=120 
  CSR_CHECK_INTERVAL=30 
  echo "Approving pending CSRs..."
  while true; do
    if [ ! -f "$KUBECONFIG_PATH" ]; then
        echo "WARN: Kubeconfig not found."
        sleep "$CSR_CHECK_INTERVAL"; MAX_CSR_CHECKS=$((MAX_CSR_CHECKS - 1))
        if [ "$MAX_CSR_CHECKS" -le 0 ]; then echo "ERROR: Kubeconfig unavailable."; exit 271; fi
        continue
    fi
    export KUBECONFIG="$KUBECONFIG_PATH"
    PENDING_CSRS=$(oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null)
    OC_GET_CSR_EXIT_CODE=$?
    NODES_READY_COUNT=$(oc get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {print $1}' | wc -l)
    OC_GET_NODES_EXIT_CODE=$?

    if [ $OC_GET_CSR_EXIT_CODE -ne 0 ]; then echo "WARN: 'oc get csr' failed."; NODES_READY_COUNT=0; fi
    if [ $OC_GET_NODES_EXIT_CODE -ne 0 ]; then echo "WARN: 'oc get nodes' failed."; NODES_READY_COUNT=0; fi

    if [ -z "$PENDING_CSRS" ] && [ $OC_GET_CSR_EXIT_CODE -eq 0 ]; then
      echo "No pending CSRs."
      if [ "$NODES_READY_COUNT" -ge "$EXPECTED_NODES_TOTAL" ]; then echo "All $EXPECTED_NODES_TOTAL nodes Ready. Breaking."; break;
      else echo "$NODES_READY_COUNT/$EXPECTED_NODES_TOTAL nodes Ready. Waiting..."; fi
    elif [ $OC_GET_CSR_EXIT_CODE -eq 0 ]; then
      echo "Pending CSRs:" && echo "$PENDING_CSRS" && echo "$PENDING_CSRS" | xargs -r oc adm certificate approve && echo "Approved." && CSR_COUNT=$((CSR_COUNT + 1))
    fi
    echo "$NODES_READY_COUNT/$EXPECTED_NODES_TOTAL Ready. $MAX_CSR_CHECKS checks left."
    MAX_CSR_CHECKS=$((MAX_CSR_CHECKS - 1))
    if [ "$MAX_CSR_CHECKS" -le 0 ]; then echo "WARN: Max CSR checks. Proceeding."; break; fi
    sleep "$CSR_CHECK_INTERVAL"
  done

  echo "Deleting bootstrap node CloudFormation stack: $BOOTSTRAP_STACK_NAME ..."
  if aws cloudformation delete-stack --stack-name "$BOOTSTRAP_STACK_NAME"; then
    aws cloudformation wait stack-delete-complete --stack-name "$BOOTSTRAP_STACK_NAME"
    echo "Bootstrap stack $BOOTSTRAP_STACK_NAME deleted."
  else
    echo "WARN: Failed to delete bootstrap stack $BOOTSTRAP_STACK_NAME."
  fi

  echo "Finalizing installation with '$OCP_INSTALL_PATH wait-for install-complete'..."
  "$OCP_INSTALL_PATH" wait-for install-complete --dir "$INSTALL_DIRNAME" --log-level=info
  echo "OpenShift UPI Cluster installation successfully completed."

  # Configure UPI Node Roles and Taints
  if ! configure_upi_node_roles_and_taints; then
    echo "ERROR: UPI Node Role and Taint Configuration failed. This might impact Day2 operations."
    exit 28
  fi

else
  echo "ERROR: Unknown INSTALL_TYPE: '$INSTALL_TYPE'."
  exit 29
fi

if [[ "$ENABLE_DAY2_GITOPS_CONFIG" == "true" ]]; then
  if [ -f "$HOME/$INSTALL_DIRNAME/auth/kubeconfig" ]; then
    export KUBECONFIG="$HOME/$INSTALL_DIRNAME/auth/kubeconfig"
    if ! configure_oauth_secret; then
        echo "ERROR: Failed to configure OAuth secret."
        exit 1
    fi
    if ! configure_day2_gitops; then
        echo "ERROR: Day2 GitOps Configuration failed."
    fi
  else
    echo "WARN: Kubeconfig not found. Skipping Day2 GitOps configuration."
  fi
else
  echo "Day2 GitOps Configuration is disabled."
fi

SUMMARY_FILE="$HOME/cluster_summary.txt"

{
  echo ""
  echo "========================================================================"
  echo "                   CLUSTER INSTALLATION SUMMARY                         "
  echo "========================================================================"
  echo "Cluster Name: $CLUSTER_NAME"
  echo "Date: $(date)"
  echo ""

  if [ -f "$HOME/$INSTALL_DIRNAME/auth/kubeconfig" ]; then
    export KUBECONFIG="$HOME/$INSTALL_DIRNAME/auth/kubeconfig"
    
    API_URL=$(oc whoami --show-server 2>/dev/null || echo "Unknown")
    CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "Unknown")

    echo "API URL:     $API_URL"
    echo "Console URL: $CONSOLE_URL"
    echo ""
    echo "------------------------------------------------------------------------"
    echo "🔑  CREDENTIALS"
    echo "------------------------------------------------------------------------"

    # Check for kubeadmin password (standard IPI/UPI artifact)
    if [ -f "$HOME/$INSTALL_DIRNAME/auth/kubeadmin-password" ]; then
      KUBEADMIN_PASS=$(cat "$HOME/$INSTALL_DIRNAME/auth/kubeadmin-password")
      echo "User:     kubeadmin"
      echo "Password: $KUBEADMIN_PASS"
      echo ""
      echo "NOTE: If Day 2 GitOps ran successfully, this user might have been removed."
    else
      echo "User 'kubeadmin': Password file not found (or removed)."
    fi

    # Display OAuth info if Day 2 Config was enabled
    if [[ "$ENABLE_DAY2_GITOPS_CONFIG" == "true" ]]; then
        echo ""
        echo "User:     admin (OAuth htpasswd)"
        echo "Password: (Hidden - See OCP_ADMIN_PASSWORD in your config file)"
    fi

  else
    echo "❌ ERROR: Kubeconfig not found. Installation likely failed."
  fi
  echo "========================================================================"
} | tee "$SUMMARY_FILE"

echo ""
echo "Summary saved to: $SUMMARY_FILE"
echo "Bastion script finished."