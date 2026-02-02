#!/bin/bash
set -e

cd $(dirname $0)

# --- HELPER: USAGE ---
show_usage() {
  echo "Usage: $(basename $0) [OPTIONS] [CONFIG_FILE]"
  echo ""
  echo "Description:"
  echo "  Initializes an OpenShift installation environment via an AWS Bastion host."
  echo "  Supports resuming sessions, multi-configuration, and parallel executions."
  echo ""
  echo "Options:"
  echo "  -h, --help         Show this help message and exit"
  echo "  --config-file      Specify a configuration file (looks in 'config/' directory)"
  echo ""
  echo "Examples:"
  echo "  $(basename $0)                                   # Uses config/ocp-standard.config"
  echo "  $(basename $0) --config-file odf-perf.config     # Uses config/odf-perf.config"
  exit 0
}

# --- 1. ARGUMENT PARSING ---
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_usage
fi

CONFIG_ARG=""
if [[ "$1" == "--config-file" && -n "$2" ]]; then
    CONFIG_ARG="$2"
elif [[ -n "$1" && "$1" != -* ]]; then
    CONFIG_ARG="$1"
fi

# Define the Configuration Directory
CONFIG_DIR="config"

if [[ -z "$CONFIG_ARG" ]]; then
    TARGET_CONFIG="$CONFIG_DIR/ocp-standard.config"
else
    # Check if file exists as provided (absolute path)
    if [[ -f "$CONFIG_ARG" ]]; then
        TARGET_CONFIG="$CONFIG_ARG"
    # Check if file exists in the config directory
    elif [[ -f "$CONFIG_DIR/$CONFIG_ARG" ]]; then
        TARGET_CONFIG="$CONFIG_DIR/$CONFIG_ARG"
    else
        echo "❌ ERROR: Configuration file not found: $CONFIG_ARG"
        echo "   Checked paths:"
        echo "   - $(pwd)/$CONFIG_ARG"
        echo "   - $(pwd)/$CONFIG_DIR/$CONFIG_ARG"
        exit 1
    fi
fi

CONFIG_NAME=$(basename "$TARGET_CONFIG" .config)
echo "✅ Selected Configuration: $CONFIG_NAME (File: $TARGET_CONFIG)"

# --- 2. DYNAMIC SESSION & FILE PATHS ---

mkdir -p output

UPLOAD_TO_BASTION_DIR="output/_upload_to_bastion_${CONFIG_NAME}"
BASTION_KEY_PEM_FILE="output/bastion_${CONFIG_NAME}.pem" 
SESSION_STATE_FILE="output/.bastion_session_${CONFIG_NAME}.info"
PROVISIONING_STATE_FILE="output/.bastion_provisioning_${CONFIG_NAME}.info"

