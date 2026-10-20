# Pyron Monitor Stack

[![Feature CI](https://github.com/PYRON-Ai/monitoring-stack/actions/workflows/feature-ci.yml/badge.svg)](https://github.com/PYRON-Ai/monitoring-stack/actions/workflows/feature-ci.yml)
[![Deploy Stack](https://github.com/PYRON-Ai/monitoring-stack/actions/workflows/stage-deploy.yml/badge.svg)](https://github.com/PYRON-Ai/monitoring-stack/actions/workflows/stage-deploy.yml)

[![Prod CI & PR](https://github.com/PYRON-Ai/monitoring-stack/actions/workflows/prod-ci.yml/badge.svg)](https://github.com/PYRON-Ai/monitoring-stack/actions/workflows/prod-ci.yml)
[![Deploy Stack (PRODUCTION)](https://github.com/PYRON-Ai/monitoring-stack/actions/workflows/prod-deploy.yml/badge.svg)](https://github.com/PYRON-Ai/monitoring-stack/actions/workflows/prod-deploy.yml)

Metrics, logs and alerting for the Pyron platform, running with `docker compose`
on a DigitalOcean droplet and deployed from GitHub Actions.

**It runs OUTSIDE the Kubernetes cluster it watches, on purpose.** A cluster that
monitors itself dies with the cluster — so storage, dashboards and alerting live
here, and the cluster only ships data out.

```
   DOKS cluster                          monitoring droplet
   ┌──────────────────────┐              ┌─────────────────────────────┐
   │ prometheus-agent ────┼──remote_write┼─→ Prometheus :9090          │
   │   (cAdvisor, KSM,    │              │      ↓                      │
   │    ingress-nginx)    │              │   Grafana ← Alertmanager    │
   │                      │              │      ↑              ↓       │
   │ Alloy ───────────────┼──push────────┼─→ Loki :3100    Telegram    │
   └──────────────────────┘              │                 (prod only) │
                                         │ node-exporter, promtail     │
        Cloudflare Access                │      (the droplet itself)   │
              ↓                          └─────────────────────────────┘
        cloudflared (systemd unit on the droplet) ─→ Grafana
```

The collection side lives in [`pyron-doks-iac`](https://github.com/PYRON-Ai/pyron-doks-iac)
(`terraform/platform`). This repo is the receiving side.

> **Status:** staging is **live**. Production has its own isolated pipeline,
> state and firewall (`terraform/prod.tfvars`, `production/terraform.tfstate`),
> deployed by **manual dispatch** — never by a merge. The cluster-ingest firewall
> (9090 remote_write, 3100 Loki push) is open per-environment to each cluster's
> own VPC + CNI ranges.

## What runs here

| Service | Port | Role |
|---|---|---|
| **Prometheus** | 9090 | Scrapes the droplet, and **receives** cluster metrics by remote_write. TSDB bounded to 30d / 20GB. `--web.enable-lifecycle` (reload) is on. |
| **Grafana** | *(none)* | Dashboards. Deliberately publishes no host port — see [Access](#access). |
| **Loki** | 3100 | Log store. Local filesystem, 7d retention. |
| **Alertmanager** | 9093 | Alert routing. **Staging = null receiver** on purpose; **production pages critical alerts to Telegram** — see [Alerting](#alerting). |
| **promtail** | — | Ships the droplet's own container logs to Loki. |
| **node-exporter** | *(none)* | Host metrics for the droplet. Scraped over the compose bridge; no public port. |

`cloudflared` is **not** in the compose file — it is a systemd unit on the
droplet. See [Access](#access).

## Access

Grafana has no published port. Two ways in, covered fully in
[`docs/access.md`](docs/access.md):

- **Day-to-day** — behind Cloudflare Access (one-time PIN by email), then
  Grafana's own login.
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
| **Container Saturation (cAdvisor)** | ops | The per-container signals the others miss: CPU throttling, usage vs limit, PSI (cpu/mem/io), FD/thread leaks |
| **Load Test / Burn** | — | Throughput and queue depth during stress tests |

Service View is built entirely from the ingress and the container runtime: it can
say a request was slow or failed, but **not which handler or query caused it**.
That needs application instrumentation.

## Alerting

Rules in `config/rules/`:

| File | Covers |
|---|---|
| `basic-alerts.yml` | The droplet itself — CPU, memory, disk, inodes, targets down |
| `cluster-alerts.yml` | Cluster state (kube-state-metrics) — crashloops, OOMKills, pods stuck Pending, missing replicas, and a watchdog for the agent going silent |
| `container-saturation.yml` | Per-container saturation (cAdvisor) — CPU throttling, CPU-vs-limit, memory/IO pressure (PSI), and FD/thread-leak detection by relative growth |

**Routing is per-environment, and that split is deliberate.** The Alertmanager
config is a **deploy artifact** (`alertmanager/config.yml`, gitignored): the
pipeline copies the versioned `alertmanager/config.<env>.yml` onto it on the
droplet.

- **Staging → null receiver.** Alerts fire and are visible in Alertmanager and
  Grafana, but notify nobody. Staging is where things break on purpose, and
  paging on that trains people to ignore alerts.
- **Production → Telegram for `severity=critical`.** Warnings currently route to
  null too; tuned warning paging is a separate, deliberate pass.

The Telegram `chat_id` is a **bare integer literal** in `config.prod.yml`, never
quoted and never substituted — Alertmanager types it as a Go `int64`, so a quoted
or envsubst'd value fails the boot parse (`cannot unmarshal !!str into int64`).
Only the bot token (a real secret) is injected, via `bot_token_file`, written on
the droplet from the `TELEGRAM_BOT_TOKEN_PRODUCTION` secret (mode 0600,
gitignored).

## Configuration

| Path | What |
|---|---|
| `docker-compose.yml` | Service graph, volumes, the fixed `172.28.0.0/16` bridge |
| `config/prometheus.yaml` | Scrape jobs + Alertmanager wiring |
| `config/loki-config.yaml` | Loki storage and retention |
| `config/promtail-config.yaml` | Droplet log collection |
| `config/rules/` | Alert rules (see [Alerting](#alerting)) |
| `grafana/provisioning/` | Datasources and dashboards |
| `alertmanager/config.stage.yml` | Staging routing (null receiver) |
| `alertmanager/config.prod.yml` | Production routing (Telegram, critical) |
| `terraform/` | Droplet, per-environment firewall, Spaces state backend |

## Environment

The droplet's `.env` is written wholesale from the `MONITOR_ENV_<ENV>` secret.
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
Locally the compose expects `alertmanager/config.yml` to exist — copy one of the
per-environment files onto it first (`cp alertmanager/config.stage.yml
alertmanager/config.yml` and `touch alertmanager/bot_token`), since that file is
a deploy artifact and gitignored.

## Deployment

Two **distinct** pipelines — staging and production — with separate tfvars,
state keys and firewalls. Code flows `feature/* → stage → main`, and a stage
deploy opens the `stage → main` promotion PR automatically.

| | Staging | Production |
|---|---|---|
| Validate | `feature-ci` (push `feature/*`) | `prod-ci` (PR → `main`) |
| Config | `stage.tfvars` | `prod.tfvars` |
| State | `staging/terraform.tfstate` | `production/terraform.tfstate` |
| Deploy | `stage-deploy` (**auto** on push to `stage`) | `prod-deploy` (**manual dispatch**, typed `DEPLOY` confirm) |
| Alertmanager | null receiver | Telegram (critical) |

**Merging to `main` deploys nothing.** Production goes out only when a human runs
the `prod-deploy` workflow and types `DEPLOY`. There is **no destroy option** in
the prod workflow — tearing prod down must not be one dropdown away from a routine
deploy. These gates mirror `pyron-doks-iac`, whose rules were written after an
auto-applied merge destroyed staging (postmortem 2026-08-14).

A stage deploy runs, in order:

1. **infra** — `terraform apply` for the droplet and per-environment firewall
   (falls through to a `terraform destroy` path only when `destroy=true` in the
   tfvars — staging only)
2. **bootstrap** — Docker + fail2ban on a fresh droplet
3. **deploy** — rsync the repo, select the environment's Alertmanager config,
   write `.env` from the secret, `docker compose up -d`, then recreate Prometheus
   if its config changed on disk (a single-file bind mount that `/-/reload` alone
   cannot pick up) or `POST /-/reload` otherwise.

The prod deploy adds a `confirm` gate and applies a **saved plan**, so an apply
hours after review does not silently re-plan against drifted state.

> **Why separate merge from apply?** It makes `main` the *approved* state rather
> than the *applied* one — two events with different owners and clocks. Deploys
> can be scheduled into a maintenance window without holding up review; release
> can be governed separately from code review; and what was reviewed is what runs
> (the saved plan). The stricter inversion some shops use — deploy first, merge
> only on success, so `main` means "this ran and worked" — is a stronger guarantee
> but costs more machinery, and suits infra (expensive, rare rollbacks) more than
> apps (cheap, frequent). For a team this size the simpler order is fine; the real
> question is what you want `main` to *mean*, and how much it costs to be wrong.

### Required secrets

Per environment (`_STAGING` / `_PRODUCTION`):

| Secret | For |
|---|---|
| `DO_TOKEN_<ENV>` | Terraform: droplet, firewall |
| `DO_SSH_FINGERPRINT_<ENV>` | SSH key registered in DigitalOcean |
| `DO_DEPLOY_USER_<ENV>` / `DO_DEPLOY_PATH_<ENV>` | Where to deploy |
| `MONITOR_ENV_<ENV>` | The droplet's `.env`, verbatim |
| `TELEGRAM_BOT_TOKEN_PRODUCTION` | Telegram bot token (prod only; written to `bot_token`) |

Shared:

| Secret | For |
|---|---|
| `DO_SPACES_ACCESS_KEY_ID` / `DO_SPACES_SECRET_ACCESS_KEY` | Terraform state backend |
| `DO_DEPLOY_SSH_KEY` | Private key the pipeline deploys with |

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
- **Data lives in `./data` on the droplet**, as bind mounts rather than named
  volumes. `docker compose down --volumes` therefore cannot delete it — Docker
  only removes volumes it owns. Backing up the stack means copying that one
  directory; `data/grafana/grafana.db` is the part that is not reproducible from
  this repo, since it holds users, the admin password and anything changed
  through the UI.
- **There is no backup yet.** Nothing copies `./data` anywhere off the droplet,
  so a lost droplet is still a lost history. The bind mount removes the easy
  accident, not the single point of failure.

## Docs

- [`docs/access.md`](docs/access.md) — how people get in, and how it is set up
- [`docs/cluster-metrics-logs-study.md`](docs/cluster-metrics-logs-study.md) — why the cluster ships data out rather than monitoring itself
- [`docs/k3s-migration-tradeoff.md`](docs/k3s-migration-tradeoff.md) — the FinOps case for the k8s migration
