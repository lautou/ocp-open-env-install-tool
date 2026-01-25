#!/bin/bash
set -e

cd $(dirname $0)

# --- HELPER: USAGE ---
show_usage() {
  echo "Usage: $(basename $0) [OPTIONS] [PROFILE_CONFIG]"
  echo ""
  echo "Description:"
  echo "  Initializes an OpenShift installation environment via an AWS Bastion host."
  echo "  Supports resuming sessions, multi-profile configurations, and parallel executions."
  echo ""
  echo "Options:"
  echo "  -h, --help         Show this help message and exit"
  echo "  --profile-file     Specify a configuration profile file (looks in current dir or 'profiles/')"
  echo ""
  echo "Examples:"
  echo "  ./$(basename $0)                                          # Run with default 'ocp_rhdp.config'"
  echo "  ./$(basename $0) --profile-file profiles/odf-full-aws.config  # Run with specific profile"
  echo "  ./$(basename $0) profiles/odf-full-aws.config                 # Legacy style support"
  exit 0
}

# --- 1. ARGUMENT PARSING ---
# Check for help immediately
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  show_usage
fi

PROFILE_ARG=""
if [[ "$1" == "--profile-file" && -n "$2" ]]; then
    PROFILE_ARG="$2"
elif [[ -n "$1" && "$1" != -* ]]; then
    # Legacy support: ./init.sh myprofile.config
    PROFILE_ARG="$1"
fi

# Define Target Config
if [[ -z "$PROFILE_ARG" ]]; then
    # Default behavior: look for ocp_rhdp.config
    TARGET_CONFIG="ocp_rhdp.config"
else
    # Smart search for the profile
    if [[ -f "$PROFILE_ARG" ]]; then
        TARGET_CONFIG="$PROFILE_ARG"
    elif [[ -f "profiles/$PROFILE_ARG" ]]; then
        TARGET_CONFIG="profiles/$PROFILE_ARG"
    else
        echo "❌ ERROR: Profile configuration file not found."
        echo "   Checked: $PROFILE_ARG"
        echo "   Checked: profiles/$PROFILE_ARG"
        echo "   Use -h for help."
        exit 1
    fi
fi

# Extract Profile Name for Session Isolation (e.g. 'only-odf-full-aws')
PROFILE_NAME=$(basename "$TARGET_CONFIG" .config)
echo "✅ Selected Profile: $PROFILE_NAME (File: $TARGET_CONFIG)"

# --- 2. DYNAMIC SESSION & FILE PATHS ---
UPLOAD_TO_BASTION_DIR="_upload_to_bastion_${PROFILE_NAME}"
BASTION_KEY_PEM_FILE="bastion_${PROFILE_NAME}.pem" 
SESSION_STATE_FILE=".bastion_session_${PROFILE_NAME}.info"

