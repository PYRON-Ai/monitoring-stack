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

> **Staging only, for now.** The monitoring stack was born in production — it was
> the v1 Pyron stack — and what tied it to prod was the targets it scraped, the
> VPC it sat in and the prod resources it referenced, not the workflow file. When
> the platform moved to Kubernetes and staging, those references went with it.
>
> `.github/workflows/prod-deploy.yml.old` survives from that era **only on
> `main`** (76+ commits behind `stage`), and its name no longer matches its
> contents: it triggers on pushes to `stage`, reads `*_STAGING` secrets, and is
> still titled "Stage Deploy" internally. Dropping the `.old` would redeploy
> staging, not deploy production. `terraform/prod.tfvars` is empty for the same
> reason.
>
> Production monitoring goes up when the production platform does, following the
> same shape as `pyron-doks-iac`: **merging to `main` deploys nothing.**

Push to `stage` runs `.github/workflows/stage-deploy.yml`:

1. **infra** — `terraform apply` for the droplet and firewall
2. **bootstrap** — Docker + fail2ban on a fresh droplet
3. **deploy** — rsync the repo, write `.env` from the secret, `docker compose up -d`,
   then `POST /-/reload` so Prometheus picks up config changes with no scrape gap

### When production comes back

The target shape mirrors `pyron-doks-iac`, whose gates were written after an
auto-applied merge destroyed staging (postmortem 2026-08-14). The rule that
matters: **merging to `main` deploys nothing.**

| Workflow | Trigger | Does |
|---|---|---|
| `prod-ci.yml` | PR → `main` | validate + `terraform plan`, commented on the PR |
| `prod-deploy.yml` | **manual dispatch only** | apply, behind a typed confirmation |

Three gates, no more: branch protection on `main` (review), manual dispatch (a
merge never applies), and a `confirm` input that must read `DEPLOY` before the
job proceeds. Deliberately **no destroy option** — tearing prod down should not
be one dropdown away from a routine deploy.

**Why this split is worth the extra step.** Separating merge from apply makes
`main` the *approved* state rather than the *applied* one, and those are two
different events with different owners and different clocks:

- **Deploys can be scheduled.** Changes are reviewed and merged during working
  hours; the apply waits for a maintenance window. With auto-deploy the two are
  the same instant, so the window's constraint lands on review instead — nobody
  merges at 17:00 on a Friday, and good changes sit around for the wrong reason.
- **Release can be governed separately from code review.** Approving *what*
  changes and authorising *when* it lands are distinct decisions, and often
  distinct people. A manual dispatch is a hook anything can pull: a scheduled
  window, or an external approval system calling `gh workflow run`.
- **What was reviewed is what runs.** The doks job applies a saved plan, so an
  apply hours after the review does not silently re-plan against drifted state.

**The other ordering, worth knowing.** Larger shops often invert it: deploy from
the release branch inside the approved window first, and merge to `main` only
once the deploy succeeded. `main` then means *"this ran in production and
worked"* rather than *"this was approved to run"*.

That is the stronger guarantee, and it closes a real gap in the order above: here,
if an apply fails, `main` already contains code that never worked in production,
and the next person branches from a lie. Inverted, `main` can never be ahead of
reality.

It costs more machinery — the deploy has to run from somewhere other than `main`,
and a failed deploy leaves a branch needing a decision. Worth it when an external
system (ServiceNow and the like) owns the window and the merge is the audit
record that the change landed.

**It also suits infrastructure better than applications**, for two reasons that
do not apply equally:

- **Rollback cost.** Reverting an app is swapping back to an image that still
  exists — seconds, and the state returns to what it was. Reverting infrastructure
  is a *new apply* that can fail for reasons the first one did not: a destroyed
  resource does not come back with `git revert`. The doks postmortem is the
  example — a cluster was destroyed and the recreate then failed on an invalid
  version slug, leaving the environment with nothing. Where rollback is cheap,
  merging early costs little; where it is expensive, you want `main` to record
  only what survived.
- **Frequency.** Apps deploy many times a day, and deploy-then-merge turns into
  standing friction: branches pending, merges queued, `main` permanently behind
  what is running. Infrastructure deploys rarely, so the ceremony per event is
  diluted.

So the trade is not one-size: infra repos can afford the stricter ordering and
benefit most from it, while app repos usually want merge-first and cheap
rollback. For a team this size the simpler order is fine here too — but the
choice is really about what you want `main` to *mean*, and how much it costs to
be wrong.

One caveat, since it is easy to over-read the split above: regulated shops often
apply the strict ordering to *everything* — apps, infra, roles, the lot — and
they are not being careless about the trade. Uniformity is itself the goal there,
because the question being answered is "can you show an auditor that every change
went through the same door?", and each per-type exception is one more thing to
justify. They can also afford it: there is a release function, tooling that owns
the calendar, people whose job is to run it, so the friction is absorbed by
structure rather than landing on whoever was writing code. And the cost of a bad
deploy is a regulatory incident, not a rollback. Rigour scales with the cost of
being wrong, not with principle.

What has to exist before any of that is useful:

- `terraform/prod.tfvars` — currently empty
- Prod-side secrets — `DO_TOKEN_PRODUCTION`, `DO_DEPLOY_*_PRODUCTION`,
  `MONITOR_ENV_PRODUCTION`
- Scrape targets and a VPC path to whatever prod runs — the part that actually
  made the old pipeline "production", and the part that does not exist yet
- An Alertmanager config that pages: see `alertmanager/config.yml` for the three
  things missing there (no prod config file, dead bot token, and Alertmanager not
  expanding env vars)

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