generate_user_data() {
  cat <<EOF | base64 -w 0
#!/bin/bash
set -x
exec > >(tee /var/log/cloud-init-output.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "--- STARTING BASTION PROVISIONING (USER DATA) ---"
echo "Installing base packages..."
dnf install -y wget jq unzip httpd-tools tmux tar gzip

echo "Installing yq..."
wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq

echo "Installing AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

OCP_VERSION="$OPENSHIFT_VERSION"
BASE_URL="$OCP_DOWNLOAD_BASE_URL"

echo "Downloading OpenShift Clients (Version: \$OCP_VERSION)..."
wget -nv -O "openshift-client.tar.gz" "\$BASE_URL/\$OCP_VERSION/openshift-client-linux-\$OCP_VERSION.tar.gz"
tar -xf "openshift-client.tar.gz" -C /usr/local/bin oc kubectl
rm -f openshift-client.tar.gz

echo "Downloading OpenShift Installer..."
wget -nv -O "openshift-install.tar.gz" "\$BASE_URL/\$OCP_VERSION/openshift-install-linux-\$OCP_VERSION.tar.gz"
tar -xf "openshift-install.tar.gz" -C /usr/local/bin openshift-install
rm -f openshift-install.tar.gz

echo "--- BASTION PROVISIONING COMPLETE ---"
touch /var/lib/cloud/instance/boot-finished-custom
EOF
}

retrieve_logs_and_summary() {
  local bastion_host="$1"
  local key_file="$2"
  local local_summary_file="output/cluster_summary_${CONFIG_NAME}.txt"
  local local_log_file="output/bastion_execution_${CONFIG_NAME}.log"

  echo ""
  echo "📥 Retrieving logs and summary from bastion..."

  if scp -o "StrictHostKeyChecking=no" -q -i "$key_file" "ec2-user@$bastion_host:bastion_execution.log" "$local_log_file"; then
    echo "📄 Execution log saved to: $(pwd)/$local_log_file"
  else
    echo "⚠️  Could not retrieve 'bastion_execution.log'."
  fi

  if scp -o "StrictHostKeyChecking=no" -q -i "$key_file" "ec2-user@$bastion_host:cluster_summary.txt" "$local_summary_file"; then
    echo ""
    cat "$local_summary_file"
    echo ""
    echo "✅ Summary saved to: $(pwd)/$local_summary_file"
  else
    echo "⚠️  Could not retrieve 'cluster_summary.txt'."
  fi
}

# --- 3. ROBUST SESSION MANAGEMENT (INSTALLATION PHASE) ---
if [[ -f "$SESSION_STATE_FILE" ]]; then
  source "$SESSION_STATE_FILE"
  
  SESSION_ALIVE=false
  if [[ -n "$BASTION_HOST" ]]; then
      if ssh -q -o "StrictHostKeyChecking=no" -o "ConnectTimeout=5" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$BASTION_HOST" "tmux has-session -t ocp_install 2>/dev/null"; then
          SESSION_ALIVE=true
      fi
  fi

  if [[ "$SESSION_ALIVE" == "true" ]]; then
    echo ""
    echo "⚠️  WARNING: AN INTERRUPTED SESSION WAS DETECTED FOR CONFIG: $CONFIG_NAME"
    echo "   Bastion Host: $BASTION_HOST"
    echo ""
    echo -n "❓ Do you want to RESUME the existing connection? (Default: Yes) [Y/n]: "
    read -r response
    response=${response:-Y}

    if [[ "$response" =~ ^[Yy]$ ]]; then
      echo "🔄 Resuming session on $BASTION_HOST..."
      ssh -t -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$BASTION_HOST" \
        "tmux attach-session -t ocp_install"

      if ssh -q -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$BASTION_HOST" "tmux has-session -t ocp_install 2>/dev/null"; then
          echo "⏸️  Session detached. State file kept."
          exit 0
      else
          echo "✅ Session completed cleanly."
          retrieve_logs_and_summary "$BASTION_HOST" "$BASTION_KEY_PEM_FILE"
          rm -f "$SESSION_STATE_FILE"
          exit 0
      fi
    else
      echo "🗑️  Abandoning previous session. Proceeding with a fresh installation..."
      rm -f "$SESSION_STATE_FILE"
    fi

  else
    echo "ℹ️  Session 'ocp_install' not found on bastion. Checking for success artifacts..."
    
    if ssh -q -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$BASTION_HOST" "test -f cluster_summary.txt"; then
        echo "✅ SUCCESS: Installation finished successfully while you were away!"
        retrieve_logs_and_summary "$BASTION_HOST" "$BASTION_KEY_PEM_FILE"
        echo "🧹 Cleaning up stale session file (Next run will be a fresh install)."
        rm -f "$SESSION_STATE_FILE"
        exit 0
    else
        echo "⚠️  No success artifacts found. Assuming the previous installation crashed."
        echo "🗑️  Cleaning up state file and restarting..."
        rm -f "$SESSION_STATE_FILE"
    fi
  fi
fi

echo "Clean temporary directories..."
rm -rf "$UPLOAD_TO_BASTION_DIR"
mkdir -p "$UPLOAD_TO_BASTION_DIR"

# --- 4. CONFIGURATION LOADING & FLATTENING ---
COMMON_CONFIG="$CONFIG_DIR/common.config"
MERGED_CONFIG_FILE="$UPLOAD_TO_BASTION_DIR/ocp_rhdp.config"
echo "# MERGED CONFIGURATION FOR BASTION" > "$MERGED_CONFIG_FILE"

if [[ -f "$COMMON_CONFIG" ]]; then
    echo "   Loading common configuration ($COMMON_CONFIG)..."
    source "$COMMON_CONFIG"
    cat "$COMMON_CONFIG" >> "$MERGED_CONFIG_FILE"
    echo "" >> "$MERGED_CONFIG_FILE"
fi

echo "   Loading target configuration ($TARGET_CONFIG)..."
if [[ ! -f "$TARGET_CONFIG" ]]; then
  echo "ERROR: Configuration file $TARGET_CONFIG not found."
  exit 1
fi
source "$TARGET_CONFIG"
cat "$TARGET_CONFIG" >> "$MERGED_CONFIG_FILE"

echo
echo "------------------------------------"
echo "Configuration variables (Merged Config: $CONFIG_NAME)"
echo "------------------------------------"
echo "INSTALL_TYPE=$INSTALL_TYPE"
echo "OPENSHIFT_VERSION=$OPENSHIFT_VERSION"
echo "RHDP_TOP_LEVEL_ROUTE53_DOMAIN=$RHDP_TOP_LEVEL_ROUTE53_DOMAIN"
echo "CLUSTER_NAME=$CLUSTER_NAME"
echo "AWS_ACCESS_KEY_ID=****************"
echo "AWS_SECRET_ACCESS_KEY=****************"
echo "AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"
echo "AWS_INSTANCE_TYPE_CONTROLPLANE_NODES=$AWS_INSTANCE_TYPE_CONTROLPLANE_NODES"
echo "AWS_INSTANCE_TYPE_COMPUTE_NODES=$AWS_INSTANCE_TYPE_COMPUTE_NODES"
echo "AWS_INSTANCE_TYPE_INFRA_NODES=$AWS_INSTANCE_TYPE_INFRA_NODES"
echo "AWS_INSTANCE_TYPE_STORAGE_NODES=$AWS_INSTANCE_TYPE_STORAGE_NODES"
echo "GIT_CREDENTIALS_TEMPLATE_URL=$GIT_CREDENTIALS_TEMPLATE_URL"
echo "GIT_CREDENTIALS_TEMPLATE_TOKEN_NAME=****************"
echo "GIT_CREDENTIALS_TEMPLATE_TOKEN_SECRET=****************"
echo "GIT_REPO_URL=$GIT_REPO_URL"
echo "GIT_REPO_REVISION=${GIT_REPO_REVISION:-HEAD}"
echo "GIT_REPO_TOKEN_NAME=****************"
echo "GIT_REPO_TOKEN_SECRET=****************"
echo "OCP_DOWNLOAD_BASE_URL=$OCP_DOWNLOAD_BASE_URL"
echo "------------------------------------"

echo "Check if aws CLI is installed..."
if ! hash aws 2>/dev/null; then
  echo "aws CLI is not installed on your workstation! Ensure aws CLI is installed."
  exit 2
fi

echo "Check if podman is installed..."
if ! hash podman 2>/dev/null; then
  echo "podman is needed to check Red Hat credentials! Ensure podman is installed."
  exit 3
fi

echo "Check if git is installed..."
if ! hash git 2>/dev/null; then
  echo "git is required in order to check git connectivity to the git repository hosting GitOps resources! Ensure git is installed."
  exit 4
fi

echo "Check if yq is installed..."
if ! hash yq 2>/dev/null; then
  echo "yq is required in order to inject proper yaml configuration files! Ensure yq is installed."
  exit 5
fi

echo "Check if pull-secret.txt file is present..."
if [[ ! -f pull-secret.txt ]]; then
  echo "Cannot find pull-secret.txt file on $(dirname "$0")! Get this file from console.redhat.com using your Red Hat credentials and drop it into this directory."
  exit 6
fi

if [[ "$INSTALL_TYPE" != "IPI" && "$INSTALL_TYPE" != "UPI" ]]; then
  echo "Invalid INSTALL_TYPE in config. Must be \"IPI\" or \"UPI\"."
  exit 7
fi
if [ "$INSTALL_TYPE" == "UPI" ]; then
  CLOUDFORMATION_TEMPLATES_DIR="cloudformation_templates" 
  if [ ! -d "$CLOUDFORMATION_TEMPLATES_DIR" ]; then
    echo "INSTALL_TYPE is UPI, but CloudFormation templates directory '$CLOUDFORMATION_TEMPLATES_DIR' not found at $(pwd)/$CLOUDFORMATION_TEMPLATES_DIR."
    echo "Please create this directory and place your CloudFormation templates inside it."
    exit 8
  else
    echo "CloudFormation templates directory '$CLOUDFORMATION_TEMPLATES_DIR' found for UPI installation."
  fi
fi
echo "Check if a credential template URL is filled..."
if [[ "$ENABLE_DAY2_GITOPS_CONFIG" == "true" ]]; then
  if [[ "$GIT_CREDENTIALS_TEMPLATE_URL" ]]; then
    if [[ ! "$GIT_CREDENTIALS_TEMPLATE_URL" =~ ^https?://.+$ ]]; then
      echo "Git credential template URL: $GIT_CREDENTIALS_TEMPLATE_URL is invalid. Ensure it is correctly filled and only uses HTTP(S) method."
      exit 9
    elif [[ -z "$GIT_CREDENTIALS_TEMPLATE_TOKEN_NAME" ]]; then
      echo "No Git token name provided for credential template! Please provide a token name."
      exit 10
    elif [[ -z "$GIT_CREDENTIALS_TEMPLATE_TOKEN_SECRET" ]]; then
      echo "No Git token secret provided for credential template! Please provide a token secret."
      exit 11
    fi
  fi

  echo "Check if git repo URL is valid..."
  if [[ "$GIT_REPO_URL" =~ ^(https?)://(.+/.+\.git)$ ]]; then
    GIT_REPO_URL_SCHEME=${BASH_REMATCH[1]}
    GIT_REPO_URL_DOMAIN_PATH=${BASH_REMATCH[2]}
  else
    echo "Git base URL: $GIT_REPO_URL is invalid. Ensure it is filled, it only uses HTTP(S) method and '.git' extension is added at the end to the path."
    exit 12
  fi

  echo "Check if a repo token is required..."
  if [[ "$GIT_REPO_TOKEN_NAME" ]] && [[ -z "$GIT_REPO_TOKEN_SECRET" ]]; then
      echo "No Git token secret provided for the GitOps git repository! Please provide a token secret."
      exit 13
  fi

  echo "Check if we can connect to the repository..."
  if [[ -n "$GIT_REPO_TOKEN_NAME" ]]; then
    echo "We use the explicitely provided git repo token to check the connectivity"
    GIT_URL_TO_CHECK="$GIT_REPO_URL_SCHEME://$GIT_REPO_TOKEN_NAME:$GIT_REPO_TOKEN_SECRET@$GIT_REPO_URL_DOMAIN_PATH"
  elif [[ "$GIT_REPO_URL" =~ ^"$GIT_CREDENTIALS_TEMPLATE_URL" ]] && [[ -n "$GIT_CREDENTIALS_TEMPLATE_TOKEN_NAME" ]] && [[ -n "$GIT_CREDENTIALS_TEMPLATE_TOKEN_SECRET" ]]; then
    echo "The git repo URL matches the git credential URL, so we use the credential template token to check the connectivity..."
    GIT_URL_TO_CHECK="$GIT_REPO_URL_SCHEME://$GIT_CREDENTIALS_TEMPLATE_TOKEN_NAME:$GIT_CREDENTIALS_TEMPLATE_TOKEN_SECRET@$GIT_REPO_URL_DOMAIN_PATH"
  else
    echo "No specific credential provided for this repo URL, or template credentials incomplete. Trying anonymous connectivity..."
    GIT_URL_TO_CHECK="$GIT_REPO_URL"
  fi
  if ! git ls-remote -q "$GIT_URL_TO_CHECK" &>/dev/null; then
    echo "Unable to connect to the repo $GIT_REPO_URL. Check the credentials and/or the repository path."
    exit 14
  fi

else
  echo "Day 2 GitOps configuration is disabled. Skipping Git credentials and repository checks."
fi

echo "Check if Route53 base domain is valid..."
if [[ "${RHDP_TOP_LEVEL_ROUTE53_DOMAIN::1}" != "." ]]; then
  echo "The base domain $RHDP_TOP_LEVEL_ROUTE53_DOMAIN does not start with a period."
  exit 15
fi

echo "Check RH subscription credentials validity..."
REGISTRY_LIST=(registry.connect.redhat.com quay.io registry.redhat.io)
for registry in "${REGISTRY_LIST[@]}";
do
  if ! podman login --authfile=pull-secret.txt "$registry" < /dev/null; then
    echo "Failed to login to $registry using pull-secret.txt. Please check your pull secret."
    exit 16
  fi
done
echo "Pull secret validated for all required registries."

echo "Check Amazon credentials..."
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
if ! aws sts get-caller-identity > /dev/null; then
  echo "AWS credentials are not valid or region is not set correctly."
  exit 17
fi
echo "AWS credentials and region successfully validated."

. scripts/aws_lib.sh

echo "Check base domain hosted zone exists..."
if [[ -z "$(get_r53_hz_id_by_name "${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}")" ]]; then
  echo "Base domain hosted zone does not exist in Route53: ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}."
  exit 18
fi
# --- 5. BASTION PROVISIONING & RECOVERY ---

BASTION_VPC_TAG_NAME="${CLUSTER_NAME}-bastion-vpc${RHDP_TOP_LEVEL_ROUTE53_DOMAIN}"
BASTION_SUBNET_TAG_NAME="${CLUSTER_NAME}-bastion-subnet"
BASTION_SG_TAG_NAME="${CLUSTER_NAME}-bastion-sg"
BASTION_IGW_TAG_NAME="${CLUSTER_NAME}-bastion-igw"
BASTION_RT_TAG_NAME="${CLUSTER_NAME}-bastion-rt"
BASTION_KEY_PAIR_NAME="${CLUSTER_NAME}-bastion-key"
BASTION_INSTANCE_TAG_NAME="${CLUSTER_NAME}-bastion"

INSTANCE_ID=""
RECOVERED_PROVISIONING=false

if [[ -f "$PROVISIONING_STATE_FILE" ]]; then
    echo ""
    echo "⚠️  WARNING: DETECTED INCOMPLETE BASTION PROVISIONING."
    source "$PROVISIONING_STATE_FILE"
    echo "   Pending Instance ID: $BASTION_INSTANCE_ID"
    
    echo "   Verifying if instance is still alive in AWS..."
    INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$BASTION_INSTANCE_ID" --query "Reservations[].Instances[].State.Name" --output text 2>/dev/null || echo "terminated")
    
    if [[ "$INSTANCE_STATE" == "running" || "$INSTANCE_STATE" == "pending" ]]; then
        echo "✅ Instance found (State: $INSTANCE_STATE). Resuming wait..."
        INSTANCE_ID="$BASTION_INSTANCE_ID"
        RECOVERED_PROVISIONING=true
    else
        echo "❌ Instance not found or terminated (State: $INSTANCE_STATE). Cleaning up and starting fresh."
        rm -f "$PROVISIONING_STATE_FILE"
    fi
fi

if [[ "$RECOVERED_PROVISIONING" == "false" ]]; then
    echo "Check and clean the AWS tenant..."
    ./scripts/clean_aws_tenant.sh "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_DEFAULT_REGION" "$CLUSTER_NAME" "$RHDP_TOP_LEVEL_ROUTE53_DOMAIN"

    echo "------------------------------------"
    echo "Creating the Bastion VPC..."
    VPC_ID=$(aws ec2 create-vpc --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value='$BASTION_VPC_TAG_NAME'}]" --output text --query Vpc.VpcId --cidr-block 192.168.0.0/16)
echo "Enable DNS Hostnames..."
    aws ec2 modify-vpc-attribute --enable-dns-hostnames --vpc-id "$VPC_ID"
echo "Creating Subnet..."
    SUBNET_ID=$(aws ec2 create-subnet --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value='$BASTION_SUBNET_TAG_NAME'}]" --output text --query Subnet.SubnetId --cidr-block 192.168.0.0/24 --vpc-id="$VPC_ID")
echo "Creating Security Group..."
    SG_ID=$(aws ec2 create-security-group --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value='$BASTION_SG_TAG_NAME'}]" --output text --query GroupId --group-name "$BASTION_SG_TAG_NAME" --description "Bastion SG" --vpc-id "$VPC_ID")
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --cidr 0.0.0.0/0 --protocol tcp --port 22 > /dev/null

echo "Creating Internet Gateway..."
    IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value='$BASTION_IGW_TAG_NAME'}]" --output text --query InternetGateway.InternetGatewayId)
    aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
