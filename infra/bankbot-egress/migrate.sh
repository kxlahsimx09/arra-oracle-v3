#!/usr/bin/env bash
# Move each bank's two ECS services into its private subnet with
# assignPublicIp=DISABLED, so their egress exits via the bank's NAT/EIP.
# Run ONLY after ./apply.sh status shows a ROUTE-VIA instance for every bank.
#
#   ./migrate.sh            # migrate all banks (prompts per bank)
#   ./migrate.sh scb1       # migrate one bank
#   ./migrate.sh --check    # show current subnet/publicIp of every service
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh

svc_net() { # <service> -> "subnet|assignPublicIp"
  aws ecs describe-services --cluster "$CLUSTER" --services "$1" \
    --query 'services[0].networkConfiguration.awsvpcConfiguration.[subnets[0],assignPublicIp]' \
    --output text
}

if [[ "${1:-}" == "--check" ]]; then
  printf '%-42s %-24s %s\n' SERVICE SUBNET PUBLIC-IP
  for b in "${BANKS[@]}"; do for s in ${BANK_SERVICES[$b]}; do
    printf '%-42s %-24s %s\n' "$s" $(svc_net "$s")
  done; done
  exit 0
fi

migrate_bank() {
  local bank="$1"
  local subnet
  subnet=$(aws ec2 describe-subnets \
    --filters "Name=tag:Name,Values=$NAME_PREFIX-$bank-private" \
    --query 'Subnets[0].SubnetId' --output text)
  [[ "$subnet" == "None" || -z "$subnet" ]] && die "no private subnet for $bank — run apply.sh first"

  # safety: confirm the bank's default route points at a running NAT instance
  local via
  via=$(aws ec2 describe-route-tables \
    --filters "Name=tag:Name,Values=$NAME_PREFIX-$bank-rtb" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].InstanceId|[0]" \
    --output text)
  [[ -z "$via" || "$via" == "None" ]] && die "$bank route has no NAT yet — wait for the instance to boot"

  log "migrating $bank -> subnet $subnet (NAT $via), assignPublicIp=DISABLED"
  for s in ${BANK_SERVICES[$bank]}; do
    aws ecs update-service --cluster "$CLUSTER" --service "$s" \
      --network-configuration \
      "awsvpcConfiguration={subnets=[$subnet],securityGroups=[$TASK_SG],assignPublicIp=DISABLED}" \
      --query 'service.serviceName' --output text
  done
  log "$bank update issued; tasks roll over to the new subnet now"
}

targets=("$@"); [[ ${#targets[@]} -eq 0 ]] && targets=("${BANKS[@]}")
for b in "${targets[@]}"; do
  read -rp "Migrate bank '$b' (2 services, triggers task replacement)? [y/N] " ok
  [[ "$ok" == [yY] ]] && migrate_bank "$b" || log "skipped $b"
done
log "watch rollout: aws ecs wait services-stable --cluster $CLUSTER --services <svc>"
log "verify egress IP: ECS exec into a task and run: curl -s https://checkip.amazonaws.com"
