# Plugging the DOKS cluster into the (droplet) monitoring stack

> Status: **Design / blueprint** — no execution yet. The plan to scrape cluster
> metrics from the external Prometheus (on the monitoring droplet), without
> installing a second Prometheus inside the cluster.
> Date: 2026-07-13

## The constraint (why it's not trivial)

Prometheus runs on the monitoring droplet (`10.0.0.2`), OUTSIDE the cluster — by
design (a cluster monitoring itself dies with the cluster). The cluster's metric
endpoints are **ClusterIP** (`10.104.x`), which only exist INSIDE the cluster.
So even on the same VPC, Prometheus can't hit a ClusterIP directly.

**Network facts (verified 2026-07-13):**
- Monitoring droplet: `10.0.0.2` (VPC `pyron-vpc-staging` 4ba63b32…)
- Cluster node `system-3ck0td`: InternalIP **`10.0.0.4`** (SAME VPC) + public 152.42.248.50
- → The droplet CAN reach the node at `10.0.0.4` over the VPC.
- → A **NodePort** Service is reachable at `10.0.0.4:<nodePort>` from the droplet.
- ClusterIP (`10.104.x`) is NOT reachable from outside → NodePort is the bridge.

## What each addon emits (mapped, not guessed)

| Source | Metric | State | Port (ClusterIP) |
|---|---|---|---|
| **metrics-server** | node/pod CPU+RAM | ✅ working (`kubectl top`: 8% CPU / 67% RAM) | 443 (metrics-API, not Prometheus format) |
| **Hubble** | L7 network: dns, http(V2), tcp, drops, flows | ✅ **ALREADY enabled** | `hubble-metrics:9965` |
| **Cilium** | CNI metrics | ✅ **ALREADY enabled** (`prometheus-serve-addr :9090`) | `cilium-agent:9964` |
| **ingress-nginx** | **req/s, latency, status per service** (the "graph over time" Tom wants) | ❌ **OFF** — our default (we never set metrics.enabled) | 10254 |

Key realization: **we installed the ingress**, so `--enable-metrics=false` is OUR
config default, not an external mystery. Turning it on is one line in our IaC.

## The plan (all our IaC, no Prometheus-in-cluster)

### Step 1 — Turn ON ingress metrics (terraform/platform, doks-iac)
Add to the `ingress_nginx` helm_release:
```
set { name = "controller.metrics.enabled"          value = "true" }
set { name = "controller.metrics.service.type"     value = "NodePort" }
set { name = "controller.metrics.service.nodePort" value = "30254" }   # fixed target
```
→ ingress starts emitting req/s + latency + status per service, exposed at
`10.0.0.4:30254`. This is the biggest win: the load "graph over time" WITHOUT
touching app code (all traffic passes through the ingress, so it measures it).

### Step 2 — Expose Hubble + Cilium via NodePort (k8s manifests, doks-iac platform)
They already emit; just need a NodePort each so the droplet can scrape:
```
hubble-metrics  → NodePort 30965  (10.0.0.4:30965)
cilium-agent    → NodePort 30964  (10.0.0.4:30964)
```
(Or a single small NodePort Service per target. Headless ClusterIPs can't be
NodePort'd directly — front them with a plain Service selecting the same pods.)

### Step 3 — Point the droplet Prometheus at the node (monitoring-stack)
Add scrape jobs to `config/prometheus.yaml`:
```yaml
  - job_name: 'ingress-nginx'
    static_configs: [{ targets: ['10.0.0.4:30254'] }]
  - job_name: 'hubble'
    static_configs: [{ targets: ['10.0.0.4:30965'] }]
  - job_name: 'cilium'
    static_configs: [{ targets: ['10.0.0.4:30964'] }]
```
⚠️ `10.0.0.4` is a single node IP. Under autoscaling the node set changes, but the
NodePort answers on EVERY node, and 10.0.0.4 is the fixed system node (min pool),
so it's a stable target for staging. (For robustness later: k8s SD or a small
list of node IPs.)

### Step 4 — Firewall (doks-iac cluster + monitoring terraform)
- The cluster node firewall must allow inbound `30254/30965/30964` from the
  monitoring droplet's VPC IP (`10.0.0.2` or `10.0.0.0/16`).
- Also fix the pre-existing bug: the monitoring droplet's Loki firewall rule
  allows `10.1.0.0/16` (dead prod VPC) — should be `10.0.0.0/16` (staging VPC).

### metrics-server (CPU/RAM) — separate track
metrics-server speaks the k8s metrics API, not Prometheus. Options:
- Add **kube-state-metrics** (1 light deployment) for cluster STATE (pods,
  deploys, HPA) in Prometheus format → NodePort → scrape. OR
- Leave CPU/RAM to `kubectl top` / the DO panel for now.
(Not blocking — Hubble already gives network load; ingress gives request load.)

## What we DON'T do
- ❌ No kube-prometheus-stack / Prometheus operator in the cluster (the trambolho
  Andre vetoed — a second Prometheus + CRDs + operator is overkill).
- ❌ No DO exporter (dead since 2020, no DOKS collector).

## Execution order (once validated)
1. terraform/platform: ingress metrics ON + NodePort → apply (doks-iac pipeline).
2. Manifests: NodePort Services for hubble/cilium → apply.
3. Cluster node firewall: allow the NodePorts from the droplet.
4. monitoring-stack: add the 3 scrape jobs to prometheus.yaml → deploy.
5. Grafana: build dashboards on the new datasource metrics.
6. (later) kube-state-metrics for cluster state; app-level /metrics = phase 2.
