#!/usr/bin/env bash
# Build the callback fixed-egress proxy (EIP + SG + IAM + squid via ASG auto-heal).
# Idempotent. Requires APR1_HASH in the env (apr1-hashed proxy password):
#   source /tmp/cbproxy_creds.env && ./apply.sh
#   ./apply.sh status
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh
: "${APR1_HASH:?set APR1_HASH (apr1 password hash) in env first}"

tagspec() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$NAME_PREFIX},{Key=Project,Value=$PROJECT_TAG}]"; }

ensure_eip() {
  local id
  id=$(aws ec2 describe-addresses --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'Addresses[0].AllocationId' --output text 2>/dev/null | grep -v '^None$' || true)
  if [[ -z "$id" ]]; then
    id=$(aws ec2 allocate-address --domain vpc \
      --tag-specifications "$(tagspec elastic-ip)" --query AllocationId --output text)
    log "EIP allocated: $id"
  fi
  echo "$id"
}

ensure_sg() {
  local id
  id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
    "Name=vpc-id,Values=$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null \
    | grep -v '^None$' || true)
  if [[ -z "$id" ]]; then
    id=$(aws ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$VPC" \
      --description "callback egress squid proxy" \
      --tag-specifications "$(tagspec security-group)" --query GroupId --output text)
    # proxy port open to internet — protected by basic-auth (Supabase EF egress IPs are dynamic)
    aws ec2 authorize-security-group-ingress --group-id "$id" \
      --ip-permissions "IpProtocol=tcp,FromPort=$PROXY_PORT,ToPort=$PROXY_PORT,IpRanges=[{CidrIp=0.0.0.0/0,Description=callback-proxy-auth}]" >/dev/null
    log "SG created: $id (tcp/$PROXY_PORT, auth-gated)"
  fi
  echo "$id"
}

ensure_iam() {
  if ! aws iam get-role --role-name "$IAM_ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$IAM_ROLE" --assume-role-policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
      --tags "Key=Project,Value=$PROJECT_TAG" >/dev/null
    log "IAM role created: $IAM_ROLE"
  fi
  aws iam put-role-policy --role-name "$IAM_ROLE" --policy-name claim-eip \
    --policy-document file://iam-policy.json
  aws iam attach-role-policy --role-name "$IAM_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  if ! aws iam get-instance-profile --instance-profile-name "$IAM_PROFILE" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$IAM_PROFILE" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$IAM_PROFILE" --role-name "$IAM_ROLE"
    log "instance profile created; waiting for propagation"; sleep 10
  fi
}

build_userdata() { # <alloc-id> -> base64 userdata
  REGION="$REGION" ALLOC="$1" PUSER="$PROXY_USER" PHASH="$APR1_HASH" PORT="$PROXY_PORT" \
  python3 -c '
import os,base64
t=open("userdata.tpl.sh").read()
for k,v in [("__REGION__","REGION"),("__ALLOC_ID__","ALLOC"),("__PROXY_USER__","PUSER"),
            ("__APR1_HASH__","PHASH"),("__PROXY_PORT__","PORT")]:
    t=t.replace(k,os.environ[v])
print(base64.b64encode(t.encode()).decode())'
}

ensure_proxy() { # <alloc> <sg>
  local alloc="$1" sg="$2" lt="$NAME_PREFIX-lt" asg="$NAME_PREFIX-asg"
  local ud; ud=$(build_userdata "$alloc")
  local lt_json
  lt_json=$(cat <<JSON
{"ImageId":"$PROXY_AMI","InstanceType":"$PROXY_TYPE",
 "IamInstanceProfile":{"Name":"$IAM_PROFILE"},
 "NetworkInterfaces":[{"DeviceIndex":0,"AssociatePublicIpAddress":true,
   "SubnetId":"$PUBLIC_SUBNET","Groups":["$sg"]}],
 "MetadataOptions":{"HttpTokens":"required","HttpEndpoint":"enabled"},
 "UserData":"$ud",
 "TagSpecifications":[{"ResourceType":"instance","Tags":[
   {"Key":"Name","Value":"$NAME_PREFIX"},{"Key":"Project","Value":"$PROJECT_TAG"}]}]}
JSON
)
  if aws ec2 describe-launch-templates --launch-template-names "$lt" >/dev/null 2>&1; then
    aws ec2 create-launch-template-version --launch-template-name "$lt" \
      --launch-template-data "$lt_json" --query LaunchTemplateVersion.VersionNumber --output text >/dev/null
    aws ec2 modify-launch-template --launch-template-name "$lt" --default-version '$Latest' >/dev/null
    log "launch template updated"
  else
    aws ec2 create-launch-template --launch-template-name "$lt" --launch-template-data "$lt_json" \
      --tag-specifications "$(tagspec launch-template)" >/dev/null
    log "launch template created: $lt"
  fi
  if [[ "$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
        --query 'length(AutoScalingGroups)' --output text 2>/dev/null)" == "1" ]]; then
    aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$asg" \
      --launch-template "LaunchTemplateName=$lt,Version=\$Latest" --min-size 1 --max-size 1 --desired-capacity 1
    log "ASG updated (existing instance kept; refresh manually to roll)"
  else
    aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$asg" \
      --launch-template "LaunchTemplateName=$lt,Version=\$Latest" \
      --min-size 1 --max-size 1 --desired-capacity 1 --vpc-zone-identifier "$PUBLIC_SUBNET" \
      --health-check-type EC2 --health-check-grace-period 60 \
      --tags "Key=Project,Value=$PROJECT_TAG,PropagateAtLaunch=false"
    log "ASG created: $asg"
  fi
}

cmd_status() {
  local eip iid
  eip=$(aws ec2 describe-addresses --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    --query 'Addresses[0].[PublicIp,InstanceId]' --output text 2>/dev/null)
  iid=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
  echo "EIP/assoc : $eip"
  echo "instance  : $iid"
  echo "proxy URL : http://<EIP>:$PROXY_PORT  (user=$PROXY_USER)"
}

[[ "${1:-build}" == status ]] && { cmd_status; exit 0; }
log "region=$REGION vpc=$VPC subnet=$PUBLIC_SUBNET"
ensure_iam
sg=$(ensure_sg)
alloc=$(ensure_eip)
ensure_proxy "$alloc" "$sg"
log "done. wait ~90s, then: ./apply.sh status"