echo "Creating Route Table..."
    RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value='$BASTION_RT_TAG_NAME'}]" --output text --query RouteTable.RouteTableId)
    aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID" > /dev/null
    aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null

    echo "Creating EC2 Key Pair..."
    aws ec2 delete-key-pair --key-name "$BASTION_KEY_PAIR_NAME" > /dev/null 2>&1
    aws ec2 create-key-pair --key-name "$BASTION_KEY_PAIR_NAME" --query KeyMaterial --output text > "$BASTION_KEY_PEM_FILE" 2> /dev/null
    chmod 600 "$BASTION_KEY_PEM_FILE"

    echo "Determining AMI..."
    AWS_BASTION_AMI=$(aws ec2 describe-images \
      --owners 309956199498 \
      --filters \
"Name=name,Values=RHEL-9*x86_64*Hourly*" \
"Name=architecture,Values=x86_64" \
    "Name=virtualization-type,Values=hvm" \
    "Name=root-device-type,Values=ebs" \
    "Name=state,Values=available" \
      --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
--output text)

    echo "Generating UserData..."
    USER_DATA_BASE64=$(generate_user_data)

    echo "Launching Bastion Instance..."
    BASTION_START_TIME=$(date +%s)
    INSTANCE_ID=$(aws ec2 run-instances \
      --image-id "$AWS_BASTION_AMI" \
      --instance-type t2.large \
      --subnet-id "$SUBNET_ID" \
      --key-name "$BASTION_KEY_PAIR_NAME" \
      --security-group-ids "$SG_ID" \
      --associate-public-ip-address \
      --user-data "$USER_DATA_BASE64" \
      --query Instances[].InstanceId \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value='$BASTION_INSTANCE_TAG_NAME'}]" \
      --output text)

    echo "BASTION_INSTANCE_ID=$INSTANCE_ID" > "$PROVISIONING_STATE_FILE"
    echo "Bastion INSTANCE_ID=$INSTANCE_ID (State saved to $PROVISIONING_STATE_FILE)"
