#!/bin/bash
set -e

cd $(dirname $0)

echo Check if aws CLI is installed...
aws --version 1>/dev/null 2>&1
if [[ $? -ne 0 ]]; then
  echo "aws CLI is not installed on your workstation! Ensure aws CLI is installed."
  exit 1
fi

echo Check if podman is installed...
podman --version 1>/dev/null 2>&1
if [[ $? -ne 0 ]]; then
  echo "podman is needed to check Red Hat credentials! Ensure podman is installed."
  exit 2
fi

echo Check if pull-secret.txt file is present...
if [[ ! -f pull-secret.txt ]]; then
  echo "Cannot find pull-secret.txt file on $(dirname $0)! Get this file from console.redhat.com using your Red Hat credentials and drop it into this directory."
  exit 3
fi

echo Check if install-config_template.yaml is present...
if [[ ! -f install-config_template.yaml ]]; then
  echo "Cannot find install-config_template.yaml file on $(dirname $0)."
  exit 4
fi

echo Check if ocp_rhdp.config is present...
if [[ ! -f ocp_rhdp.config ]]; then
  echo "Cannot find ocp_rhdp.config file on $(dirname $0)"
  exit 5
fi
. ocp_rhdp.config

RHOCM_PULL_SECRET=$(cat pull-secret.txt)

#At this stage, we have generated some variables...
echo
echo ------------------------------------
echo Configuration variables
echo ------------------------------------
echo OPENSHIFT_VERSION=$OPENSHIFT_VERSION
echo RHDP_TOP_LEVEL_ROUTE53_DOMAIN=$RHDP_TOP_LEVEL_ROUTE53_DOMAIN
echo CLUSTER_NAME=$CLUSTER_NAME
echo AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
echo AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
echo AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
echo AWS_AMI=$AWS_AMI
echo AWS_INSTANCE_TYPE_INFRA_NODES=$AWS_INSTANCE_TYPE_INFRA_NODES
echo AWS_INSTANCE_TYPE_STORAGE_NODES=$AWS_INSTANCE_TYPE_STORAGE_NODES
echo RHOCM_PULL_SECRET=$RHOCM_PULL_SECRET
echo OCP_DOWNLOAD_BASE_URL=$OCP_DOWNLOAD_BASE_URL
echo ------------------------------------

# Load AWS library
. aws_lib.bash

echo Check if Route53 base domain is valid...
if [[ "${RHDP_TOP_LEVEL_ROUTE53_DOMAIN::1}" != "." ]]; then
  echo "The base domain $RHDP_TOP_LEVEL_ROUTE53_DOMAIN does not start with a period."
  exit 6
fi

echo Check RH subscription credentials validity...
REGISTRY_LIST=(registry.connect.redhat.com quay.io registry.redhat.io)
for registry in ${REGISTRY_LIST[@]};
do
  podman login --authfile=pull-secret.txt $registry < /dev/null
done

echo Check Amazon credentials...
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
aws sts get-caller-identity

echo Check base domain hosted zone exists...
if [[ -z "$(get_r53_hz ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1})" ]]; then
  echo "Base domain does not exist: ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}."
  exit 7
fi

echo Check Amazon image existence on the selected region: $AWS_DEFAULT_REGION...
aws ec2 describe-images --image-ids $AWS_AMI 1>/dev/null

echo Check and clean the AWS tenant...
./clean_aws_tenant.sh $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY $AWS_DEFAULT_REGION $CLUSTER_NAME $RHDP_TOP_LEVEL_ROUTE53_DOMAIN

echo ------------------------------------
echo Creating the VPC...
VPC_ID=$(aws ec2 create-vpc --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$CLUSTER_NAME$RHDP_TOP_LEVEL_ROUTE53_DOMAIN}]" --output text --query Vpc.VpcId --cidr 192.168.0.0/16)
echo VPC_ID=$VPC_ID

echo Enable DNS Hostnames in the VPC...
aws ec2 modify-vpc-attribute --enable-dns-hostnames --vpc-id $VPC_ID

