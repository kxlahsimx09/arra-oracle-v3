# bankbot egress — 1 bank = 1 fixed IP

Give each bankbot a **dedicated, stable outbound IP** so the bank portal can
whitelist per bank. Mechanism: **one NAT instance per bank** (`t4g.nano`, ARM)
behind a 1-of-1 Auto Scaling Group that re-claims the bank's Elastic IP and
re-owns its route on every boot → the egress IP survives instance replacement.

```
scb1 (main+payout) → subnet-scb1(private) → rtb-scb1 → NAT-scb1(ASG) → EIP-scb1
scb2 …             → subnet-scb2           → rtb-scb2 → NAT-scb2      → EIP-scb2
scb3 …                                                                → EIP-scb3
ktb1 …                                                                → EIP-ktb1
```

Banks: `scb1, scb2, scb3, ktb1` (4 bankbots = 8 ECS services).
Cluster `mb-next-bankbot`, region `ap-southeast-7`, profile `root-boostrap`.

## Why NAT instance, not NAT Gateway
Traffic is tiny (Playwright → bank portal over HTTPS). A NAT Gateway costs
~$33/bank/mo regardless of volume; a `t4g.nano` NAT instance is ~$3/bank/mo and
more than enough. The ASG (min=max=1) replaces a dead instance in minutes and
the userdata re-attaches the same EIP, so the whitelisted IP never changes.
Trade-off: 1 IP per bank ⇒ egress is single-AZ per bank (inherent — a NAT
Gateway with 1 IP is also single-AZ).

## Run order
```bash
cd infra/bankbot-egress
./apply.sh              # 1. build EIPs, private subnets, route tables, IAM, NAT/ASG
./apply.sh status       # 2. wait ~2min; every bank must show an EIP + ROUTE-VIA instance
./migrate.sh --check    # 3. see current service networking (before)
./migrate.sh scb1       # 4. migrate one bank at a time; verify, then do the rest
```
Verify a bank's egress IP after migrating (ECS exec must be enabled on the task):
```bash
aws --profile root-boostrap --region ap-southeast-7 ecs execute-command \
  --cluster mb-next-bankbot --task <taskId> --container <name> --interactive \
  --command 'curl -s https://checkip.amazonaws.com'
# expect the bank's EIP
```

## Rollback
```bash
./rollback.sh services   # services back to public subnets + assignPublicIp=ENABLED
./rollback.sh infra      # delete ASG/LT/NAT/subnet/RTB/EIP/SG/IAM (run AFTER services)
```

## ⚠️ Not captured in IaC here
This repo (arra-oracle-v3) does **not** own the `mb-next-bankbot` ECS deploy. If
the bankbot deploy pipeline (the other repo's `deploy.yml`) re-applies service
`networkConfiguration`, it will revert these services to public subnets /
`assignPublicIp=ENABLED`. **Update that pipeline's network config to the private
subnets + `DISABLED`** so the change sticks across deploys.

## Notes
- `scb2` / `scb3` were crash-looping (new task every ~90s) at build time — an
  app-level issue, unrelated to networking. Migrating subnets won't fix it.
- IAM policy is `Resource:"*"` for simplicity; tighten to the EIP/RTB ARNs if
  required by policy review.
- All resources are tagged `Project=mb-next-bankbot-egress` (+ `Bank=<bank>`)
  for idempotent re-runs and clean teardown.
