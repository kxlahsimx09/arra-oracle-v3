# callback egress topology — fixed IP for client webhooks

**Account** 261955339426 · **Region** `ap-southeast-2` (Sydney) · **VPC**
`vpc-0d63bd1a3e6e1a982`. **Built / verified** 2026-06-24.

Gives the payment-gateway's **client callbacks** one stable egress IP to whitelist.
The `dispatch-callback` Edge Function routes its `fetch(callback_url)` through a
squid forward proxy on EC2 + Elastic IP; clients see the EIP, not Supabase's
rotating Edge-runtime IPs.

> Region note: the proxy IP only needs to be **stable**, not in any particular
> country. It runs in ap-southeast-2 because ap-southeast-1 On-Demand vCPU was
> exhausted (8/8: oracle-runner + 2 bankbot proxies); ap-se-2 had headroom.
> vCPU quotas are per-region, so relocating sidesteps the limit entirely.

```
dispatch-callback EF (Supabase ap-se-1)        squid proxy (EC2 t4g.nano + EIP, ap-se-2)   client
  fetch(callback_url, {                         ┌───────────────────────────────┐
    client: Deno.createHttpClient({  ──CONNECT─▶│ auth + CONNECT→443 only        │──TLS──▶ client
      proxy:{ url, basicAuth }}) })  Proxy-Auth │ EIP 52.65.119.13 (fixed)       │   sees EIP
                                                └───────────────────────────────┘
```

## Resources (live)
| What | Id / value |
|------|-----------|
| **Fixed egress EIP** | **52.65.119.13** (`eipalloc-0895d8abc1e860822`) |
| Proxy instance | `i-039a60efdc6b5f27b` (t4g.nano, AL2023 ARM `ami-042c728924a2da03f`) |
| Public subnet | `subnet-02f486e9abe4eef66` (ap-southeast-2c, IGW `igw-066bd619b2187d663`) |
| Security group | `sg-0a8fc9ce72d6a45b0` — inbound tcp/3128 from 0.0.0.0/0 (auth-gated) |
| ASG (auto-heal) | `cb-egress-proxy-asg` (min=max=1) |
| Launch template | `cb-egress-proxy-lt` |
| IAM role/profile | `cb-egress-proxy-role` / `cb-egress-proxy-profile` (AssociateAddress + SSM; global, reused across regions) |
| Proxy auth | user `callbackproxy`, password in Supabase secret (NOT in repo) |

## Verification (2026-06-24)
- CONNECT-https through the proxy with auth → egress IP = **52.65.119.13** (the EIP) ✅
- No credentials → denied (407) ✅ · CONNECT to a non-443 port → denied (403) ✅
- Mechanism proven on the real Supabase edge-runtime
  (`public.ecr.aws/supabase/edge-runtime:v1.74.1`, user-worker sandbox):
  `Deno.createHttpClient({proxy})` works and `fetch(url,{client})` tunnels HTTPS
  via CONNECT through the proxy.

## Auto-heal
ASG min=max=1. On every boot the squid userdata (`userdata.tpl.sh`, baked into the
LT) installs squid, writes the auth + CONNECT-443-only config, and **re-associates
the EIP** — so the whitelisted IP survives instance replacement.

## Edge Function integration (payment-gateway team)
In `supabase/functions/dispatch-callback/index.ts` (~line 162), replace the direct
fetch with a proxied client; keep the existing `callbackUrlUnsafeReason` SSRF check:
```ts
const client = Deno.createHttpClient({
  proxy: { url: Deno.env.get("CALLBACK_PROXY_URL")!,            // http://52.65.119.13:3128
           basicAuth: { username: "callbackproxy",
                        password: Deno.env.get("CALLBACK_PROXY_PW")! } },
});
const res = await fetch(row.callback_url, { ...opts, client });
```
Set Supabase function secrets `CALLBACK_PROXY_URL` + `CALLBACK_PROXY_PW`.
**Client whitelists `52.65.119.13`.**

## Security
- squid: only **authenticated CONNECT to :443** (verified — 407 without auth, 403 to
  other ports); `via off` / `forwarded_for delete` so proxy use isn't leaked.
- SG opens 3128 to 0.0.0.0/0 because Supabase Edge egress IPs are dynamic; the
  basic-auth secret is the control. Rotate the password if leaked.
- Keep the EF's SSRF/endpoint-safety check BEFORE relaying (proxy can reach any URL).

## Ops
- Build/inspect: `apply.sh` (`export APR1_HASH=...; ./apply.sh`, `./apply.sh status`).
- 1 EIP = single-AZ egress; HA would need a 2nd proxy/IP (extra whitelist entry).
- Teardown: delete ASG + LT + EIP + SG (region ap-se-2) + IAM role/profile (global);
  all tagged `Project=callback-egress-proxy`.
