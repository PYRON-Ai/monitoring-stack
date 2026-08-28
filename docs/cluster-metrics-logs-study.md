# DOKS → monitoring-stack: cluster metrics + pod logs (economical first pass)

> Status: **Study / blueprint** — no execution yet.
> Date: 2026-08-28 · Supersedes the open items in [`cluster-metrics-plan.md`](cluster-metrics-plan.md)
> Scope decisions taken up front: logs on **local disk, 48h–7d** · log agent as a
> **permanent DaemonSet** · **kube-state-metrics + cAdvisor in scope**.
> Numbers below **verified against the live staging cluster on 2026-08-28**
> (see [Live verification](#live-verification-2026-08-28)).

## Where we actually are (not where the old plan left off)

The July plan has been partially executed. What is live today:

| Piece | State | Path |
|---|---|---|
| ingress-nginx metrics | ✅ **done** | NodePort 30254 → scraped from the droplet ([`prometheus.yaml`](../config/prometheus.yaml)) |
| Ingress dashboard | ✅ **done** | req/s, p95, 5xx, per-service |
| Webhook app metrics | ✅ **done, via remote_write** | in-cluster prometheus-agent → droplet `:9090` |
| Firewall for the cluster→droplet path | ✅ **done** | 9090 open to `10.0.0.0/16` + `10.105.0.0/16` (pod CNI) |
| Hubble / Cilium NodePorts | ❌ not done | still ClusterIP-only |
| kube-state-metrics / cAdvisor | ❌ not done | no per-pod CPU/RAM, no restarts/OOM |
| **Pod logs** | ❌ **nothing** | Loki only ingests the droplet's own containers |

So the remaining gap is narrower than the old doc implies: **cluster state/resource
metrics, and logs.** Request-level observability is already solved.

### The real finding: we have three transport patterns, not one

Getting here produced three *different* ways for cluster data to reach the droplet:

1. **NodePort pull** — droplet scrapes `10.0.0.4:30254` (ingress).
2. **remote_write push** — in-cluster agent pushes to droplet `:9090` (webhook).
3. **nothing** — logs.

Pattern 1 broke for the webhook precisely because it doesn't survive scale: a
NodePort scrape load-balances across pods and hits **one random pod per interval**,
so per-pod series come out serrated and un-aggregatable (documented in the config's
own comment). That failure is not specific to the webhook — it applies to *any*
multi-replica target. cAdvisor and kube-state-metrics are exactly that shape.

**Consequence for this study: do not add more NodePort scrape jobs.** Pattern 1
should be treated as legacy, kept only for ingress (where it happens to work today
because staging runs one controller replica) and not extended.

## Proposal: one push path for metrics, one for logs

Consolidate on **push from inside the cluster**, which the firewall already
supports and the burn already proved:

```
    ┌─────────────────── DOKS staging ────────────────────┐
    │                                                      │
    │  kube-state-metrics ─┐                               │
    │  cAdvisor (kubelet) ─┼─→ prometheus-agent ──remote_write──┐
    │  ingress-nginx ──────┘    (Deployment, kubernetes_sd)     │
    │                                                            │
    │  every pod's stdout ──→ Grafana Alloy (DaemonSet) ──push───┤
    │                                                            │
    └────────────────────────────────────────────────────────────┤
                                                                 ▼
                          monitoring droplet 10.0.0.2 (OUTSIDE the cluster)
                          Prometheus :9090  ·  Loki :3100  ·  Grafana
```

The cluster never becomes its own monitor — the storage, dashboards and alerting
stay outside, which was the original constraint and still holds.

### Why promote the prometheus-agent from ephemeral to permanent

It exists, it works, and it already solves the multi-replica problem via
`kubernetes_sd`. Today it lives in the ephemeral namespace and dies with the burn
teardown (verified: that namespace is gone). Making it a **permanent Deployment
in a `monitoring` namespace** costs one small pod (~150–250MB RAM) and removes
the need to ever add another NodePort. **Pin it to the system node**
(`nodeSelector pyron.io/pool=system`): the workload node is already at 71% RAM
while idle, the system node at 34%.
It then carries kube-state-metrics, cAdvisor and ingress in the same pipeline.

Note this makes the disabled `webhook-app` job's comment obsolete: with a
permanent agent, the NodePort path is not "re-enable if you want it back" — it is
retired.

## Live verification (2026-08-28)

Checked against `do-sgp1-pyron-doks-staging`. What this changes is flagged inline.

**Cluster shape — 2 nodes, not 1.** `system-3meoo2` (`10.0.0.4`) and
`workload-3meo5d` (`10.0.0.5`). The workload pool is currently **on** (the
`stage.tfvars` comment says to revert it to `false` after the burn; it wasn't).

| Node | Role | CPU | RAM |
|---|---|---|---|
| system-3meoo2 (10.0.0.4) | platform | 86m (4%) | 1027Mi (**34%**) |
| workload-3meo5d (10.0.0.5) | apps | 100m (5%) | 2141Mi (**71%**) |

Everything is at 1 replica, no HPAs exist, and the only recent event is a benign
cilium-operator PDB notice. The cluster is idle and healthy.

**⚠️ The `10.0.0.4` scrape target is narrower than it looks.** The existing
ingress scrape points at the system node, and the ingress controller pod does
run there — but NodePort answering "on every node" is what makes that safe, and
the endpoint is a **single pod** (`10.105.0.117:10254`). With one controller
replica the current job works; it is one `replicaCount` bump away from the same
serrated-sampling problem the webhook hit. Reinforces the study's core
recommendation rather than contradicting it.

**RAM headroom is the real constraint, not CPU.** The workload node sits at
**71%** RAM while idle. The agent + KSM + Alloy land in roughly 300–500Mi total.
That fits, but it is not free on a `s-2vcpu-4gb` node that is already two-thirds
consumed — worth pinning the agent and KSM to the **system** node (34% RAM,
plenty of room) via `nodeSelector pyron.io/pool=system`, leaving the workload
node for apps. Alloy, being a DaemonSet, necessarily runs on both.

**✅ Log volume is a non-issue at baseline — the 48h/local-disk call is right.**
Measured over 15 minutes:

| Source | lines/15min | bytes/15min | ≈ /day |
|---|---|---|---|
| frontend | 270 | 14.7 KB | ~1.4 MB |
| webhook | 135 | 9.6 KB | ~0.9 MB |
| metric-tracker | 6 | 0.6 KB | ~57 KB |
| mirror / backend / ingress | 0 | 0 | 0 |

**Total ≈ 2.4 MB/day**, so a 48h window is ~5 MB and even 7d is ~17 MB. Storage
is genuinely irrelevant at idle. The volume concern in Part 2 stands **only for
burn windows** — at 866 req/s the webhook's per-request logging is 3–4 orders of
magnitude above this baseline. So: ship the DaemonSet without volume anxiety, and
keep the level-filtering as a **burn-time** control, not a day-one blocker.

Worth noting the webhook's baseline is almost entirely
`[INFO]: Dynamic webhook health check requested` — health-check noise on a loop.
Dropping that one line pattern at the agent removes most of the idle log volume.

**🚩 Blocker for execution: your kubectl user is not cluster-admin.**
`kubectl auth whoami` → `bash.br@gmail.com`, groups `do-role-name:Modifier`.
Concretely:

- `kubectl get --raw /api/v1/nodes/<node>/proxy/metrics/cadvisor` → **Forbidden**
  (`cannot get resource "nodes/proxy" at the cluster scope`).
- `kubectl auth can-i create clusterrole` → **no**.

Two consequences. First, **cAdvisor could not be verified hands-on** — the
endpoint is standard in the kubelet and the agent will reach it with its own
ServiceAccount (a ServiceAccount's RBAC is independent of yours), so the design
holds; it just isn't empirically confirmed here. Second, and more practically:
the agent needs a **ClusterRole** (`nodes/metrics`, `nodes/proxy`, plus pod/node
list-watch for `kubernetes_sd`), and **you cannot create one with this token**.

So step 2 must go through the **doks-iac Terraform pipeline**, which holds the
cluster-admin credential — not a manual `kubectl apply` from your laptop. That is
the right home for it anyway (it's platform IaC), but it means this work is
gated on a pipeline run, not something to hand-apply while iterating.

Caveat on `auth can-i`: it returned `yes` for `nodes/proxy` while the real call
was denied — DO's `Modifier` role makes the subresource check unreliable. Trust
the actual API call, not `can-i`, when validating this.

**Confirmed unchanged from the study:** ingress NodePort 30254 is live and
correctly wired; there is **no** `monitoring` or ephemeral namespace (the burn
agent is gone, as designed); node IPs `10.0.0.4/10.0.0.5` are in the VPC range
`10.0.0.0/16` and pod IPs are `10.105.x` — exactly the two ranges the firewall
argument depends on.

## Part 1 — Cluster metrics (kube-state-metrics + cAdvisor)

**What each gives, concretely:**

- **cAdvisor** (already in the kubelet, `/metrics/cadvisor`, no install): actual
  CPU/RAM **per pod and per container** — `container_cpu_usage_seconds_total`,
  `container_memory_working_set_bytes`. This is the number the k3s FinOps doc says
  we must measure before committing to consolidation, and today we don't have it.
- **kube-state-metrics** (one small Deployment, ~64–128MB): cluster *state* —
  `kube_pod_container_status_restarts_total`, OOMKilled, Pending, deployment
  replicas desired vs available, HPA current/target.

Together they answer "is a pod restarting", "did it get OOMKilled", "is the HPA
saturated", "what does a webhook pod actually cost in CPU" — none of which the
ingress metrics can express.

**Scrape config (in the agent, not the droplet):** cAdvisor is scraped through the
kubelet with the pod's ServiceAccount token and needs RBAC on `nodes/metrics`;
kube-state-metrics is a plain ClusterIP the agent reaches directly. Both then
remote_write to the droplet on the already-open port.

**Cardinality is the cost risk, not CPU.** cAdvisor emits per-container series; at
the burn's 100+ pods that is a real ingest spike. Mitigations, in order of value:
1. `metric_relabel_configs` dropping `container_network_*`, `container_fs_*` and
   `container_blkio_*` (rarely used, high volume);
2. drop the `id` and `image` labels (long strings, high churn);
3. keep `namespace` restricted to the namespaces we care about.
Without this, a 20-node burn can multiply active series by an order of magnitude
on a droplet whose Prometheus has no retention tuning today.

## Part 2 — Pod logs, economically

**Agent: Grafana Alloy as a DaemonSet** (the supported successor to Promtail,
which is EOL as of Loki 3.x). One pod per node, tails
`/var/log/pods/*`, enriches with `namespace / pod / container / node` from the
k8s API, pushes to the droplet's Loki.

**Why a DaemonSet and not the ephemeral pattern:** logs are most valuable for the
incidents you didn't schedule. The postmortem in doks-iac (a full cluster loss)
is exactly the case where "logs only during burns" produces nothing.

**Loki stays on local filesystem, 48h–7d.** The current
[`loki-config.yaml`](../config/loki-config.yaml) is already filesystem +
boltdb-shipper with a 48h `retention_period`, so **no storage migration is needed
for this phase** — this is the genuinely cheap path. Marginal cost: disk on a
droplet we already pay for.

**But two things must change before pod logs land:**

1. **The firewall does not currently admit the cluster to Loki.** The rule opens
   3100 to `10.1.0.0/16` — the **dead prod VPC**. This is the pre-existing bug the
   old plan flagged and it was never fixed. It needs `10.0.0.0/16` (VPC) **and**
   `10.105.0.0/16` (pod CNI), for exactly the reason documented on the 9090 rule:
   DO does not SNAT pod egress, so packets arrive with the pod IP. A DaemonSet
   pushing to Loki will hit precisely the same timeout that was already debugged
   once on 9090.

2. **Volume control — a burn-time concern, not a day-one one.** At idle the whole
   cluster emits ~2.4 MB/day (measured), so nothing here blocks the rollout. But
   at burn scale (~866 req/s) a webhook logging per request produces on the order
   of GBs per hour. Put the controls in from the start so the burn doesn't have to
   retrofit them; the defense is at the agent, before the network:
   - drop `debug`/`info` from high-volume services during burns, keep `warn`+;
   - namespace allowlist rather than "everything on the node";
   - keep labels **low-cardinality** — `namespace`, `app`, `level`, `node`. Never
     label by `pod` name or request/trace id: in Loki each label combination is a
     separate stream, and pod names churn on every autoscale event. This is the
     single most common way a cheap Loki becomes an expensive, slow Loki;
   - drop the webhook's `Dynamic webhook health check requested` line — it is
     most of the idle volume and carries no diagnostic value.

**Sizing — now measured, not estimated:** staging produces **~2.4 MB/day** of
logs at idle (see [Live verification](#live-verification-2026-08-28)), so a 48h
window is ~5 MB. Disk is a non-concern at baseline; the existing
`DiskAlmostFull` alert remains the guardrail for burn windows, where volume rises
by orders of magnitude.

**Escalation path if 7d proves too short:** switch `storage_config` to the Spaces
bucket (the credentials and `.env` keys already exist, `SPACES_*`) — roughly
$5/mo, no architectural change. That is a config swap, deliberately deferred.

## What we are NOT doing (and why)

- ❌ **No kube-prometheus-stack / Prometheus operator in the cluster.** Unchanged
  from the original plan — a second Prometheus + CRDs + operator is overkill, and
  the cluster monitoring itself dies with the cluster.
- ❌ **No new NodePort scrape jobs.** Superseded by the agent; see the
  multi-replica failure above.
- ❌ **No Spaces/object storage for Loki in this phase.** Explicitly deferred.
- ❌ **Hubble/Cilium NodePorts (steps 2 of the old plan): dropped from scope.**
  L7 network metrics are interesting but they don't answer a question we currently
  have, and the ingress already covers request-level traffic. If they come back,
  they come back through the agent, not a NodePort.

## Execution order

**Both sides are live** — the DOKS staging cluster and this monitoring stack are
up and serving. So none of this is a greenfield build: every step lands on
running infrastructure and is written to be applied without an outage.

Two consequences worth stating explicitly:

- **Step 1 changes a firewall on a live droplet.** It only *widens* inbound 3100
  from a dead VPC range to the live one — it removes no access that anything is
  currently using (nothing can be reaching Loki from `10.1.0.0/16`; that VPC is
  gone), so the blast radius is effectively nil.
- **Prometheus config changes do not need a restart.** The pipeline already
  POSTs `/-/reload` (`--web.enable-lifecycle` is set in the compose), so step 3
  applies with zero scrape gap. Do not restart the container to pick up config.

Each step is independently verifiable; nothing here is a big-bang.

1. **monitoring-stack** — fix the Loki firewall rule (`10.1.0.0/16` →
   `10.0.0.0/16` + `10.105.0.0/16`) in [`terraform/main.tf`](../terraform/main.tf).
   Standalone bugfix, worth shipping on its own regardless of the rest.
2. **doks-iac platform** — deploy kube-state-metrics + a permanent
   `monitoring` namespace with the prometheus-agent (RBAC, kubelet/cAdvisor +
   KSM + ingress scrape, remote_write to `10.0.0.2:9090`, with the cardinality
   drops in place from the first apply). **Must run through the pipeline** — the
   ClusterRole this needs cannot be created with the `Modifier` token on a
   laptop (see Live verification).
3. **monitoring-stack** — verify the new series arrive; retire the commented-out
   `webhook-app` NodePort job and its now-stale comment.
4. **Grafana** — a "Cluster / Resources" dashboard: CPU & RAM per namespace and
   per pod, restarts, OOMKills, pending pods, HPA saturation.
5. **doks-iac platform** — Alloy DaemonSet with the namespace allowlist and
   low-cardinality labels; push to `10.0.0.2:3100`.
6. **Grafana** — logs panels, and wire log context onto the existing ingress and
   burn dashboards (click a latency spike → the logs for that window).
7. **Alerts** — extend [`basic-alerts.yml`](../config/rules/basic-alerts.yml)
   beyond the current node-level rules: CrashLoopBackOff, OOMKilled, pods Pending
   > 5m. Today an app dying inside the cluster raises nothing.

## Open questions worth deciding before step 2

- **Prometheus retention on the droplet is unset** (defaults to 15d, no size cap).
  Adding cAdvisor cardinality without a `--storage.tsdb.retention.size` bound is
  how the disk fills quietly. Recommend setting an explicit size limit in the
  same change.
- **Does this extend to production?** The whole path assumes the shared staging
  VPC (`10.0.0.0/16`) and one monitoring droplet. Prod is a separate VPC and the
  doc should not be read as prod-ready without redoing the network step.
- **The agent is a SPOF for push metrics.** One replica means a gap in the series
  if it's evicted. Acceptable for staging; worth an explicit decision for prod.
