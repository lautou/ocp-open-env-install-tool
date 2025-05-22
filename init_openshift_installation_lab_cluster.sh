#!/bin/bash
set -e

UPLOAD_TO_BASTION_DIR="_upload_to_bastion"
BASTION_KEY_PEM_FILE="bastion.pem" 

cd $(dirname $0)

echo "Clean temporary directories..."
rm -rf "$UPLOAD_TO_BASTION_DIR"

echo "Check if aws CLI is installed..."
if ! hash aws 2>/dev/null; then
  echo "aws CLI is not installed on your workstation! Ensure aws CLI is installed."
  exit 1
fi

echo "Check if podman is installed..."
if ! hash podman 2>/dev/null; then
  echo "podman is needed to check Red Hat credentials! Ensure podman is installed."
  exit 2
fi

echo "Check if git is installed..."
if ! hash git 2>/dev/null; then
  echo "git is required in order to check git connectivity to the git repository hosting GitOps resources! Ensure git is installed."
  exit 3
fi

echo "Check if yq is installed..."
if ! hash yq 2>/dev/null; then
  echo "yq is required in order to inject proper yaml configuration files! Ensure yq is installed."
  exit 4
fi

echo "Check if pull-secret.txt file is present..."
if [[ ! -f pull-secret.txt ]]; then
  echo "Cannot find pull-secret.txt file on $(dirname "$0")! Get this file from console.redhat.com using your Red Hat credentials and drop it into this directory."
  exit 5
fi

echo "Check if ocp_rhdp.config is present..."
if [[ ! -f ocp_rhdp.config ]]; then
  echo "Cannot find ocp_rhdp.config file on $(dirname $0)"
  exit 6
fi
. ocp_rhdp.config 

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
echo "Configuration variables from ocp_rhdp.config"
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
echo "GIT_REPO_TOKEN_NAME=****************"
echo "GIT_REPO_TOKEN_SECRET=****************"
echo "OCP_DOWNLOAD_BASE_URL=$OCP_DOWNLOAD_BASE_URL"
echo "------------------------------------"

echo "Check if a credential template URL is filled..."
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

echo "Determining latest RHEL 9 AMI for bastion in region $AWS_DEFAULT_REGION..."
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
if [ -z "$AWS_BASTION_AMI" ] || [ "$AWS_BASTION_AMI" == "None" ]; then
  echo "ERROR: Could not automatically determine a suitable RHEL 9 for the bastion in region $AWS_DEFAULT_REGION."
  echo "Please check AWS filters or specify AWS_BASTION_AMI manually if this problem persists."
  exit 19
fi
echo "Using RHEL 9 AMI for bastion: $AWS_BASTION_AMI"

echo "Check and clean the AWS tenant..."
./clean_aws_tenant.sh "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$AWS_DEFAULT_REGION" "$CLUSTER_NAME" "$RHDP_TOP_LEVEL_ROUTE53_DOMAIN"

BASTION_VPC_TAG_NAME="${CLUSTER_NAME}-bastion-vpc${RHDP_TOP_LEVEL_ROUTE53_DOMAIN}"
BASTION_SUBNET_TAG_NAME="${CLUSTER_NAME}-bastion-subnet"
BASTION_SG_TAG_NAME="${CLUSTER_NAME}-bastion-sg"
BASTION_IGW_TAG_NAME="${CLUSTER_NAME}-bastion-igw"
BASTION_RT_TAG_NAME="${CLUSTER_NAME}-bastion-rt"
BASTION_KEY_PAIR_NAME="${CLUSTER_NAME}-bastion-key"
BASTION_INSTANCE_TAG_NAME="${CLUSTER_NAME}-bastion"

echo "------------------------------------"
echo "Creating the Bastion VPC..."
VPC_ID=$(aws ec2 create-vpc --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$BASTION_VPC_TAG_NAME}]" --output text --query Vpc.VpcId --cidr-block 192.168.0.0/16)
echo "Bastion VPC_ID=$VPC_ID"

echo "Enable DNS Hostnames in the Bastion VPC..."
aws ec2 modify-vpc-attribute --enable-dns-hostnames --vpc-id "$VPC_ID"

echo "Creating the subnet for Bastion VPC id $VPC_ID..."
SUBNET_ID=$(aws ec2 create-subnet --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$BASTION_SUBNET_TAG_NAME}]" --output text --query Subnet.SubnetId --cidr-block 192.168.0.0/24 --vpc-id="$VPC_ID")
echo "Bastion SUBNET_ID=$SUBNET_ID"

