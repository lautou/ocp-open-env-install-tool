#!/bin/bash
set -e

###############################################

function get_r53_hz {
  aws route53 list-hosted-zones --query "HostedZones[?Name=='$1.'].Id" --output text
}

function check_and_delete_previous_r53_hzr {
  json_file=delete_records_$1.json
  echo "Check and delete previous Route53 hosted zones records on $1 zone..." 
  for hzid in $(get_r53_hz "$1")
  do
    if [[ ! -z "$hzid" ]]; then
      rrs=$(aws route53 list-resource-record-sets --hosted-zone-id $hzid --query "ResourceRecordSets[?Type=='A'].Name" --output text)
      if [[ ! -z "$rrs" ]]; then
        cat > $json_file << EOF_json1_head
{
  "Changes": [
EOF_json1_head
        cpt=0
        for i in $rrs; do
          hzjson=$(aws route53 list-resource-record-sets --hosted-zone-id $hzid --query "ResourceRecordSets[?Name=='$i']" | jq -r .[])
          echo $hzjson
          if [ $cpt -ne 0 ]; then
            echo "    ," >> $json_file
          fi
          cat >> $json_file << EOF_json1
    {
      "Action": "DELETE",
      "ResourceRecordSet": $hzjson
    }
EOF_json1
          cpt=$((cpt+1))
        done
        cat >> $json_file << EOF_json1_foot
  ]
}
EOF_json1_foot
        aws route53 change-resource-record-sets --hosted-zone-id $hzid --change-batch file://$json_file
      fi
    fi
  done
}
###############################################

