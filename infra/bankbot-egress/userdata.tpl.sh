#!/bin/bash
# NAT-instance bootstrap. Placeholders are substituted per-bank by apply.sh:
#   __REGION__   AWS region
#   __ALLOC_ID__ Elastic IP allocation id for THIS bank (the fixed egress IP)
#   __RTB_ID__   Route table id of THIS bank's private subnet
# On every boot (incl. ASG replacement) the new instance reclaims the same EIP
# and re-points the bank's default route at itself => egress IP never changes.
set -uxo pipefail
REGION="__REGION__"
ALLOC_ID="__ALLOC_ID__"
RTB_ID="__RTB_ID__"

# 1) Turn the box into a router + masquerade outbound traffic.
#    AL2023 ships WITHOUT iptables — install it BEFORE adding rules, otherwise the
#    iptables commands no-op (command not found) and the chains stay empty.
echo 'net.ipv4.ip_forward=1' >/etc/sysctl.d/99-nat.conf
sysctl -w net.ipv4.ip_forward=1
dnf install -y iptables-services
IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
iptables -C FORWARD -j ACCEPT 2>/dev/null || iptables -A FORWARD -j ACCEPT
iptables-save >/etc/sysconfig/iptables
systemctl enable --now iptables  # restores the saved rules (with ours) on reboot

# 2) Who am I (IMDSv2).
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

# 3) Claim the role of NAT: a NAT must forward traffic not addressed to it,
#    so source/dest check MUST be off.
aws ec2 modify-instance-attribute --region "$REGION" \
  --instance-id "$IID" --no-source-dest-check

# 4) Grab this bank's fixed public IP.
aws ec2 associate-address --region "$REGION" \
  --allocation-id "$ALLOC_ID" --instance-id "$IID" --allow-reassociation

# 5) Own the default route for this bank's private subnet (replace if it exists,
#    else create it — first boot has no route yet).
aws ec2 replace-route --region "$REGION" --route-table-id "$RTB_ID" \
  --destination-cidr-block 0.0.0.0/0 --instance-id "$IID" \
  || aws ec2 create-route --region "$REGION" --route-table-id "$RTB_ID" \
       --destination-cidr-block 0.0.0.0/0 --instance-id "$IID"