echo "Creating the security group for Bastion VPC id $VPC_ID..."
SG_ID=$(aws ec2 create-security-group --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=$BASTION_SG_TAG_NAME}]" --output text --query GroupId --group-name "$BASTION_SG_TAG_NAME" --description "Bastion Host security group for $CLUSTER_NAME" --vpc-id "$VPC_ID")
echo "Bastion SG_ID=$SG_ID"

echo "Creating the TCP port 22 ingress rule for security group id $SG_ID..." 
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --cidr 0.0.0.0/0 --protocol tcp --port 22 > /dev/null
echo "------------------------------------"
echo

echo "Creating an Internet Gateway for Bastion VPC..."
IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=$BASTION_IGW_TAG_NAME}]" --output text --query InternetGateway.InternetGatewayId)
echo "Bastion IGW_ID=$IGW_ID"

echo "Attaching Internet Gateway id $IGW_ID to Bastion vpc id $VPC_ID..."
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

echo "Creating a route table for Bastion vpc id $VPC_ID..."
RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=$BASTION_RT_TAG_NAME}]" --output text --query RouteTable.RouteTableId)
echo "Bastion RT_ID=$RT_ID"

echo "Associate route table id $RT_ID to subnet $SUBNET_ID..."
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_ID" > /dev/null

echo "Create route in table id $RT_ID for internet gateway $IGW_ID..."
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null

echo "Creating the EC2 key pair for the bastion: $BASTION_KEY_PAIR_NAME..."
aws ec2 delete-key-pair --key-name "$BASTION_KEY_PAIR_NAME" > /dev/null
aws ec2 create-key-pair --key-name "$BASTION_KEY_PAIR_NAME" --query KeyMaterial --output text > "$BASTION_KEY_PEM_FILE" 2> /dev/null
chmod 600 "$BASTION_KEY_PEM_FILE"

echo "Creating the bastion instance using AMI $AWS_BASTION_AMI..."
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AWS_BASTION_AMI" --instance-type t2.large --subnet-id "$SUBNET_ID" --key-name "$BASTION_KEY_PAIR_NAME" --security-group-ids "$SG_ID" --associate-public-ip-address --query Instances[].InstanceId --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$BASTION_INSTANCE_TAG_NAME}]" --output text)
echo "Bastion INSTANCE_ID=$INSTANCE_ID"
echo -n "Waiting the bastion instance state is running..."
aws ec2 wait instance-running --filters Name=instance-id,Values="$INSTANCE_ID"
echo " Done."

PUBLIC_DNS_NAME=$(aws_ec2_get instance Reservations[].Instances[].PublicDnsName instance-id "$INSTANCE_ID")
echo "Bastion PUBLIC_DNS_NAME=$PUBLIC_DNS_NAME"
echo -n "Waiting the system status for bastion instance is OK..."
aws ec2 wait system-status-ok --instance-ids "$INSTANCE_ID"
echo " Done."

echo "Prepare files to send to the bastion..."
mkdir -p "$UPLOAD_TO_BASTION_DIR"

echo "Copy required files to the bastion..."
if [ "$INSTALL_TYPE" == "UPI" ]; then
  cp -r "$CLOUDFORMATION_TEMPLATES_DIR" "$UPLOAD_TO_BASTION_DIR/"
  echo "Copied $CLOUDFORMATION_TEMPLATES_DIR directory to bastion upload directory."
fi
cp -r day1_config day2_config bastion_script.sh aws_lib.sh ocp_rhdp.config pull-secret.txt "$UPLOAD_TO_BASTION_DIR"

echo "Transferring files to bastion host $PUBLIC_DNS_NAME..."
scp -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" -r "$UPLOAD_TO_BASTION_DIR/." "ec2-user@$PUBLIC_DNS_NAME:/home/ec2-user"

echo "Running the ocp installation script on the bastion (this may take a while)..."
ssh -T -o "StrictHostKeyChecking=no" -i "$BASTION_KEY_PEM_FILE" "ec2-user@$PUBLIC_DNS_NAME" ./bastion_script.sh

echo "Bastion script execution finished."
echo "The local script has completed its tasks. Bastion key '$BASTION_KEY_PEM_FILE' is kept locally at $(pwd)/$BASTION_KEY_PEM_FILE for potential debugging."
if [ "$INSTALL_TYPE" == "IPI" ]; then
  echo "Wait few minutes the OAuth initialization before authenticating to the Web Console using htpassw identity provider!!"
fi
