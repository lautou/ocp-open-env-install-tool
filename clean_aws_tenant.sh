#!/bin/bash
set -e
if [[ $# -lt 5 ]]; then
  echo "Incorrect number of arguments. Expected: 5. Found: $#."
  exit 1
fi
AWS_ACCESS_KEY_ID=$1
AWS_SECRET_ACCESS_KEY=$2
AWS_DEFAULT_REGION=$3
CLUSTER_NAME=$4
RHDP_TOP_LEVEL_ROUTE53_DOMAIN=$5

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
cd $(dirname $0)
. aws_lib.sh

STACK_PREFIX="${CLUSTER_NAME}-cfn"
NODEGROUP_STACKS=()
BOOTSTRAP_STACK=""
MASTERS_STACK=""
LOADBALANCER_STACK=""
SECURITY_STACK=""
NETWORK_STACK=""
OTHER_CLUSTER_STACKS=()

ALL_EXISTING_STACKS=$(aws cloudformation list-stacks --stack-status-filter \
  CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE CREATE_FAILED \
  ROLLBACK_FAILED DELETE_FAILED UPDATE_ROLLBACK_COMPLETE UPDATE_ROLLBACK_FAILED \
  IMPORT_COMPLETE IMPORT_ROLLBACK_COMPLETE \
  --query "StackSummaries[?StackStatus != 'DELETE_COMPLETE'].StackName" \
  --output text)

for stack_name in $ALL_EXISTING_STACKS; do
  if [[ "$stack_name" == "${STACK_PREFIX}-nodegroup-"* ]]; then
    NODEGROUP_STACKS+=("$stack_name")
  elif [[ "$stack_name" == "${STACK_PREFIX}-bootstrap" ]]; then
    BOOTSTRAP_STACK="$stack_name"
  elif [[ "$stack_name" == "${STACK_PREFIX}-masters" ]]; then
    MASTERS_STACK="$stack_name"
  elif [[ "$stack_name" == "${STACK_PREFIX}-loadbalancer" ]]; then
    LOADBALANCER_STACK="$stack_name"
  elif [[ "$stack_name" == "${STACK_PREFIX}-security" ]]; then
    SECURITY_STACK="$stack_name"
  elif [[ "$stack_name" == "${STACK_PREFIX}-network" ]]; then
    NETWORK_STACK="$stack_name"
  elif [[ "$stack_name" == "${CLUSTER_NAME}-"* ]] || [[ "$stack_name" == "${STACK_PREFIX}"* ]]; then
    TAGS=$(aws cloudformation describe-stacks --stack-name "$stack_name" --query "Stacks[0].Tags" --output json 2>/dev/null || echo "[]")
    if jq -e ".[] | select(.Key==\"ClusterName\" and .Value==\"$CLUSTER_NAME\")" <<< "$TAGS" > /dev/null 2>&1; then
        OTHER_CLUSTER_STACKS+=("$stack_name")
    fi
  fi
done

echo "Checking and deleting previous CloudFormation stacks related to cluster '$CLUSTER_NAME'..."

STAGE1_STACKS=("${NODEGROUP_STACKS[@]}")
if [[ -n "$BOOTSTRAP_STACK" ]]; then STAGE1_STACKS+=("$BOOTSTRAP_STACK"); fi
if [[ -n "$MASTERS_STACK" ]]; then STAGE1_STACKS+=("$MASTERS_STACK"); fi
echo "--- Deleting Stage 1 CloudFormation Stacks (Nodegroups, Bootstrap, Masters) ---"
delete_and_wait_stacks "${STAGE1_STACKS[@]}"

if [ ${#OTHER_CLUSTER_STACKS[@]} -gt 0 ]; then
    echo "--- Deleting Other Cluster-Tagged CloudFormation Stacks ---"
    delete_and_wait_stacks "${OTHER_CLUSTER_STACKS[@]}"
fi

echo Check and delete previous route53 materials...
check_and_delete_previous_r53_hzr_all $CLUSTER_NAME$RHDP_TOP_LEVEL_ROUTE53_DOMAIN
check_and_delete_previous_r53_hz $CLUSTER_NAME$RHDP_TOP_LEVEL_ROUTE53_DOMAIN
check_and_delete_previous_r53_hzr_all ${RHDP_TOP_LEVEL_ROUTE53_DOMAIN:1} 

echo "--- Deleting Stage 2 CloudFormation Stacks (Loadbalancer) ---"
if [[ -n "$LOADBALANCER_STACK" ]]; then
    delete_and_wait_stacks "$LOADBALANCER_STACK"
else
    echo "Loadbalancer stack not identified for deletion."
fi

echo "--- Deleting Stage 3 CloudFormation Stacks (Security) ---"
if [[ -n "$SECURITY_STACK" ]]; then
    delete_and_wait_stacks "$SECURITY_STACK"
else
    echo "Security stack not identified for deletion."
fi

echo "Checking and deleting previous Auto Scaling Groups..."
for asg_name in $(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName" --output text); do
  echo "Deleting Auto Scaling Group: $asg_name"
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$asg_name" --force-delete > /dev/null
done
echo "Auto Scaling Group deletion process initiated."

echo Check and delete previous instances...
INSTANCE_ID=$(aws_ec2_get instance Reservations[].Instances[].InstanceId)
if [[ ! -z "$INSTANCE_ID" ]]; then
  echo "found instance(s): $INSTANCE_ID"
  echo terminating instances...
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID > /dev/null
  echo "wait instances are terminated (could take 2-3 minutes)..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
fi

echo "Check and delete previous ELBs (Classic Load Balancers)..."
classic_lbs_to_delete=()
for lb_name in $(aws_elb_get load-balancer LoadBalancerDescriptions[].LoadBalancerName); do
  classic_lbs_to_delete+=("$lb_name")
  echo "Initiating deletion for Classic ELB: $lb_name"
  aws elb delete-load-balancer --load-balancer-name "$lb_name" > /dev/null
done

echo "Check and delete previous ELBv2 (Application/Network Load Balancers)..."
elbv2_lbs_to_delete=()
for lb_arn in $(aws_elbv2_get load-balancer LoadBalancers[].LoadBalancerArn); do
  elbv2_lbs_to_delete+=("$lb_arn")
  echo "Initiating deletion for ELBv2: $lb_arn"
  aws elbv2 delete-load-balancer --load-balancer-arn "$lb_arn" > /dev/null
done

if [ ${#classic_lbs_to_delete[@]} -gt 0 ]; then
  echo "Waiting for Classic ELBs to be deleted..."
  for lb_name in "${classic_lbs_to_delete[@]}"; do
    echo -n "Waiting for $lb_name to be deleted..."
    while aws elb describe-load-balancers --load-balancer-names "$lb_name" > /dev/null 2>&1; do
      echo -n "."
      sleep 10
    done
    echo " Deleted."
  done
fi

if [ ${#elbv2_lbs_to_delete[@]} -gt 0 ]; then
  echo "Waiting for ELBv2 (ALB/NLB) to be deleted..."
  for lb_arn in "${elbv2_lbs_to_delete[@]}"; do
    echo -n "Waiting for $lb_arn to be deleted..."
    while aws elbv2 describe-load-balancers --load-balancer-arns "$lb_arn" > /dev/null 2>&1; do
      echo -n "."
      sleep 10
    done
    echo " Deleted."
  done
fi
echo "Load balancer deletion and waiting process complete."

prev_vpc_ids=$(aws_ec2_get vpc Vpcs[].VpcId)
if [[ ! -z "$prev_vpc_ids" ]]; then
  prev_vpc_ids_cs=$(echo $prev_vpc_ids | sed "s/ /,/g")

  echo "Check and delete previous NAT Gateways for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get nat-gateway NatGateways[].NatGatewayId vpc-id $prev_vpc_ids_cs); do aws ec2 delete-nat-gateway --nat-gateway-id $i > /dev/null; done
  echo "Waiting NAT Gateways are deleted..."
  while [[ ! -z "$(aws_ec2_get nat-gateway NatGateways[].NatGatewayId vpc-id $prev_vpc_ids_cs state pending,available,deleting)" ]];
  do
    echo -n .
    sleep 5
  done

  echo "Check, detach and delete previous Internet Gateways for vpc ids ... $prev_vpc_ids"
  for vpcid in $prev_vpc_ids
  do
    for i in $(aws_ec2_get internet-gateway InternetGateways[].InternetGatewayId attachment.vpc-id $vpcid)
    do
      aws ec2 detach-internet-gateway --internet-gateway-id $i --vpc-id $vpcid > /dev/null
      aws ec2 delete-internet-gateway --internet-gateway-id $i > /dev/null
    done
  done

  echo "Delete previous security group rules for vpc ids $prev_vpc_ids"
  sg=$(aws_ec2_get security-group "SecurityGroups[?!(GroupName=='default')].GroupId" vpc-id $prev_vpc_ids_cs)
  for i in $sg
  do
    echo delete ingress rules for security group: $i
    sgr=$(aws_ec2_get security-group-rule "SecurityGroupRules[?!(IsEgress)].SecurityGroupRuleId" group-id $i)
    if [[ ! -z "$sgr" ]]; then
      aws ec2 revoke-security-group-ingress --group-id $i --security-group-rule-ids $sgr > /dev/null
    fi
    echo delete egress rules for security group: $i
    sgr=$(aws_ec2_get security-group-rule "SecurityGroupRules[?IsEgress].SecurityGroupRuleId" group-id $i)
    if [[ ! -z "$sgr" ]]; then
      aws ec2 revoke-security-group-egress --group-id $i --security-group-rule-ids $sgr > /dev/null
    fi
  done

  echo "Delete previous security group for vpc ids $prev_vpc_ids"
  for i in $sg
  do
    echo delete security group: $i
    aws ec2 delete-security-group --group-id $i > /dev/null
  done
fi

echo "--- Deleting Stage 4 CloudFormation Stacks (Network) ---"
if [[ -n "$NETWORK_STACK" ]]; then
    delete_and_wait_stacks "$NETWORK_STACK"
else
    echo "Network stack not identified for deletion."
fi

echo "CloudFormation stack deletion process finished."

echo Check and delete previous EIPs...
for i in $(aws_ec2_get addresse Addresses[].AllocationId); do aws ec2 release-address --allocation-id $i > /dev/null; done

prev_vpc_ids=$(aws_ec2_get vpc Vpcs[].VpcId)
if [[ ! -z "$prev_vpc_ids" ]]; then
  prev_vpc_ids_cs=$(echo $prev_vpc_ids | sed "s/ /,/g")

  echo "Check and delete previous Network interfaces for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get network-interface NetworkInterfaces[].NetworkInterfaceId vpc-id $prev_vpc_ids_cs); do aws ec2 delete-network-interface --network-interface-id $i > /dev/null; done

  echo "Check and delete previous subnets for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get subnet Subnets[].SubnetId vpc-id $prev_vpc_ids_cs); do aws ec2 delete-subnet --subnet-id $i > /dev/null; done

  echo "Check and delete previous vpc endpoints for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get vpc-endpoint VpcEndpoints[].VpcEndpointId vpc-id $prev_vpc_ids_cs); do aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $i > /dev/null; done

  echo "Check and delete previous route tables for vpc ids ... $prev_vpc_ids"
  for i in $(aws_ec2_get route-table "RouteTables[?!(Associations[].Main)].RouteTableId" vpc-id $prev_vpc_ids_cs); do aws ec2 delete-route-table --route-table-id $i > /dev/null; done

  for vpcid in $prev_vpc_ids; do
    echo "Delete vpc id: $vpcid..."
    aws ec2 delete-vpc --vpc-id $vpcid > /dev/null
  done
fi

echo Delete previous S3 buckets...
for bucket in $(aws s3api list-buckets --query Buckets[].Name --output text); do
  aws s3 rb s3://$bucket --force 1>/dev/null
done

echo Delete previous Elastic Block Storage...
for i in $(aws_ec2_get volume Volumes[].VolumeId); do aws ec2 delete-volume --volume-id $i > /dev/null; done

echo "Checking and deleting IAM users with 'kubernetes.io/cluster/*' tags..."
USER_NAMES=$(aws iam list-users --query "Users[].UserName" --output text)
if [ -n "$USER_NAMES" ]; then
  for user_name in $USER_NAMES; do
    echo "Checking tags for user: $user_name"
    USER_TAGS=$(aws iam list-user-tags --user-name "$user_name" --query "Tags[]" --output json 2>/dev/null)

    if echo "$USER_TAGS" | jq -e '.[] | select(.Key | startswith("kubernetes.io/cluster/"))' > /dev/null; then
      echo "User '$user_name' has matching tags. Proceeding with deletion."
      
      set +e # Temporarily disable exit on error to report details

      # Detach user from groups
      GROUPS=$(aws iam list-groups-for-user --user-name "$user_name" --query "Groups[].GroupName" --output text)
      if [ $? -ne 0 ]; then echo "No groups for user '$user_name'. Skipping group removal."; else
        if [ -n "$GROUPS" ]; then
          for group_name in $GROUPS; do
            echo "Removing user '$user_name' from group '$group_name'..."
            aws iam remove-user-from-group --user-name "$user_name" --group-name "$group_name"
            if [ $? -ne 0 ]; then echo "ERROR: Failed to remove user '$user_name' from group '$group_name'."; fi
          done
        fi
      fi

      # Delete access keys
      ACCESS_KEYS=$(aws iam list-access-keys --user-name "$user_name" --query "AccessKeyMetadata[].AccessKeyId" --output text)
      if [ $? -ne 0 ]; then echo "No access keys for user '$user_name'. Skipping access key deletion."; else
        if [ -n "$ACCESS_KEYS" ]; then
          for key_id in $ACCESS_KEYS; do
            echo "Deleting access key '$key_id' for user '$user_name'..."
            aws iam delete-access-key --user-name "$user_name" --access-key-id "$key_id"
            if [ $? -ne 0 ]; then echo "ERROR: Failed to delete access key '$key_id' for user '$user_name'."; fi
          done
        fi
      fi

      # Delete signing certificates
      CERTIFICATES=$(aws iam list-signing-certificates --user-name "$user_name" --query "Certificates[].CertificateId" --output text)
      if [ $? -ne 0 ]; then echo "No signing certificates for user '$user_name'. Skipping certificate deletion."; else
        if [ -n "$CERTIFICATES" ]; then
          for cert_id in $CERTIFICATES; do
            echo "Deleting signing certificate '$cert_id' for user '$user_name'..."
            aws iam delete-signing-certificate --user-name "$user_name" --certificate-id "$cert_id"
            if [ $? -ne 0 ]; then echo "ERROR: Failed to delete signing certificate '$cert_id' for user '$user_name'."; fi
          done
        fi
      fi
      
      # Delete SSH public keys
      SSH_KEYS=$(aws iam list-ssh-public-keys --user-name "$user_name" --query "SSHPublicKeys[].SSHPublicKeyId" --output text)
      if [ $? -ne 0 ]; then echo "No SSH public keys for user '$user_name'. Skipping SSH key deletion."; else
        if [ -n "$SSH_KEYS" ]; then
          for ssh_key_id in $SSH_KEYS; do
            echo "Deleting SSH public key '$ssh_key_id' for user '$user_name'..."
            aws iam delete-ssh-public-key --user-name "$user_name" --ssh-public-key-id "$ssh_key_id"
            if [ $? -ne 0 ]; then echo "ERROR: Failed to delete SSH public key '$ssh_key_id' for user '$user_name'."; fi
          done
        fi
      fi

      # Delete service specific credentials
      SVC_CREDS=$(aws iam list-service-specific-credentials --user-name "$user_name" --query "ServiceSpecificCredentials[].ServiceSpecificCredentialId" --output text)
      if [ $? -ne 0 ]; then echo "No service specific credentials for user '$user_name'. Skipping service credential deletion."; else
        if [ -n "$SVC_CREDS" ]; then
          for svc_cred_id in $SVC_CREDS; do
            echo "Deleting service specific credential '$svc_cred_id' for user '$user_name'..."
            aws iam delete-service-specific-credential --user-name "$user_name" --service-specific-credential-id "$svc_cred_id"
            if [ $? -ne 0 ]; then echo "ERROR: Failed to delete service specific credential '$svc_cred_id' for user '$user_name'."; fi
          done
        fi
      fi

      # Deactivate and delete MFA devices
      MFA_DEVICES=$(aws iam list-mfa-devices --user-name "$user_name" --query "MFADevices[].SerialNumber" --output text)
      if [ $? -ne 0 ]; then echo "No MFA devices for user '$user_name'. Skipping MFA deactivation."; else
        if [ -n "$MFA_DEVICES" ]; then
          for mfa_sn in $MFA_DEVICES; do
            echo "Deactivating MFA device '$mfa_sn' for user '$user_name'..."
            aws iam deactivate-mfa-device --user-name "$user_name" --serial-number "$mfa_sn"
            if [ $? -ne 0 ]; then echo "ERROR: Failed to deactivate MFA device '$mfa_sn' for user '$user_name'."; fi
            # Consider adding delete-virtual-mfa-device if needed
          done
        fi
      fi

      # Detach managed policies
      MANAGED_POLICIES=$(aws iam list-attached-user-policies --user-name "$user_name" --query "AttachedPolicies[].PolicyArn" --output text)
      if [ $? -ne 0 ]; then echo "No attached managed policies for user '$user_name'. Skipping managed policy detachment."; else
        if [ -n "$MANAGED_POLICIES" ]; then
          for policy_arn in $MANAGED_POLICIES; do
            echo "Detaching managed policy '$policy_arn' from user '$user_name'..."
            aws iam detach-user-policy --user-name "$user_name" --policy-arn "$policy_arn"
            if [ $? -ne 0 ]; then echo "ERROR: Failed to detach managed policy '$policy_arn' from user '$user_name'."; fi
          done
        fi
      fi

      # Delete inline policies
      INLINE_POLICIES=$(aws iam list-user-policies --user-name "$user_name" --query "PolicyNames[]" --output text)
      if [ $? -ne 0 ]; then echo "No inline policies for user '$user_name'. Skipping inline policy deletion."; else
        if [ -n "$INLINE_POLICIES" ]; then
          for policy_name in $INLINE_POLICIES; do
            echo "Deleting inline policy '$policy_name' from user '$user_name'..."
            aws iam delete-user-policy --user-name "$user_name" --policy-name "$policy_name"
            if [ $? -ne 0 ]; then echo "ERROR: Failed to delete inline policy '$policy_name' from user '$user_name'."; fi
          done
        fi
      fi
      
      # Delete login profile (if exists)
      aws iam get-login-profile --user-name "$user_name" > /dev/null 2>&1
      if [ $? -eq 0 ]; then # Check if command was successful (login profile exists)
        echo "Deleting login profile for user '$user_name'..."
        aws iam delete-login-profile --user-name "$user_name"
        if [ $? -ne 0 ]; then echo "ERROR: Failed to delete login profile for user '$user_name'."; fi
      else
        echo "No login profile to delete for user '$user_name'."
      fi

      # Finally, delete the user
      echo "Attempting to delete user '$user_name'..."
      aws iam delete-user --user-name "$user_name"
      if [ $? -eq 0 ]; then
        echo "Successfully deleted user '$user_name'."
      else
        echo "ERROR: Failed to delete user '$user_name'. This may be due to remaining dependencies or permissions issues."
        # Attempt to get more info if delete failed
        aws iam get-user --user-name "$user_name" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "User '$user_name' still exists. Please check IAM console for details and manual cleanup if necessary."
        else
            echo "User '$user_name' seems to have been deleted despite earlier error reporting, or there's another issue."
        fi
      fi
      set -e # Re-enable exit on error
    else
      echo "User '$user_name' does not have matching tags. Skipping."
    fi
  done
else
  echo "No IAM users found to check."
fi

echo "AWS Tenant cleanup script finished."