generate_user_data() {
  cat <<EOF | base64 -w 0
#!/bin/bash
set -x
exec > >(tee /var/log/cloud-init-output.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "--- STARTING BASTION PROVISIONING (USER DATA) ---"

# 1. System Updates & Base Tools
echo "Installing base packages..."
dnf install -y wget jq unzip httpd-tools tmux tar gzip

# 2. Install YQ
echo "Installing yq..."
wget -q https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# 3. Install AWS CLI v2
echo "Installing AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# 4. Install OpenShift Tools
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

# 5. Finalize
echo "--- BASTION PROVISIONING COMPLETE ---"
# Create a marker file for the local script to detect completion
touch /var/lib/cloud/instance/boot-finished-custom
EOF
}

retrieve_logs_and_summary() {
  local bastion_host="$1"
  local key_file="$2"
  
  # Determine local filenames based on the profile to prevent overwriting
  local local_summary_file="cluster_summary_${PROFILE_NAME}.txt"
  local local_log_file="bastion_execution_${PROFILE_NAME}.log"

  echo ""
  echo "📥 Retrieving logs and summary from bastion..."

  # 1. Retrieve Execution Log (Debug info)
  if scp -o "StrictHostKeyChecking=no" -q -i "$key_file" "ec2-user@$bastion_host:bastion_execution.log" "$local_log_file"; then
    echo "📄 Execution log saved to: $(pwd)/$local_log_file"
  else
    echo "⚠️  Could not retrieve 'bastion_execution.log'."
  fi

  # 2. Retrieve Summary (Credentials/URLs)
  if scp -o "StrictHostKeyChecking=no" -q -i "$key_file" "ec2-user@$bastion_host:cluster_summary.txt" "$local_summary_file"; then
    echo ""
    cat "$local_summary_file"
    echo ""
    echo "✅ Summary saved to: $(pwd)/$local_summary_file"
  else
    echo "⚠️  Could not retrieve 'cluster_summary.txt'."
  fi
}

# --- 3. ROBUST SESSION MANAGEMENT ---
if [[ -f "$SESSION_STATE_FILE" ]]; then
  source "$SESSION_STATE_FILE"
  
  SESSION_ALIVE=false
  # 1. Check if session is really alive on bastion
  if [[ -n "$BASTION_HOST" ]]; then
      if ssh -q -o "StrictHostKeyChecking=no" -o "ConnectTimeout=5" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$BASTION_HOST" "tmux has-session -t ocp_install 2>/dev/null"; then
          SESSION_ALIVE=true
      fi
  fi

  if [[ "$SESSION_ALIVE" == "true" ]]; then
    # CAS 1: Session is active -> Prompt to Resume
    echo ""
    echo "⚠️  WARNING: AN INTERRUPTED SESSION WAS DETECTED FOR PROFILE: $PROFILE_NAME"
    echo "   Bastion Host: $BASTION_HOST"
    echo ""
    echo -n "❓ Do you want to RESUME the existing connection? (Default: Yes) [Y/n]: "
    read -r response
    response=${response:-Y}

    if [[ "$response" =~ ^[Yy]$ ]]; then
      echo "🔄 Resuming session on $BASTION_HOST..."
      ssh -t -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$BASTION_HOST" \
        "tmux attach-session -t ocp_install"

      # Returned from tmux (Detach or Exit)
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
    # CAS 2: Local file exists, but tmux session is DEAD.
    # We check if it finished successfully in the background.
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
COMMON_CONFIG="common.config"
MERGED_CONFIG_FILE="$UPLOAD_TO_BASTION_DIR/ocp_rhdp.config"

echo "# MERGED CONFIGURATION FOR BASTION" > "$MERGED_CONFIG_FILE"

# A. Load Common (if exists)
if [[ -f "$COMMON_CONFIG" ]]; then
    echo "   Loading common configuration..."
    source "$COMMON_CONFIG"
    cat "$COMMON_CONFIG" >> "$MERGED_CONFIG_FILE"
    echo "" >> "$MERGED_CONFIG_FILE" # Newline safety
fi

# B. Load Profile (Overrides common)
echo "   Loading profile configuration..."
# Check if file exists (handled at step 1, but good practice)
if [[ ! -f "$TARGET_CONFIG" ]]; then
  echo "ERROR: Configuration file $TARGET_CONFIG not found."
  exit 1
fi
source "$TARGET_CONFIG"
cat "$TARGET_CONFIG" >> "$MERGED_CONFIG_FILE"

# At this point:
# 1. Variables are sourced locally (so checks below work)
# 2. Variables are written to MERGED_CONFIG_FILE (so Bastion gets them)

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
  echo "Invalid INSTALL_TYPE in ocp_rhdp.config. Must be \"IPI\" or \"UPI\"."
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

echo
echo "------------------------------------"
echo "Configuration variables (Merged Profile: $PROFILE_NAME)"
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

. aws_lib.sh

echo "Check base domain hosted zone exists..."
if [[ -z "$(get_r53_hz_id_by_name "${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}")" ]]; then
  echo "Base domain hosted zone does not exist in Route53: ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}."
  exit 18
fi


echo "Check and clean the AWS tenant..."
./clean_aws_tenant.sh "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_DEFAULT_REGION" "$CLUSTER_NAME" "$RHDP_TOP_LEVEL_ROUTE53_DOMAIN"

# Note: Using single quotes for Tags in AWS CLI command to ensure variable expansion works inside double quotes
BASTION_VPC_TAG_NAME="${CLUSTER_NAME}-bastion-vpc${RHDP_TOP_LEVEL_ROUTE53_DOMAIN}"
BASTION_SUBNET_TAG_NAME="${CLUSTER_NAME}-bastion-subnet"
BASTION_SG_TAG_NAME="${CLUSTER_NAME}-bastion-sg"
BASTION_IGW_TAG_NAME="${CLUSTER_NAME}-bastion-igw"
BASTION_RT_TAG_NAME="${CLUSTER_NAME}-bastion-rt"
BASTION_KEY_PAIR_NAME="${CLUSTER_NAME}-bastion-key"
BASTION_INSTANCE_TAG_NAME="${CLUSTER_NAME}-bastion"

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

echo "Generating UserData for Bastion Provisioning..."
USER_DATA_BASE64=$(generate_user_data)

echo "Launching Bastion Instance with UserData..."
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

echo "Bastion INSTANCE_ID=$INSTANCE_ID"
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

# Loop until the marker file created by UserData exists
# We use StrictHostKeyChecking=no to avoid issues as the instance just came up
set +e
while true; do
    # 1. Check if finished
    ssh -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$PUBLIC_DNS_NAME" \
        "test -f /var/lib/cloud/instance/boot-finished-custom" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Bastion Software Installation Complete."
        break
    fi

    # 2. Tail the last 5 lines of the log to show progress
    ssh -o "ConnectTimeout=5" -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$PUBLIC_DNS_NAME" \
        "tail -n 2 /var/log/cloud-init-output.log" 2>/dev/null
    
    sleep 5
done
set -e

BASTION_END_TIME=$(date +%s)
BASTION_DURATION=$((BASTION_END_TIME - BASTION_START_TIME))
echo "⏱️  Bastion Ready Time: $((BASTION_DURATION / 60)) min $((BASTION_DURATION % 60)) sec"

echo "Prepare files..."
mkdir -p "$UPLOAD_TO_BASTION_DIR/argocd/common"
if [ "$INSTALL_TYPE" == "UPI" ]; then
  cp -r "$CLOUDFORMATION_TEMPLATES_DIR" "$UPLOAD_TO_BASTION_DIR/"
fi
cp argocd/common/cluster-versions.yaml "$UPLOAD_TO_BASTION_DIR/argocd/common/"
# Note: we do NOT copy ocp_rhdp.config here because we already generated a merged version 
# inside $UPLOAD_TO_BASTION_DIR at step 4.
cp -r day1_config day2_config bastion_script.sh aws_lib.sh pull-secret.txt "$UPLOAD_TO_BASTION_DIR"

echo "Transferring files..."
scp -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" -r "$UPLOAD_TO_BASTION_DIR/." "ec2-user@$PUBLIC_DNS_NAME:/home/ec2-user"

echo "Running ocp installation script..."
echo "BASTION_HOST=$PUBLIC_DNS_NAME" > "$SESSION_STATE_FILE"

echo ""
echo "========================================================================"
echo "🚀  LAUNCHING INSTALLATION SESSION"
echo "========================================================================"
sleep 2

set +e
ssh -t -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$PUBLIC_DNS_NAME" \
  "echo 'set -g mouse on' > ~/.tmux.conf; tmux new-session -A -s ocp_install './bastion_script.sh || (echo \"\" && echo \"❌ SCRIPT FAILED. Press ENTER to close session...\" && read)'"
SSH_EXIT_CODE=$?
set -e

if [ $SSH_EXIT_CODE -eq 0 ]; then
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
  echo "⚠️  SSH terminated unexpectedly (Code: $SSH_EXIT_CODE)."
  exit $SSH_EXIT_CODE
fi