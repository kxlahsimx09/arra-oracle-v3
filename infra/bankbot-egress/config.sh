# shellcheck shell=bash
# Shared config for the "1 bank = 1 fixed egress IP" build.
# NAT-instance-per-bank (t4g.nano) + per-bank ASG (min=max=1) self-heal.
# Source this from apply.sh / migrate.sh / rollback.sh.

export AWS_PROFILE="${AWS_PROFILE:-root-boostrap}"
export REGION="ap-southeast-7"
export VPC="vpc-000b8946b98f2daa5"
export CLUSTER="mb-next-bankbot"

# Existing task security group (reused; egress-only path through the NAT).
export TASK_SG="sg-0a1e0b6255aeb4f98"

# Tag every resource we create so re-runs are idempotent and rollback is exact.
export PROJECT_TAG="mb-next-bankbot-egress"
export NAME_PREFIX="mbnb-egress"

# Existing PUBLIC subnets (route to IGW) per AZ — NAT instances live here.
declare -gA PUBLIC_SUBNET_BY_AZ=(
  [ap-southeast-7a]="subnet-0eaa1fc05b85e0449"
  [ap-southeast-7b]="subnet-07dc4a86306582f2f"
  [ap-southeast-7c]="subnet-0e921b98a7007cf53"
)

# ARM64 Amazon Linux 2023 AMI (resolved from SSM 2026-06-22). t4g => ARM.
export NAT_AMI="ami-00459c1c32cae7058"
export NAT_TYPE="t4g.nano"

# One bank per row. Each bank gets: its own private subnet, route table,
# Elastic IP, NAT instance (ASG), and both of its ECS services move into it.
# Spread banks across AZs to shrink blast radius (NAT + private subnet co-located
# per AZ => no cross-AZ data charge). 1-IP-per-bank => single-AZ egress per bank.
export BANKS=(scb1 scb2 scb3 ktb1)

declare -gA BANK_AZ=(
  [scb1]="ap-southeast-7a"
  [scb2]="ap-southeast-7b"
  [scb3]="ap-southeast-7c"
  [ktb1]="ap-southeast-7a"
)

declare -gA BANK_CIDR=(
  [scb1]="172.31.48.0/24"
  [scb2]="172.31.49.0/24"
  [scb3]="172.31.50.0/24"
  [ktb1]="172.31.51.0/24"
)

# The two ECS services (main + payout) that make up each bankbot.
declare -gA BANK_SERVICES=(
  [scb1]="mb-next-bankbot-scb-fleet-scb1 mb-next-bankbot-scb-fleet-scb1-payout"
  [scb2]="mb-next-bankbot-scb-fleet-scb2 mb-next-bankbot-scb-fleet-scb2-payout"
  [scb3]="mb-next-bankbot-scb-fleet-scb3 mb-next-bankbot-scb-fleet-scb3-payout"
  [ktb1]="mb-next-bankbot-ktb-fleet-ktb1 mb-next-bankbot-ktb-fleet-ktb1-payout"
)

export IAM_ROLE="${NAME_PREFIX}-nat-role"
export IAM_PROFILE="${NAME_PREFIX}-nat-profile"
export NAT_SG_NAME="${NAME_PREFIX}-nat-sg"

aws() { command aws --profile "$AWS_PROFILE" --region "$REGION" "$@"; }
export -f aws

# Look up a single resource id we created, by Name tag. Echoes "" if absent.
# usage: by_name <ec2-describe-cmd...> ; uses Name=tag:Name filter pattern.
log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