fi

echo -n "Waiting for running state..."
aws ec2 wait instance-running --filters Name=instance-id,Values="$INSTANCE_ID"
echo " Done."

PUBLIC_DNS_NAME=$(aws_ec2_get instance Reservations[].Instances[].PublicDnsName instance-id "$INSTANCE_ID")
echo "Bastion PUBLIC_DNS_NAME=$PUBLIC_DNS_NAME"
echo -n "Waiting for system status check..."
aws ec2 wait system-status-ok --instance-ids "$INSTANCE_ID"
echo " Done."

echo "--------------------------------------------------------"
echo "📡  Streaming Bastion UserData Logs (Software Installation)..."
echo "--------------------------------------------------------"

set +e
while true; do
    ssh -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$PUBLIC_DNS_NAME" \
        "test -f /var/lib/cloud/instance/boot-finished-custom" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Bastion Software Installation Complete."
        break
    fi
    ssh -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$PUBLIC_DNS_NAME" \
        "tail -n 2 /var/log/cloud-init-output.log" 2>/dev/null
    sleep 5
done
set -e

if [[ "$RECOVERED_PROVISIONING" == "false" ]]; then
    BASTION_END_TIME=$(date +%s)
    BASTION_DURATION=$((BASTION_END_TIME - BASTION_START_TIME))
    echo "⏱️  Bastion Ready Time: $((BASTION_DURATION / 60)) min $((BASTION_DURATION % 60)) sec"
