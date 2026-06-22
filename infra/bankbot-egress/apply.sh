#!/usr/bin/env bash
# Build per-bank fixed-egress-IP infrastructure. Idempotent: safe to re-run.
# Does NOT move ECS services (that is migrate.sh, run it after verifying NAT).
#
#   ./apply.sh            # build everything (EIP, subnet, RTB, IAM, NAT/ASG)
#   ./apply.sh status     # print current state (EIPs, instances, routes)
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

tag_spec() { # <resource-type> <bank-or-_>  -> --tag-specifications string
  local rt="$1" bank="$2" name="$NAME_PREFIX${3:+-$3}"
  local tags="{Key=Name,Value=$name},{Key=Project,Value=$PROJECT_TAG}"
  [[ "$bank" != "_" ]] && tags="$tags,{Key=Bank,Value=$bank}"
  echo "ResourceType=$rt,Tags=[$tags]"
}

find_by_tag() { # <ec2-collection> <Name-tag> <jq-id-path>
  aws ec2 "describe-$1" \
    --filters "Name=tag:Project,Values=$PROJECT_TAG" "Name=tag:Name,Values=$2" \
    --query "$3" --output text 2>/dev/null | grep -v '^None$' || true
}

ensure_eip() { # <bank> -> echoes allocation id
  local bank="$1"; local name="$NAME_PREFIX-$bank-eip" id
  id=$(find_by_tag addresses "$name" "Addresses[0].AllocationId")
  if [[ -z "$id" ]]; then
    id=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "$(tag_spec elastic-ip "$bank" "$bank-eip")" \
      --query AllocationId --output text)
    log "EIP created for $bank: $id"
  fi
  echo "$id"
}

ensure_subnet() { # <bank> -> echoes subnet id
  local bank="$1"; local name="$NAME_PREFIX-$bank-private" id
  id=$(find_by_tag subnets "$name" "Subnets[0].SubnetId")
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-subnet --vpc-id "$VPC" \
      --cidr-block "${BANK_CIDR[$bank]}" --availability-zone "${BANK_AZ[$bank]}" \
      --tag-specifications "$(tag_spec subnet "$bank" "$bank-private")" \
      --query Subnet.SubnetId --output text)
    log "private subnet created for $bank (${BANK_CIDR[$bank]} ${BANK_AZ[$bank]}): $id"
  fi
  # private subnet must NOT auto-assign public IPs
  aws ec2 modify-subnet-attribute --subnet-id "$id" --no-map-public-ip-on-launch
  echo "$id"
}

ensure_rtb() { # <bank> <subnet-id> -> echoes route table id
  local bank="$1" subnet="$2"; local name="$NAME_PREFIX-$bank-rtb" id
  id=$(find_by_tag route-tables "$name" "RouteTables[0].RouteTableId")
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-route-table --vpc-id "$VPC" \
      --tag-specifications "$(tag_spec route-table "$bank" "$bank-rtb")" \
      --query RouteTable.RouteTableId --output text)
    log "route table created for $bank: $id"
  fi
  # associate (ignore if already associated)
  aws ec2 associate-route-table --route-table-id "$id" --subnet-id "$subnet" \
    >/dev/null 2>&1 || true
  echo "$id"  # default route is created by the NAT instance on boot
}

ensure_iam() {
  if ! aws iam get-role --role-name "$IAM_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$IAM_ROLE" \
      --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=Project,Value=$PROJECT_TAG" >/dev/null
    log "IAM role created: $IAM_ROLE"
  fi
  aws iam put-role-policy --role-name "$IAM_ROLE" \
    --policy-name nat-self-manage --policy-document file://iam-policy.json
  aws iam attach-role-policy --role-name "$IAM_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  if ! aws iam get-instance-profile --instance-profile-name "$IAM_PROFILE" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$IAM_PROFILE" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$IAM_PROFILE" \
      --role-name "$IAM_ROLE"
    log "instance profile created: $IAM_PROFILE"; sleep 10  # let it propagate
  fi
}

ensure_nat_sg() { # -> echoes sg id
  local id
  id=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$NAT_SG_NAME" "Name=vpc-id,Values=$VPC" \
    --query "SecurityGroups[0].GroupId" --output text 2>/dev/null | grep -v None || true)
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-security-group --group-name "$NAT_SG_NAME" \
      --description "mb-next-bankbot NAT instances" --vpc-id "$VPC" \
      --tag-specifications "$(tag_spec security-group _ nat-sg)" \
      --query GroupId --output text)
    # allow all traffic FROM inside the VPC (the bank tasks routing through us)
    aws ec2 authorize-security-group-ingress --group-id "$id" \
      --protocol -1 --cidr 172.31.0.0/16 >/dev/null
    log "NAT security group created: $id"
  fi
  echo "$id"
}

