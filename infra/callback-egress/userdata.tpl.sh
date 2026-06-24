#!/bin/bash
# squid forward-proxy bootstrap. Placeholders substituted by apply.sh:
#   __REGION__     AWS region
#   __ALLOC_ID__   Elastic IP allocation id (the fixed callback egress IP)
#   __PROXY_USER__ basic-auth username
#   __APR1_HASH__  apr1-hashed password (NOT plaintext)
# On every boot the instance reclaims the same EIP, so the whitelisted callback
# IP survives ASG replacement.
set -uxo pipefail
REGION="__REGION__"
ALLOC_ID="__ALLOC_ID__"
PROXY_USER="__PROXY_USER__"
APR1_HASH='__APR1_HASH__'

# install squid FIRST (AL2023 ships without it), then configure.
dnf install -y squid

printf '%s:%s\n' "$PROXY_USER" "$APR1_HASH" > /etc/squid/passwd
chown squid:squid /etc/squid/passwd
chmod 640 /etc/squid/passwd
NCSA=$(rpm -ql squid | grep -m1 basic_ncsa_auth)

cat > /etc/squid/squid.conf <<EOF
http_port __PROXY_PORT__
auth_param basic program $NCSA /etc/squid/passwd
auth_param basic realm callback-proxy
acl authenticated proxy_auth REQUIRED
acl SSL_ports port 443
acl CONNECT method CONNECT
# only authenticated CONNECT to :443 — no open relay, no plaintext HTTP forwarding
http_access deny CONNECT !SSL_ports
http_access deny !authenticated
http_access allow authenticated CONNECT SSL_ports
http_access deny all
# do not leak that traffic was proxied
via off
forwarded_for delete
httpd_suppress_version_string on
shutdown_lifetime 5 seconds
EOF

systemctl enable squid
systemctl restart squid

# claim the fixed Elastic IP (IMDSv2)
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 associate-address --region "$REGION" \
  --allocation-id "$ALLOC_ID" --instance-id "$IID" --allow-reassociation
