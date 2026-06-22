# bankbot egress topology — 1 bank = 1 fixed Thai IP

**Account** 261955339426 · **Region** `ap-southeast-7` (AWS Thailand) ·
**VPC** `vpc-000b8946b98f2daa5` (172.31.0.0/16) · **Cluster** `mb-next-bankbot`
**Built / verified** 2026-06-22.

Each bankbot (a `main` + a `payout` ECS service) now egresses to its bank portal
through a **dedicated NAT instance with a fixed Elastic IP**. The task ENIs have
**no public IP** — their only route out is their bank's NAT, so the portal always
sees one stable Thai IP per bank, surviving task restart/redeploy.

## Per-bank resources

| Bank | Fixed egress EIP | Private subnet (AZ) | Route table | NAT instance (ASG) | Target portal |
|------|------------------|---------------------|-------------|--------------------|---------------|
| scb1 | **43.210.108.116** | subnet-097f237ed6cbe8e19 · 172.31.48.0/24 (7a) | rtb-006f3d5379b434b30 | i-08493967f710c067c · mbnb-egress-scb1-asg | scbportal.3-1-0-33.sslip.io |
| scb2 | **43.210.213.41**  | subnet-0de679618ca581cf4 · 172.31.49.0/24 (7b) | rtb-0e4f8a63bb44e1b68 | i-0c177e929d4b6a5ba · mbnb-egress-scb2-asg | scbportal.3-1-0-33.sslip.io |
| scb3 | **43.210.222.137** | subnet-0f6f39e1d71f3064a · 172.31.50.0/24 (7c) | rtb-08eef66b6dc47cfc6 | i-0f3fb183aca03f772 · mbnb-egress-scb3-asg | scbportal.3-1-0-33.sslip.io |
| ktb1 | **43.210.251.122** | subnet-05868cb5dbe5272d9 · 172.31.51.0/24 (7a) | rtb-006d2574ff8d862a6 | i-0e738d39856abd916 · mbnb-egress-ktb1-asg | 47-131-114-119.sslip.io |

Each bank runs two services: `…-<bank>` (main) and `…-<bank>-payout`, both
`0.5 vCPU / 2 GB / ARM64` Fargate, both in the bank's private subnet,
`assignPublicIp=DISABLED`.

## Shared resources
- Public subnets (host the NAT instances, route → IGW `igw-0102b9ee03cc432ef`):
  7a `subnet-0eaa1fc05b85e0449` · 7b `subnet-07dc4a86306582f2f` · 7c `subnet-0e921b98a7007cf53`
- NAT security group `sg-052fcb12afaff06fc` (`mbnb-egress-nat-sg`): inbound allow-all from 172.31.0.0/16
- Task security group `sg-0a1e0b6255aeb4f98` (reused): egress allow-all
- NAT IAM role `mbnb-egress-nat-role` / profile `mbnb-egress-nat-profile`
  (EIP associate + route replace + SSM core)
- NAT instances: `t4g.nano`, AL2023 ARM64 `ami-00459c1c32cae7058`, source/dest check OFF

## Traffic flow (per bank)

```
ECS task (main / payout)            bank's NAT instance (public subnet)
  private subnet, NO public IP        EIP = fixed Thai IP, src/dest check OFF
        │                                   │
        │ 0.0.0.0/0 ── bank route table ───▶│ iptables MASQUERADE (ens5)
        │                                   │
        ▼                                   ▼
   172.31.<bank>.x                    IGW ──▶ internet ──▶ bank portal
                                      portal sees: the bank's EIP, always
```

## Auto-heal (why the IP is stable across NAT replacement)

Each NAT sits in a 1-of-1 Auto Scaling Group (`min=max=desired=1`). On every boot
the instance's userdata (`userdata.tpl.sh`, baked into the launch template):
1. installs iptables, enables `ip_forward`, adds MASQUERADE + FORWARD ACCEPT;
2. disables its own source/dest check;
3. **re-associates the bank's Elastic IP** (`--allow-reassociation`);
4. **re-writes the bank route table's `0.0.0.0/0`** to point at itself.

So if the instance dies, the ASG launches a replacement that reclaims the same EIP
and re-owns the route → egress IP never changes. Validated 2026-06-22 by an
instance-refresh on scb2: the fresh instance came up with MASQUERADE active and
reclaimed 43.210.213.41 automatically.

## Verification evidence (2026-06-22)
- **SCB portal access log** (`scbportal.3-1-0-33.sslip.io`, on oracle-runner
  3.1.0.33) after full migration showed **only** 43.210.108.116 / .213.41 / .222.137
  — the prior random Fargate IPs (43.209.177.128, 43.208.49.54, …) disappeared.
- **Task-restart test**: stopping scb1's task gave a new task with a different
  private IP (172.31.48.130 → .106) but the portal still saw **43.210.108.116**.
- **ktb1** verified at infra level (no public IP, routes via its NAT); its portal
  is a different host (47.131.114.119) — grep that host's log for 43.210.251.122.

## Operational notes
- ⚠️ This repo does NOT own the `mb-next-bankbot` ECS deploy. If the bankbot
  deploy pipeline re-applies `networkConfiguration`, it reverts services to public
  subnets / `assignPublicIp=ENABLED`. Mirror the private-subnet + `DISABLED`
  config there so the change sticks.
- ECS `enableExecuteCommand=False` on all services — verify egress via portal logs
  or the NAT instance (SSM), not `ecs execute-command`.
- 1 IP per bank ⇒ egress is single-AZ per bank (a NAT instance lives in one AZ).
- Rebuild / inspect / tear down with `apply.sh`, `migrate.sh`, `rollback.sh`
  (see `README.md`). All resources tagged `Project=mb-next-bankbot-egress`.
