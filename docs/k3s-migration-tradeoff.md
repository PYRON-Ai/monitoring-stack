# Pyron Infra — Kubernetes (k3s) Migration: Trade-off & FinOps Analysis

> Status: **Discussion draft** — for the team to read and think over. No decision made.
> Author: Andre · Date: 2026-06

## Context

We currently run **5 droplets**, one service each, on DigitalOcean:

| Service | Size | vCPU / RAM | ~Cost/mo |
|---|---|---|---|
| webhook | s-4vcpu-8gb | 4 / 8 | $48 |
| mirror | s-4vcpu-8gb | 4 / 8 | $48 |
| backend (mvp) | s-2vcpu-4gb | 2 / 4 | $24 |
| webapp | s-2vcpu-4gb | 2 / 4 | $24 |
| monitoring | s-2vcpu-4gb | 2 / 4 | $24 |
| **Total** | | **14 / 28** | **~$168** |

> Cost figures are indicative (standard DO pricing) — to be confirmed against the real invoice before any decision.

Each box runs a single service, so most of this hardware sits idle — we're paying
for headroom we don't use, spread across 5 separate machines.

## The core question

Kubernetes (k3s) solves real operational pain for us, but it introduces real
engineering. This doc weighs both sides, with **FinOps as the deciding factor**:
the migration is only worth it if it genuinely saves money and/or unlocks scale
we'll actually need.

---

## Pain it RESOLVES

**Operational / deploy**
- Kills SSH-into-production and `rsync`-the-whole-repo (both flagged in the pentest).
  Deploy becomes pull-based from a registry.
- All operations become **CI/GitOps flows** — deploy, rollback, failover, "break
  mirror" — versioned, auditable, no manual SSH. Rollback is one command instead of
  a confusing manual process.
- Self-healing: a crashed service is rescheduled automatically instead of relying on
  `restart: unless-stopped`.

**Resource utilization (the FinOps core)**
- **Bin-packing**: instead of 5 idle single-service boxes, services share a pool of
  nodes sized to actual usage. We can consolidate to fewer, better-utilized droplets.
- Native horizontal scaling for when compute-distributed workloads (TukTuk runners,
  training/inference modules) land.

**Observability**
- Prometheus gets native k8s service discovery — no more hardcoded droplet IPs in
  `prometheus.yaml`.

**Secrets**
- k8s Secrets + Vault CSI integration — a clean home for the executor/admin keys
  (pentest L-01).

---

## New pain it INTRODUCES

- **A control plane to run**: k3s server, etcd/datastore, ingress controller,
  cert-manager, CNI. More moving parts than `docker compose`.
- **A platform layer to maintain**: Helm charts, ArgoCD, Terraform-managed cluster.
  *(Mitigated: this is well-trodden ground for us — prior experience operating 30+ EKS
  clusters with reusable plugin modules, Helm/ArgoCD/Terraform.)*
- **Networking complexity**: ingress + Cloudflare + the existing LB need to be
  re-mapped per service. Not a lift-and-shift.
- **Single point of failure risk**: a single-node k3s means the cluster IS the SPOF.
  Proper HA needs ≥3 control-plane nodes, which eats into the cost savings.
- **Bus factor**: this is higher-level engineering not everyone operates.
  **Mitigation: everything driven by CI/GitOps** so operations are codified and runnable
  by anyone via a pipeline — not locked in one person's head. Requires disciplined
  runbooks/documentation as a first-class deliverable.

---

## What stays OUT of the cluster (important)

- **MongoDB and Redis remain managed (DigitalOcean).** We do NOT bring stateful data
  stores into self-managed k8s — that's where self-managed clusters get burned. The
  cluster handles stateless services only.

---

## FinOps — the deciding number

**Conservative consolidation target:** the 14 vCPU / 28 GB currently spread across 5
boxes can realistically fit on **3 nodes**, since real per-service usage is well below
the provisioned headroom.

| Scenario | Droplets | ~Cost/mo |
|---|---|---|
| Today | 5 | ~$168 |
| k3s, no HA (1 server + 2 agents) | 3 | ~$72–96 |
| k3s, HA (3 servers) | 3+ | ~$96–120 |

**Indicative saving: ~$50–95/mo (30–45%)**, *plus* elastic capacity for the
distributed-compute roadmap without re-architecting later.

> Numbers are indicative — final sizing depends on **measured** per-service load
> (we should pull real CPU/RAM usage from the monitoring stack before committing).

---

## Honest assessment

The absolute dollar saving is **modest** (~$50–95/mo). On cost alone it's a weak case
for the migration effort. The real payoff is:

1. **Operational maturity** — GitOps-driven everything, real rollback, no SSH-to-prod.
2. **Scale readiness** — being ready for the distributed-compute roadmap *before*
   launch rather than scrambling *during* it.
3. **Pentest cleanup** — removes several flagged findings (SSH-as-root, rsync-to-prod)
   as a side effect.

So the decision is less "does it save money" and more "is the operational maturity +
scale readiness worth the engineering, given we have idle hardware and a pre-launch
window right now."

---

## Proposed approach (if we go ahead)

1. Pull real per-service resource usage from monitoring to validate the consolidation math.
2. Stand up k3s and migrate the **monitoring stack first** (currently idle, zero
   launch-critical risk) as a proof of concept — also makes observability k8s-native
   to watch everything else.
3. If proven, migrate the stateless services in waves; managed DB stays external.
4. Do this **now, pre-production** — idle hardware + no live traffic is the ideal
   migration window. Post-launch would be far riskier.

---

## Open for discussion

- Is the operational maturity worth the engineering investment right now, or post-launch?
- Are we comfortable with the bus-factor trade-off (mitigated by CI/GitOps + docs)?
- HA or non-HA to start? (affects cost saving vs. resilience)