echo Creating the subnet for VPC id $VPC_ID...
SUBNET_ID=$(aws ec2 create-subnet --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=bastion}]" --output text --query Subnet.SubnetId --cidr 192.168.0.0/24 --vpc-id=$VPC_ID)
echo SUBNET_ID=$SUBNET_ID

echo Creating the security group for VPC id $VPC_ID...
SG_ID=$(aws ec2 create-security-group --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=Bastion}]" --output text --query GroupId --group-name Bastion --description Host --vpc-id $VPC_ID)
echo SG_ID=$SG_ID

echo Creating the TCP port 22 ingress rule for security group id $SG_ID... 
INGRESS_TCP_22_ID=$(aws ec2 authorize-security-group-ingress --group-id $SG_ID --cidr 0.0.0.0/0 --protocol tcp --port 22 --output text --query SecurityGroupRules[].GroupId)
echo INGRESS_TCP_22_ID=$INGRESS_TCP_22_ID
echo ------------------------------------
echo

echo Creating an Internet Gateway...
IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=bastion-vpc-igw}]" --output text --query InternetGateway.InternetGatewayId)
echo IGW_ID=$IGW_ID

echo Attaching Internet Gateway id $IGW_ID to vpc id $VPC_ID...
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

echo Creating a route table for vpc id $VPC_ID...
RT_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --output text --query RouteTable.RouteTableId)
echo RT_ID=$RT_ID

echo Associate route table id $RT_ID to subnet $SUBNET_ID...
aws ec2 associate-route-table --route-table-id $RT_ID --subnet-id $SUBNET_ID 

echo Create route in table id $RT_ID for internet gateway $IGW_ID...
aws ec2 create-route --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

echo "Creating the keys for the bastion..."
aws ec2 delete-key-pair --key-name bastionkey
aws ec2 create-key-pair --key-name bastionkey --query KeyMaterial --output text > bastion.pem
chmod 600 bastion.pem

echo Creating the bastion...
INSTANCE_ID=$(aws ec2 run-instances --image-id $AWS_AMI --instance-type t2.large --subnet-id $SUBNET_ID --key-name bastionkey --security-group-ids $SG_ID --associate-public-ip-address --query Instances[].InstanceId --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=bastion}]" --output text)
echo INSTANCE_ID=$INSTANCE_ID
echo Waiting the bastion instance state is running...
aws ec2 wait instance-running --filters Name=instance-id,Values=$INSTANCE_ID
echo Bastion instance is running
PUBLIC_DNS_NAME=$(aws_ec2_get instance Reservations[].Instances[].PublicDnsName instance-id $INSTANCE_ID)
echo PUBLIC_DNS_NAME=$PUBLIC_DNS_NAME
echo Waiting the system status for bastion instance is OK...
aws ec2 wait system-status-ok --instance-ids $INSTANCE_ID
echo System status is OK
echo Copy template files to the bastion...

scp -o "StrictHostKeyChecking=no" -i bastion.pem -r install-config_template.yaml day1_config day2_config credentials_template bastion_script.sh aws_lib.bash ec2-user@$PUBLIC_DNS_NAME:/home/ec2-user

echo "Running the ocp installation script into the bastion..."

ssh -T -o "StrictHostKeyChecking=no" -i bastion.pem ec2-user@$PUBLIC_DNS_NAME ./bastion_script.sh $OCP_DOWNLOAD_BASE_URL $OPENSHIFT_VERSION $CLUSTER_NAME $RHDP_TOP_LEVEL_ROUTE53_DOMAIN "'$RHOCM_PULL_SECRET'" $AWS_DEFAULT_REGION $AWS_ACCESS_KEY_ID $AWS_SECRET_ACCESS_KEY $AWS_INSTANCE_TYPE_INFRA_NODES $AWS_INSTANCE_TYPE_STORAGE_NODES

echo "OCP installation lab setup script ended."
echo "Wait few minutes the OAuth initialization before authenticating to the Web Console using htpassw identity provider!!"
