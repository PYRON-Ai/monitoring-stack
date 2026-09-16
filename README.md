# Pyron Monitor Stack

Metrics, logs and alerting for the Pyron platform, running with `docker compose`
on a DigitalOcean droplet and deployed from GitHub Actions.

**It runs OUTSIDE the Kubernetes cluster it watches, on purpose.** A cluster that
monitors itself dies with the cluster — so storage, dashboards and alerting live
here, and the cluster only ships data out.

```
   DOKS cluster                          monitoring droplet (10.0.0.2)
   ┌──────────────────────┐              ┌─────────────────────────────┐
   │ prometheus-agent ────┼──remote_write┼─→ Prometheus :9090          │
   │   (cAdvisor, KSM,    │              │      ↓                      │
   │    ingress-nginx)    │              │   Grafana ← Alertmanager    │
   │                      │              │      ↑                      │
   │ Alloy ───────────────┼──push────────┼─→ Loki :3100                │
   └──────────────────────┘              │                             │
                                         │ node-exporter, promtail     │
        Cloudflare Access                │      (the droplet itself)   │
              ↓                          └─────────────────────────────┘
        cloudflared (systemd unit on the droplet) ─→ Grafana
```

The collection side lives in [`pyron-doks-iac`](https://github.com/PYRON-Ai/pyron-doks-iac)
(`terraform/platform`). This repo is the receiving side.

## What runs here

| Service | Port | Role |
|---|---|---|
| **Prometheus** | 9090 | Scrapes the droplet, and **receives** cluster metrics by remote_write. TSDB bounded to 15d / 20GB. |
| **Grafana** | *(none)* | Dashboards. Deliberately publishes no host port — see [Access](#access). |
| **Loki** | 3100 | Log store. Local filesystem, 48h retention. |
| **Alertmanager** | 9093 | Alert routing. Staging uses a **null receiver** on purpose: alerts fire and are visible, but page nobody. |
| **promtail** | — | Ships the droplet's own container logs to Loki. |
| **node-exporter** | 9100 | Host metrics for the droplet. |

`cloudflared` is **not** in the compose file — it is a systemd unit on the
droplet. See [Access](#access).

> `config/tempo-config.yaml` is left over from a Tempo deployment that no longer
> exists. Nothing references it; tracing is not currently part of this stack.

## Access

Grafana has no published port. Two ways in, covered fully in
[`docs/access.md`](docs/access.md):

- **Day-to-day** — `https://monitoring-stage.pyron-ai.com`, behind Cloudflare
  Access (one-time PIN by email), then Grafana's own login.
- **Break-glass** — SSH port-forward, which depends on nothing but SSH:
  ```sh
  ssh -L 3000:172.28.0.20:3000 <user>@<droplet-ip>
  ```
  `172.28.0.20` is Grafana's pinned address on the compose bridge. Not
  `localhost` (nothing publishes 3000) and not `grafana` (sshd cannot resolve
  container names).

## Dashboards

Provisioned from `grafana/provisioning/dashboards/`, so they are versioned rather
than hand-made in the UI:

| Dashboard | For | Answers |
|---|---|---|
| **Environment Health** | anyone | Is anything broken, what is closest to its limit, is traffic flowing |
| **Service View** | developers | Per-service: what callers experience, pod resources, and that service's logs |
| **Ingress / Traffic Overview** | — | Request rate, latency and status per service |
| **Load Test / Burn** | — | Throughput and queue depth during stress tests |

Service View is built entirely from the ingress and the container runtime: it can
say a request was slow or failed, but **not which handler or query caused it**.
That needs application instrumentation.

## Alerting

Rules in `config/rules/`. `basic-alerts.yml` covers the droplet (CPU, memory,
disk, targets down); `cluster-alerts.yml` covers the cluster (crashloops,
OOMKills, pods stuck Pending, missing replicas, and a watchdog for the in-cluster
agent going silent).

**Staging routes everything to a null receiver.** Alerts fire and are visible in
Alertmanager and Grafana, but notify nobody — staging is where things break on
purpose, and paging on that trains people to ignore alerts. Telegram is a
production decision.

## Configuration

| Path | What |
|---|---|
| `docker-compose.yml` | Service graph, volumes, the fixed `172.28.0.0/16` bridge |
| `config/prometheus.yaml` | Scrape jobs + Alertmanager wiring |
| `config/loki-config.yaml` | Loki storage and retention |
| `config/promtail-config.yaml` | Droplet log collection |
| `config/rules/` | Alert rules |
| `grafana/provisioning/` | Datasources and dashboards |
| `alertmanager/config.yml` | Routing (null receiver in staging) |
| `terraform/` | Droplet, firewall, Spaces state backend |

## Environment

The droplet's `.env` is written wholesale from the `MONITOR_ENV_STAGING` secret.
Only four keys are read — see [`.env.example`](.env.example):

```
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=<a real password>
GF_USERS_ALLOW_SIGN_UP=false
GF_AUTH_ANONYMOUS_ENABLED=false
```

⚠️ **Set the admin password here, not only in Grafana's UI.** If it exists only
in the container's database, `docker compose down -v` loses it with no record
anywhere. The deploy job warns when these keys are missing.

`SPACES_*` and `ALERT_WEBHOOK_URL` appear in older docs but nothing reads them:
Loki is on local filesystem and staging's Alertmanager has no webhook.

## Local development

```sh
cp .env.example .env     # fill in a password
docker compose pull
docker compose up -d
```

Grafana publishes no port, so reach it on the bridge address
(`docker compose port` will not help). For local work it is simplest to add a
temporary `ports:` mapping — just do not commit it, since removing that port is
what keeps Grafana off the public internet.

Prometheus `:9090`, Loki `:3100` and Alertmanager `:9093` are reachable normally.

## Deployment

Push to `stage` runs `.github/workflows/stage-deploy.yml`:

1. **infra** — `terraform apply` for the droplet and firewall
2. **bootstrap** — Docker + fail2ban on a fresh droplet
3. **deploy** — rsync the repo, write `.env` from the secret, `docker compose up -d`,
   then `POST /-/reload` so Prometheus picks up config changes with no scrape gap

### Required secrets

| Secret | For |
|---|---|
| `DO_TOKEN_STAGING` | Terraform: droplet, firewall |
| `DO_SPACES_ACCESS_KEY_ID` / `DO_SPACES_SECRET_ACCESS_KEY` | Terraform state backend |
| `DO_SSH_FINGERPRINT_STAGING` | SSH key registered in DigitalOcean |
| `DO_DEPLOY_SSH_KEY` | Private key the pipeline deploys with |
| `DO_DEPLOY_USER_STAGING` / `DO_DEPLOY_PATH_STAGING` | Where to deploy |
| `MONITOR_ENV_STAGING` | The droplet's `.env`, verbatim |

The Cloudflare tunnel token is **not** here — cloudflared reads it from
`/etc/cloudflared/token` on the droplet (root-only), so it never passes through
the pipeline.

## Operating

```sh
# on the droplet
docker compose ps
docker compose logs -f grafana

# is the cluster still shipping metrics?
curl -s localhost:9090/api/v1/query --data-urlencode 'query=up' | jq '.data.result | length'

# is the tunnel connected?
systemctl status cloudflared
```

- **Reset the Grafana admin password:**
  ```sh
  docker exec <grafana-container> grafana-cli --homepath /usr/share/grafana \
    admin reset-admin-password '<new>'
  ```
  If login still fails afterwards with *"too many consecutive incorrect login
  attempts"*, the block is stored in Grafana's database and a restart will not
  clear it — delete from the `login_attempt` table.
- **Avoid `docker compose down --volumes`** unless you mean to lose metric
  history, log history and every Grafana setting made through the UI.

## Docs

- [`docs/access.md`](docs/access.md) — how people get in, and how it is set up
- [`docs/cluster-metrics-logs-study.md`](docs/cluster-metrics-logs-study.md) — why the cluster ships data out rather than monitoring itself
- [`docs/k3s-migration-tradeoff.md`](docs/k3s-migration-tradeoff.md) — the FinOps case for the k8s migration
