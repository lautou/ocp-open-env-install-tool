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
. aws_lib.bash

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