fi

rm -f "$PROVISIONING_STATE_FILE"
echo "BASTION_HOST=$PUBLIC_DNS_NAME" > "$SESSION_STATE_FILE"

echo "Prepare files..."
mkdir -p "$UPLOAD_TO_BASTION_DIR/argocd/common"
if [ "$INSTALL_TYPE" == "UPI" ]; then
  cp -r "$CLOUDFORMATION_TEMPLATES_DIR" "$UPLOAD_TO_BASTION_DIR/"
fi
cp components/common/cluster-versions.yaml "$UPLOAD_TO_BASTION_DIR/argocd/common/"

cp scripts/bastion_script.sh "$UPLOAD_TO_BASTION_DIR"
cp scripts/aws_lib.sh "$UPLOAD_TO_BASTION_DIR"
cp -r day1_config day2_config pull-secret.txt "$UPLOAD_TO_BASTION_DIR"

mkdir -p "$UPLOAD_TO_BASTION_DIR/day2_config/gitops"
cp components/openshift-gitops-admin-config/base/openshift-gitops-argocd-openshift-gitops.yaml \
   "$UPLOAD_TO_BASTION_DIR/day2_config/gitops/custom-argocd.yaml"

echo "Transferring files..."
scp -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" -r "$UPLOAD_TO_BASTION_DIR/." "ec2-user@$PUBLIC_DNS_NAME:/home/ec2-user"

echo ""
echo "========================================================================"
echo "🚀  LAUNCHING INSTALLATION SESSION"
echo "========================================================================"
sleep 2

set +e
ssh -t -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$PUBLIC_DNS_NAME" \
  "echo 'set -g mouse on' > ~/.tmux.conf; tmux new-session -A -s ocp_install './bastion_script.sh || (echo \"\" && echo \"❌ SCRIPT FAILED. Press ENTER to close session...\" && read)'"
BASTION_STATUS=$?
set -e

if [ $BASTION_STATUS -eq 0 ]; then
  if ssh -q -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$PUBLIC_DNS_NAME" "tmux has-session -t ocp_install 2>/dev/null"; then
    echo ""
    echo "⏸️  Session detached. State file kept."
    exit 0
  else
    echo "✅ Session completed cleanly."
    retrieve_logs_and_summary "$PUBLIC_DNS_NAME" "$BASTION_KEY_PEM_FILE"
    rm -f "$SESSION_STATE_FILE"
  fi
else
  echo ""
  echo "⚠️  SSH terminated unexpectedly (Code: $BASTION_STATUS)."
  exit $BASTION_STATUS
fi