###############################################
function aws_ec2_get {
  if [[ "$1" == "nat-gateway" ]]; then
    filter_arg="filter"
  else
    filter_arg="filters"
  fi
  if [[ $# -eq 2 ]]; then
    aws ec2 describe-$1s --query $2 --output text
  elif [[ $# -eq 4 ]]; then
    aws ec2 describe-$1s --query $2 --output text --$filter_arg Name=$3,Values=$4
  else
    aws ec2 describe-$1s --query $2 --output text --$filter_arg Name=$3,Values=$4 Name=$5,Values=$6
  fi
}

function aws_elb_get {
  aws elb describe-$1s --query $2 --output text
}

function aws_elbv2_get {
  aws elbv2 describe-$1s --query $2 --output text
}

###############################################
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
echo RHOCM_PULL_SECRET=$RHOCM_PULL_SECRET
echo OCP_DOWNLOAD_BASE_URL=$OCP_DOWNLOAD_BASE_URL
echo ------------------------------------

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

echo check Amazon credentials...
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
aws sts get-caller-identity

echo check base domain hosted zone exists...
if [[ -z "$(get_r53_hz ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1})" ]]; then
  echo "Base domain does not exist: ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}."
  exit 7
fi

echo check Amazon image existence on the selected region: $AWS_DEFAULT_REGION...
aws ec2 describe-images --image-ids $AWS_AMI 1>/dev/null

echo Check and delete previous ELBs...
for i in $(aws_elb_get load-balancer LoadBalancerDescriptions[].LoadBalancerName); do aws elb delete-load-balancer --load-balancer-name $i; done
for i in $(aws_elbv2_get load-balancer LoadBalancers[].LoadBalancerArn); do aws elbv2 delete-load-balancer --load-balancer-arn $i; done

prev_vpc_ids=$(aws_ec2_get vpc Vpcs[].VpcId)
if [[ ! -z "$prev_vpc_ids" ]]; then
  prev_vpc_ids_cs=$(echo $prev_vpc_ids | sed "s/ /,/g")

  echo "Check and delete previous NAT Gateways for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get nat-gateway NatGateways[].NatGatewayId vpc-id $prev_vpc_ids_cs); do aws ec2 delete-nat-gateway --nat-gateway-id $i; done
  echo "Waiting NAT Gateways are deleted..."
  while [[ ! -z "$(aws_ec2_get nat-gateway NatGateways[].NatGatewayId vpc-id $prev_vpc_ids_cs state pending,available,deleting)" ]];
  do
    echo -n .
    sleep 5
  done
fi

echo Check and delete previous EIPs...
for i in $(aws_ec2_get addresse Addresses[].AllocationId); do aws ec2 release-address --allocation-id $i; done

echo Check and delete previous route53 materials...
check_and_delete_previous_r53_hzr $CLUSTER_NAME$RHDP_TOP_LEVEL_ROUTE53_DOMAIN
check_and_delete_previous_r53_hzr ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}

echo Check and delete previous instances...
INSTANCE_ID=$(aws_ec2_get instance Reservations[].Instances[].InstanceId)
if [[ ! -z "$INSTANCE_ID" ]]; then
  echo "found instance(s): $INSTANCE_ID"
  echo terminating instances...
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID > /dev/null
  echo "wait instances are terminated (could take 2-3 minutes)..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
fi

if [[ ! -z "$prev_vpc_ids" ]]; then
  echo "Check, detach and delete previous Internet Gateways for vpc id ... $prev_vpc_ids"
  for vpcid in $prev_vpc_ids
  do
    for i in $(aws_ec2_get internet-gateway InternetGateways[].InternetGatewayId attachment.vpc-id $vpcid)
    do
      aws ec2 detach-internet-gateway --internet-gateway-id $i --vpc-id $vpcid
      aws ec2 delete-internet-gateway --internet-gateway-id $i
    done
  done

  echo "Check and delete previous Network interfaces for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get network-interface NetworkInterfaces[].NetworkInterfaceId vpc-id $prev_vpc_ids_cs); do aws ec2 delete-network-interface --network-interface-id $i; done

  echo "Delete previous security group rules for vpc id $prev_vpc_ids"
  sg=$(aws_ec2_get security-group "SecurityGroups[?!(GroupName=='default')].GroupId" vpc-id $prev_vpc_ids_cs)
  for i in $sg
  do
    echo delete ingress rules for security group: $i
    sgr=$(aws_ec2_get security-group-rule "SecurityGroupRules[?!(IsEgress)].SecurityGroupRuleId" group-id $i)
    if [[ ! -z "$sgr" ]]; then
      aws ec2 revoke-security-group-ingress --group-id $i --security-group-rule-ids $sgr
    fi
    echo delete egress rules for security group: $i
    sgr=$(aws_ec2_get security-group-rule "SecurityGroupRules[?IsEgress].SecurityGroupRuleId" group-id $i)
    if [[ ! -z "$sgr" ]]; then
      aws ec2 revoke-security-group-egress --group-id $i --security-group-rule-ids $sgr
    fi
  done

  echo "Delete previous security group for vpc id $prev_vpc_ids"
  for i in $sg
  do
    echo delete security group: $i
    aws ec2 delete-security-group --group-id $i
  done

  echo "Check and delete previous subnets for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get subnet Subnets[].SubnetId vpc-id $prev_vpc_ids_cs); do aws ec2 delete-subnet --subnet-id $i; done

  echo "Check and delete previous vpc endpoints for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get vpc-endpoint VpcEndpoints[].VpcEndpointId vpc-id $prev_vpc_ids_cs); do aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $i; done

  echo "Check and delete previous route tables for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get route-table "RouteTables[?!(Associations[].Main)].RouteTableId" vpc-id $prev_vpc_ids_cs); do aws ec2 delete-route-table --route-table-id $i; done
fi

echo "Check and delete previous target groups..."
for i in $(aws_elbv2_get target-group TargetGroups[].TargetGroupArn); do aws elbv2 delete-target-group --target-group-arn $i; done

for vpcid in $prev_vpc_ids
do
  echo "Delete vpc id: $vpcid..."
  aws ec2 delete-vpc --vpc-id $vpcid
done

echo
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

scp -o "StrictHostKeyChecking=no" -i bastion.pem -r install-config_template.yaml day1_config credentials_template ec2-user@$PUBLIC_DNS_NAME:/home/ec2-user

cat > bastion_script << EOF_bastion
  set -e

  OCP_DOWNLOAD_BASE_URL=$OCP_DOWNLOAD_BASE_URL
  OPENSHIFT_VERSION=$OPENSHIFT_VERSION
  CLUSTER_NAME=$CLUSTER_NAME
  RHDP_TOP_LEVEL_ROUTE53_DOMAIN=$RHDP_TOP_LEVEL_ROUTE53_DOMAIN
  RHOCM_PULL_SECRET='$RHOCM_PULL_SECRET'
  AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION
  AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
  AWS_INSTANCE_TYPE_INFRA_NODES=$AWS_INSTANCE_TYPE_INFRA_NODES

  OC_TARGZ_FILE=openshift-client-linux-\$OPENSHIFT_VERSION.tar.gz
  INSTALLER_TARGZ_FILE=openshift-install-linux-\$OPENSHIFT_VERSION.tar.gz
  INSTALL_DIRNAME=cluster-install
  if [[ "\$OSTYPE" == "darwin"* ]]; then
    BASE64_OPTS="-b0"
  else
    BASE64_OPTS="-w0"
  fi
  CHRONY_CONF_B64="\$(cat day1_config/chrony.conf | base64 \$BASE64_OPTS)"

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
  wget \$OCP_DOWNLOAD_BASE_URL/\$OPENSHIFT_VERSION/\$OC_TARGZ_FILE -O \$OC_TARGZ_FILE
  if [[ \$? -ne 0 ]]; then
    echo "Something was wrong when downloading CLI for OpenShift version: \$OPENSHIFT_VERSION. Ensure version exists."
    exit 10
  fi
  sudo tar -xvf \$OC_TARGZ_FILE -C /usr/bin oc kubectl

  echo "Set up bash completion for the CLI"
  sudo sh -c '/usr/bin/oc completion bash >/etc/bash_completion.d/openshift'

  echo "Installing the installer..."
  wget \$OCP_DOWNLOAD_BASE_URL/\$OPENSHIFT_VERSION/\$INSTALLER_TARGZ_FILE -O \$INSTALLER_TARGZ_FILE
  if [[ \$? -ne 0 ]]; then
    echo "Something was wrong when downloading installer for OpenShift version: \$OPENSHIFT_VERSION. Ensure version exists."
    exit 11
  fi
  tar -xvf \$INSTALLER_TARGZ_FILE openshift-install

  if [[ -f \$INSTALL_DIRNAME/terraform.tfstate ]]; then
    echo "A previous cluster installation has been detected. So we destroy the cluster first before recreating it."
    ./openshift-install destroy cluster --dir \$INSTALL_DIRNAME
    rm -rf \$INSTALL_DIRNAME
  fi
  
  mkdir -p \$INSTALL_DIRNAME .aws
  echo "Generating install-config.yaml file from template..."
  yq ".baseDomain = \\"\${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1}\\" \\
    | .metadata.name = \\"\$CLUSTER_NAME\\" \\
    | .platform.aws.region = \\"\$AWS_DEFAULT_REGION\\" \\
    | .pullSecret = \\"\${RHOCM_PULL_SECRET//\\"/\\\\\\"}\\"" \\
    install-config_template.yaml > \$INSTALL_DIRNAME/install-config.yaml

  echo "Generating AWS credentials file from template..."
  cat credentials_template | sed s/\\\$AWS_ACCESS_KEY_ID/\$AWS_ACCESS_KEY_ID/ | sed s/\\\$AWS_SECRET_ACCESS_KEY/\${AWS_SECRET_ACCESS_KEY//\//\\\/}/ > .aws/credentials
  
  echo "Generating manifests..."
  ./openshift-install create manifests --dir \$INSTALL_DIRNAME

  echo "Creating MachineConfig for chrony configuration..."
  yq ".spec.config.storage.files[0].contents.source = \\"data:text/plain;charset=utf-8;base64,\$CHRONY_CONF_B64\\"" day1_config/machineconfig/masters-chrony-configuration_template.yaml > \$INSTALL_DIRNAME/openshift/99_openshift-machineconfig_99-masters-chrony.yaml
  yq ".spec.config.storage.files[0].contents.source = \\"data:text/plain;charset=utf-8;base64,\$CHRONY_CONF_B64\\"" day1_config/machineconfig/workers-chrony-configuration_template.yaml > \$INSTALL_DIRNAME/openshift/99_openshift-machineconfig_99-workers-chrony.yaml

  echo "Creating the MachineSet for infra nodes..."
  for i in {0..2}; do
    MS_INFRA_NAME=\$(yq '.metadata.name' cluster-install/openshift/99_openshift-cluster-api_worker-machineset-\$i.yaml | sed s/worker/infra/)
    yq ".metadata.name = \\"\$MS_INFRA_NAME\\" \\
      | .spec.selector.matchLabels[\\"machine.openshift.io/cluster-api-machineset\\"] = \\"\$MS_INFRA_NAME\\" \\
      | .spec.template.metadata.labels[\\"machine.openshift.io/cluster-api-machineset\\"] = \\"\$MS_INFRA_NAME\\" \\
      | .spec.template.metadata.labels[\\"machine.openshift.io/cluster-api-machine-role\\"] = \\"infra\\" \\
      | .spec.template.spec.metadata.labels.\\"node-role.kubernetes.io/infra\\" = \\"\\" \\
      | .spec.template.spec.providerSpec.value.instanceType = \\"\$AWS_INSTANCE_TYPE_INFRA_NODES\\" \\
      | .spec.template.taints += [{\\"key\\": \\"node-role.kubernetes.io/infra\\", \\"effect\\": \\"NoSchedule\\"}]" \\
      cluster-install/openshift/99_openshift-cluster-api_worker-machineset-\$i.yaml > \$INSTALL_DIRNAME/openshift/99_openshift-cluster-api_infra-machineset-\$i.yaml
  done

  echo "Creating the cluster..."
  ./openshift-install create cluster --dir \$INSTALL_DIRNAME

  echo "Exporting admin TLS credentials..."
  echo "export KUBECONFIG=\$HOME/\$INSTALL_DIRNAME/auth/kubeconfig" >> .bashrc
  export KUBECONFIG=\$HOME/\$INSTALL_DIRNAME/auth/kubeconfig
 
  echo "Creating htpasswd file"
  htpasswd -c -b -B htpasswd admin redhat
  htpasswd -b -B htpasswd andrew r3dh4t1!
  htpasswd -b -B htpasswd karla r3dh4t1!
  htpasswd -b -B htpasswd marina r3dh4t1!

  echo "Creating HTPasswd Secret"
  oc create secret generic htpass-secret --from-file=htpasswd=htpasswd -n openshift-config --dry-run -o yaml | oc apply -f -
  
  echo "Configuring HTPassw identity provider"
  cat > cluster-oauth.yaml << EOF_IP
apiVersion: config.openshift.io/v1
kind: OAuth
metadata:
  name: cluster
spec:
  identityProviders:
  - name: my_htpasswd_provider 
    mappingMethod: claim 
    type: HTPasswd
    htpasswd:
      fileData:
        name: htpass-secret
EOF_IP
  oc apply -f cluster-oauth.yaml

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
  
  exit
EOF_bastion

echo "Running the ocp installation script into the bastion..."
ssh -T -o "StrictHostKeyChecking=no" -i bastion.pem ec2-user@$PUBLIC_DNS_NAME << EOF_ssh_bastion
$(cat bastion_script)
EOF_ssh_bastion

echo "OCP installation lab setup script ended."
