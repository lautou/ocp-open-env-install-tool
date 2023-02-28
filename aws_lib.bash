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

