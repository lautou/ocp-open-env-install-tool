get_r53_hz_id_by_name() {
  local zone_name_to_find="$1"
  aws route53 list-hosted-zones-by-name --dns-name "$zone_name_to_find" --query "HostedZones[?Name=='$zone_name_to_find.'].Id" --output text | sed 's#.*/##'
}

check_and_delete_previous_r53_hz() {
  local zone_name_arg="$1"
  local hosted_zone_id
  hosted_zone_id=$(get_r53_hz_id_by_name "$zone_name_arg")

  if [[ -z "$hosted_zone_id" ]]; then
    echo "Route53 Cleanup: Zone $zone_name_arg not found, skipping zone deletion."
    return
  fi

  echo -n "Route53 Cleanup: Deleting hosted zone $zone_name_arg ($hosted_zone_id)... "
  local delete_status
  delete_status=$(aws route53 delete-hosted-zone --id "$hosted_zone_id" --output text --query "ChangeInfo.Status" 2>/dev/null)
  if [[ $? -eq 0 ]]; then
    echo "Deletion initiated (Status: $delete_status)."
  else
    echo "Failed to initiate deletion (zone might be already deleted or not empty of non-standard records)."
  fi
}

check_and_delete_previous_r53_hzr_all() {
  local zone_name_arg="$1"
  local hosted_zone_id
  hosted_zone_id=$(get_r53_hz_id_by_name "$zone_name_arg")

  if [[ -z "$hosted_zone_id" ]]; then
    echo "Route53 Cleanup: Zone $zone_name_arg not found, skipping record deletion."
    return
  fi

  for record_type in A TXT;
  do
    check_and_delete_previous_r53_hzr "$zone_name_arg" "$record_type" "$hosted_zone_id"
  done
}

check_and_delete_previous_r53_hzr() {
  local zone_name_arg="$1"
  local record_type_arg="$2"
  local hosted_zone_id_arg="$3"
  local json_batch_file
  json_batch_file=$(mktemp)
  local records_to_delete_count=0
  local record_set_list_json

  echo -n "Route53 Cleanup: Deleting $record_type_arg records for zone $zone_name_arg... "

  record_set_list_json=$(aws route53 list-resource-record-sets --hosted-zone-id "$hosted_zone_id_arg" --query "ResourceRecordSets[?Type=='$record_type_arg']" --output json)
  
  if echo "$record_set_list_json" | jq -e '.[] | select(.Name != "'"$zone_name_arg"'.")' > /dev/null 2>&1; then
    records_to_delete_count=$(echo "$record_set_list_json" | jq '[.[] | select(.Name != "'"$zone_name_arg"'." )] | length')
  else
    records_to_delete_count=0 
  fi

  if [[ "$records_to_delete_count" -gt 0 ]]; then
    echo "$record_set_list_json" | jq -c '{Changes: [.[] | select(.Name != "'"$zone_name_arg"'.") | {Action: "DELETE", ResourceRecordSet: .}]}' > "$json_batch_file"

    if [[ $(jq -r '.Changes | length' "$json_batch_file") -gt 0 ]]; then
        aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id_arg" --change-batch "file://$json_batch_file" > /dev/null
        echo "$records_to_delete_count $record_type_arg record(s) deletion initiated."
    else
        echo "No non-apex $record_type_arg records found to delete."
    fi
  else
    echo "No $record_type_arg records found to delete."
  fi
  rm -f "$json_batch_file"
}

