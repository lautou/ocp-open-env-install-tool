###############################################

function get_r53_hz {
  aws route53 list-hosted-zones --query "HostedZones[?Name=='$1.'].Id" --output text
}

function check_and_delete_previous_r53_hz {
  echo "Check and delete previous Route53 $1 hosted zones..."
  for hzid in $(get_r53_hz "$1")
  do
    if [[ ! -z "$hzid" ]]; then
      aws route53 delete-hosted-zone --id $hzid
    fi
  done
}

function check_and_delete_previous_r53_hzr_all {
  for type in A TXT;
  do
    check_and_delete_previous_r53_hzr $1 $type
  done
}

function check_and_delete_previous_r53_hzr {
  json_file=delete_records_$1_$2.json
  echo "Check and delete previous Route53 hosted zones $2 records on $1 zone..." 
  for hzid in $(get_r53_hz "$1")
  do
    if [[ ! -z "$hzid" ]]; then
      rrs=$(aws route53 list-resource-record-sets --hosted-zone-id $hzid --query "ResourceRecordSets[?Type=='$2'].Name" --output text)
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

###############################################
function create_s3_bucket {
BUCKET_PREFIX=$1-$2
BUCKET_PREFIX_LENGTH=${#BUCKET_PREFIX}
if [[ $BUCKET_PREFIX_LENGTH -lt 62 ]]; then
  for ((i=0;i<62-$BUCKET_PREFIX_LENGTH-1;i++)); do
     BUCKET_SUFFIX=${BUCKET_SUFFIX}$(printf "\x$(printf %x $((97 + $RANDOM % 26)))")
  done
  BUCKET_NAME=$BUCKET_PREFIX-$BUCKET_SUFFIX
elif [[ $BUCKET_PREFIX_LENGTH -gt 62 ]]; then
  BUCKET_PREFIX_TRUNCATED=${BUCKET_PREFIX::62}
  if [[ "$BUCKET_PREFIX_TRUNCATED" == *- ]]; then
    BUCKET_NAME=${BUCKET_PREFIX::61}$(printf "\x$(printf %x $((97 + $RANDOM % 26)))")
  else
    BUCKET_NAME=$BUCKET_PREFIX_TRUNCATED
  fi
else
  BUCKET_NAME=$BUCKET_PREFIX
fi
  aws s3 mb s3://$BUCKET_NAME 1>/dev/null
  aws s3api put-public-access-block --bucket $BUCKET_NAME --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  aws s3api put-bucket-tagging --bucket $BUCKET_NAME --tagging "TagSet=[{Key=kubernetes.io/cluster/$1,Value=owned},{Key=Name,Value=$1-$2}]"
  aws s3api put-bucket-lifecycle-configuration --bucket $BUCKET_NAME --lifecycle-configuration "Rules=[{ID=cleanup-incomplete-multipart-registry-uploads,Status=Enabled,AbortIncompleteMultipartUpload={DaysAfterInitiation=1},Prefix=\"\"}]"
  echo $BUCKET_NAME
}
###############################################
