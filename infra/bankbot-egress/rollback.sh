#!/usr/bin/env bash
# Reverse the egress build. Two stages, run independently:
#
#   ./rollback.sh services   # put ECS services back on the public subnets
#                            # (assignPublicIp=ENABLED) — undo migrate.sh
#   ./rollback.sh infra      # delete ASGs, launch templates, NAT instances,
#                            # route tables, subnets, EIPs, SG, IAM — undo apply.sh
#
# Run `services` FIRST and confirm tasks are healthy before `infra`, otherwise
# tasks lose their egress path mid-rollback.
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

# Original public subnets (all 3 AZs) + ENABLED public IP = pre-change state.
ORIG_SUBNETS="subnet-07dc4a86306582f2f,subnet-0e921b98a7007cf53,subnet-0eaa1fc05b85e0449"

rollback_services() {
  for b in "${BANKS[@]}"; do for s in ${BANK_SERVICES[$b]}; do
    log "restoring $s -> public subnets, assignPublicIp=ENABLED"
    aws ecs update-service --cluster "$CLUSTER" --service "$s" \
      --network-configuration \
      "awsvpcConfiguration={subnets=[$ORIG_SUBNETS],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
      --query 'service.serviceName' --output text
  done; done
}

rollback_infra() {
  for b in "${BANKS[@]}"; do
    log "=== tearing down $b ==="
    aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$NAME_PREFIX-$b-asg" \
      --force-delete 2>/dev/null || true
    aws ec2 delete-launch-template --launch-template-name "$NAME_PREFIX-$b-lt" 2>/dev/null || true

    local subnet rtb eip
    subnet=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$NAME_PREFIX-$b-private" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    rtb=$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$NAME_PREFIX-$b-rtb" \
      --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
    eip=$(aws ec2 describe-addresses --filters "Name=tag:Name,Values=$NAME_PREFIX-$b-eip" \
      --query 'Addresses[0].AllocationId' --output text 2>/dev/null)

    [[ "$subnet" != None ]] && aws ec2 delete-subnet --subnet-id "$subnet" 2>/dev/null || true
    if [[ "$rtb" != None ]]; then
      for a in $(aws ec2 describe-route-tables --route-table-ids "$rtb" \
        --query 'RouteTables[0].Associations[].RouteTableAssociationId' --output text 2>/dev/null); do
        aws ec2 disassociate-route-table --association-id "$a" 2>/dev/null || true
      done
      aws ec2 delete-route-table --route-table-id "$rtb" 2>/dev/null || true
    fi
    [[ "$eip" != None ]] && aws ec2 release-address --allocation-id "$eip" 2>/dev/null || true
  done

  local sg
  sg=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAT_SG_NAME" \
    "Name=vpc-id,Values=$VPC" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  [[ "$sg" != None ]] && aws ec2 delete-security-group --group-id "$sg" 2>/dev/null || true

  aws iam remove-role-from-instance-profile --instance-profile-name "$IAM_PROFILE" \
    --role-name "$IAM_ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$IAM_PROFILE" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$IAM_ROLE" --policy-name nat-self-manage 2>/dev/null || true
  aws iam detach-role-policy --role-name "$IAM_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore 2>/dev/null || true
  aws iam delete-role --role-name "$IAM_ROLE" 2>/dev/null || true
  log "infra rollback complete"
}

case "${1:-}" in
  services) rollback_services ;;
  infra)    rollback_infra ;;
  *) die "usage: ./rollback.sh services | infra" ;;
esac