aws_ec2_get() {
  local service_name="$1"
  local query_path="$2"
  local filter_name_1="$3"
  local filter_values_1="$4"
  local filter_name_2="$5"
  local filter_values_2="$6"
  local filter_option_name="filters"

  if [[ "$service_name" == "nat-gateway" ]]; then
    filter_option_name="filter"
  fi

  if [[ $# -eq 2 ]]; then
    aws ec2 describe-${service_name}s --query "$query_path" --output text
  elif [[ $# -eq 4 ]]; then
    aws ec2 describe-${service_name}s --query "$query_path" --output text --"$filter_option_name" Name="$filter_name_1",Values="$filter_values_1"
  else
    aws ec2 describe-${service_name}s --query "$query_path" --output text --"$filter_option_name" Name="$filter_name_1",Values="$filter_values_1" Name="$filter_name_2",Values="$filter_values_2"
  fi
}

aws_elb_get() {
  local service_name="$1"
  local query_path="$2"
  aws elb describe-${service_name}s --query "$query_path" --output text
}

aws_elbv2_get() {
  local service_name="$1"
  local query_path="$2"
  aws elbv2 describe-${service_name}s --query "$query_path" --output text
}

create_s3_bucket() {
  local infra_name="$1"
  local bucket_purpose="$2"
  local bucket_prefix
  local bucket_prefix_length
  local bucket_suffix=""
  local bucket_name
  local bucket_prefix_truncated

  bucket_prefix="$infra_name-$bucket_purpose"
  bucket_prefix_length=${#bucket_prefix}

  if [[ $bucket_prefix_length -lt 62 ]]; then
    for ((i=0; i < 62 - bucket_prefix_length - 1; i++)); do
       bucket_suffix="${bucket_suffix}$(printf "\\x$(printf %x $((97 + RANDOM % 26)))")"
    done
    bucket_name="$bucket_prefix-$bucket_suffix"
  elif [[ $bucket_prefix_length -gt 62 ]]; then
    bucket_prefix_truncated=${bucket_prefix::62}
    if [[ "$bucket_prefix_truncated" == *- ]]; then
      bucket_name="${bucket_prefix::61}$(printf "\\x$(printf %x $((97 + RANDOM % 26)))")"
    else
      bucket_name="$bucket_prefix_truncated"
    fi
  else
    bucket_name="$bucket_prefix"
  fi
  aws s3 mb "s3://$bucket_name" 1>/dev/null
  aws s3api put-public-access-block --bucket "$bucket_name" --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" > /dev/null
  aws s3api put-bucket-tagging --bucket "$bucket_name" --tagging "TagSet=[{Key=kubernetes.io/cluster/$infra_name,Value=owned},{Key=Name,Value=$infra_name-$bucket_purpose}]" > /dev/null
  aws s3api put-bucket-lifecycle-configuration --bucket "$bucket_name" --lifecycle-configuration "Rules=[{ID=cleanup-incomplete-multipart-registry-uploads,Status=Enabled,AbortIncompleteMultipartUpload={DaysAfterInitiation=1},Prefix=\"\"}]" > /dev/null
  echo "$bucket_name"
}

delete_and_wait_stacks() {
  local stacks_to_delete_list=("$@")
  local actually_deleted_stacks=()

  if [ ${#stacks_to_delete_list[@]} -eq 0 ]; then
    return
  fi

  for stack_to_del in "${stacks_to_delete_list[@]}"; do
    if [[ -z "$stack_to_del" ]]; then continue; fi
    if aws cloudformation describe-stacks --stack-name "$stack_to_del" > /dev/null 2>&1; then
      echo "Initiating deletion for CloudFormation stack: $stack_to_del"
      aws cloudformation delete-stack --stack-name "$stack_to_del" > /dev/null
      actually_deleted_stacks+=("$stack_to_del")
    else
      echo "CloudFormation stack $stack_to_del not found or already deleted, skipping."
    fi
  done

  if [ ${#actually_deleted_stacks[@]} -gt 0 ]; then
    echo "Waiting for CloudFormation stack(s) deletion to complete: ${actually_deleted_stacks[*]}"
    for stack_to_wait_for in "${actually_deleted_stacks[@]}"; do
      echo -n "Waiting for stack $stack_to_wait_for..."
      aws cloudformation wait stack-delete-complete --stack-name "$stack_to_wait_for"
      echo " Deleted."
    done
  fi
}

create_stack_and_wait() {
  local stack_name="$1"
  local template_file="$2"
  local parameters_file="$3"
  local capabilities=("CAPABILITY_IAM" "CAPABILITY_NAMED_IAM") # Add others if needed
  local tags_string="$4"

  echo "Deploying stack: $stack_name from template: $template_file..."
  
  local aws_tags_option=""
  if [[ -n "$tags_string" ]]; then
    aws_tags_option="--tags $tags_string"
  fi

  create_output=$(aws cloudformation create-stack --stack-name "$stack_name" --template-body "file://$template_file" --parameters "file://$parameters_file" --capabilities "${capabilities[@]}" $aws_tags_option)
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to initiate CloudFormation stack creation for $stack_name."
    echo "Output: $create_output"
    aws cloudformation describe-stack-events --stack-name "$stack_name" --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[ResourceStatus, ResourceType, LogicalResourceId, ResourceStatusReason]" --output table 2>/dev/null
    return 1
  fi
  echo "$create_output"

  echo -n "Waiting for stack $stack_name to complete creation..."
  if aws cloudformation wait stack-create-complete --stack-name "$stack_name"; then
    echo " Stack $stack_name created successfully."
    return 0
  else
    echo " FAILED."
    echo "ERROR: Stack $stack_name creation failed or rolled back."
    echo "Fetching events for $stack_name to find root cause..."
    aws cloudformation describe-stack-events --stack-name "$stack_name" \
      --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || contains(ResourceStatusReason, 'failed') || contains(ResourceStatusReason, 'error')].[Timestamp, LogicalResourceId, ResourceType, ResourceStatus, ResourceStatusReason] | reverse(sort_by(@, &[0])) | [0:5]" \
      --output table
    
    stack_status_reason=$(aws cloudformation describe-stacks --stack-name "$stack_name" --query "Stacks[0].StackStatusReason" --output text 2>/dev/null)
    if [[ -n "$stack_status_reason" ]] && [[ "$stack_status_reason" != "None" ]]; then
        echo "Overall Stack Status Reason for $stack_name: $stack_status_reason"
    fi
    return 1
  fi
}