ensure_nat() { # <bank> <alloc-id> <rtb-id> <nat-sg>
  local bank="$1" alloc="$2" rtb="$3" sg="$4"
  local az="${BANK_AZ[$bank]}" pub="${PUBLIC_SUBNET_BY_AZ[${BANK_AZ[$bank]}]}"
  local lt="$NAME_PREFIX-$bank-lt" asg="$NAME_PREFIX-$bank-asg"
  local ud; ud=$(sed -e "s|__REGION__|$REGION|" -e "s|__ALLOC_ID__|$alloc|" \
    -e "s|__RTB_ID__|$rtb|" userdata.tpl.sh | base64 -w0)

  local lt_json
  lt_json=$(cat <<JSON
{"ImageId":"$NAT_AMI","InstanceType":"$NAT_TYPE",
 "IamInstanceProfile":{"Name":"$IAM_PROFILE"},
 "NetworkInterfaces":[{"DeviceIndex":0,"AssociatePublicIpAddress":true,
   "SubnetId":"$pub","Groups":["$sg"]}],
 "MetadataOptions":{"HttpTokens":"required","HttpEndpoint":"enabled"},
 "UserData":"$ud",
 "TagSpecifications":[{"ResourceType":"instance","Tags":[
   {"Key":"Name","Value":"$NAME_PREFIX-$bank-nat"},
   {"Key":"Project","Value":"$PROJECT_TAG"},{"Key":"Bank","Value":"$bank"}]}]}
JSON
)
  if aws ec2 describe-launch-templates --launch-template-names "$lt" >/dev/null 2>&1; then
    aws ec2 create-launch-template-version --launch-template-name "$lt" \
      --launch-template-data "$lt_json" --query LaunchTemplateVersion.VersionNumber --output text >/dev/null
    aws ec2 modify-launch-template --launch-template-name "$lt" --default-version '$Latest' >/dev/null
  else
    aws ec2 create-launch-template --launch-template-name "$lt" \
      --launch-template-data "$lt_json" \
      --tag-specifications "$(tag_spec launch-template "$bank" "$bank-lt")" >/dev/null
    log "launch template created for $bank: $lt"
  fi

  if [[ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
       --query 'length(AutoScalingGroups)' --output text 2>/dev/null)" == "1" ]]; then
    # Non-disruptive: point the ASG at the newest LT so the NEXT launch uses it.
    # Replacing a live NAT now would drop the bank's egress ~1-2min, so refreshing
    # is left as a deliberate manual step: aws autoscaling start-instance-refresh ...
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg" \
      --launch-template "LaunchTemplateName=$lt,Version=\$Latest" \
      --min-size 1 --max-size 1 --desired-capacity 1
    log "ASG updated for $bank (LT=\$Latest; existing instance kept — refresh manually if needed)"
  else
    aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$asg" \
      --launch-template "LaunchTemplateName=$lt,Version=\$Latest" \
      --min-size 1 --max-size 1 --desired-capacity 1 \
      --vpc-zone-identifier "$pub" \
      --health-check-type EC2 --health-check-grace-period 90 \
      --tags "Key=Project,Value=$PROJECT_TAG,PropagateAtLaunch=false" \
             "Key=Bank,Value=$bank,PropagateAtLaunch=false"
    log "ASG created for $bank: $asg"
  fi
}

cmd_status() {
  printf '%-6s %-16s %-18s %-22s\n' BANK EIP ROUTE-VIA INSTANCE
  for b in "${BANKS[@]}"; do
    local eip rtb via iid
    eip=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$NAME_PREFIX-$b-eip" \
      --query 'Addresses[0].PublicIp' --output text 2>/dev/null)
    rtb=$(find_by_tag route-tables "$NAME_PREFIX-$b-rtb" "RouteTables[0].RouteTableId")
    via=$(aws ec2 describe-route-tables --route-table-ids "$rtb" \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].InstanceId|[0]" \
      --output text 2>/dev/null)
    iid=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=$NAME_PREFIX-$b-nat" \
      "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
    printf '%-6s %-16s %-18s %-22s\n' "$b" "$eip" "$via" "$iid"
  done
}

main() {
  [[ "${1:-build}" == status ]] && { cmd_status; return; }
  log "account=$ACCOUNT region=$REGION vpc=$VPC"
  ensure_iam
  local sg; sg=$(ensure_nat_sg)
  for b in "${BANKS[@]}"; do
    log "=== bank $b ==="
    local alloc subnet rtb
    alloc=$(ensure_eip "$b")
    subnet=$(ensure_subnet "$b")
    rtb=$(ensure_rtb "$b" "$subnet")
    ensure_nat "$b" "$alloc" "$rtb" "$sg"
  done
  log "done. wait ~2min for NAT instances to boot, then: ./apply.sh status"
  log "verify egress IPs are populated under ROUTE-VIA before running migrate.sh"
}
main "$@"
