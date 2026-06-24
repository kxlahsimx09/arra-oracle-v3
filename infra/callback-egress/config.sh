# shellcheck shell=bash
# Config for the client-callback fixed-egress proxy (ap-southeast-1).
# A squid forward proxy on EC2 + Elastic IP; the dispatch-callback Edge Function
# routes its fetch() through it so clients see one stable IP to whitelist.
# Co-located in ap-southeast-1 with Supabase (no Thai IP needed for this leg).

export AWS_PROFILE="${AWS_PROFILE:-root-boostrap}"
export REGION="ap-southeast-2"
export VPC="vpc-0d63bd1a3e6e1a982"
export PUBLIC_SUBNET="subnet-02f486e9abe4eef66"   # ap-southeast-2c, public (IGW)

export NAME_PREFIX="cb-egress-proxy"
export PROJECT_TAG="callback-egress-proxy"

export PROXY_AMI="ami-042c728924a2da03f"          # AL2023 ARM64 (ap-southeast-2, 2026-06-24)
export PROXY_TYPE="t4g.nano"
export PROXY_PORT="3128"
export PROXY_USER="callbackproxy"

export IAM_ROLE="${NAME_PREFIX}-role"
export IAM_PROFILE="${NAME_PREFIX}-profile"
export SG_NAME="${NAME_PREFIX}-sg"

aws() { command aws --profile "$AWS_PROFILE" --region "$REGION" "$@"; }
export -f aws
log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
