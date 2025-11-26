# Pyron Monitor Stack

A comprehensive monitoring and observability stack based on Prometheus, Grafana, Loki, Tempo, Alertmanager, Promtail, and Node Exporter. It is orchestrated with `docker compose` and ready for automated deployment through GitHub Actions to a DigitalOcean droplet.

## Architecture
- **Prometheus** scrapes targets declared in `config/prometheus.yaml`, covering internal services along with MongoDB and team applications.
- **Grafana** loads preconfigured dashboards and attaches to Prometheus, Loki, and Tempo via provisioning.
- **Loki + Promtail** send logs to DigitalOcean Spaces for durable retention.
- **Tempo** collects distributed traces with a local store that can be extended to S3/Spaces if necessary.
- **Alertmanager** routes alerts to a configurable webhook receiver.
- **Node Exporter** exposes the droplet’s host metrics so the infrastructure becomes observable.

## Configuration
- `docker-compose.yml`: defines the full service graph, persistent volumes, and restart policies.
- `config/prometheus.yaml`: lists scrape jobs and integrates Prometheus with Alertmanager.
- `config/loki-config.yaml` + `config/promtail-config.yaml`: point to the Spaces bucket specified via environment variables.
- `config/tempo-config.yaml`: configures Tempo receivers, storage, and limits.
- `grafana/provisioning`: automatically loads Prometheus, Loki, and Tempo datasources.
- `alertmanager/config.yml`: declares the default receiver and points Alertmanager at `ALERT_WEBHOOK_URL`.

## Environment variables (populate `.env`, never commit)
Copy `.env.example` and fill in sensitive values. Key environment variables are:
- `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD`: Grafana admin credentials.
- `GF_USERS_ALLOW_SIGN_UP` / `GF_AUTH_ANONYMOUS_ENABLED`: control default access.
- `SPACES_KEY`, `SPACES_SECRET`, `SPACES_BUCKET`, `SPACES_PREFIX`, `SPACES_REGION`, `SPACES_ENDPOINT`: DigitalOcean Spaces credentials used by Loki (and optionally Tempo).
- `ALERT_WEBHOOK_URL`: optional destination for Alertmanager notifications (Slack, Mattermost, internal collector, etc.).

## Local development

1. Duplicate `.env.example` as `.env` and populate real values.
2. Run `docker compose pull` and `docker compose up -d`.
3. Access the services:
   - Grafana: `http://localhost:3000`
   - Prometheus: `http://localhost:9090`
   - Loki: `http://localhost:3100`
   - Tempo: `http://localhost:3200`
4. Customize dashboards by adding JSON files into `grafana/provisioning` and restarting Grafana.

## DigitalOcean deployment

1. **Droplet**: provision Ubuntu 24.04 with Docker Engine and Docker Compose v2. Open TCP ports 3000, 9090, 3100, 3200, 9100, and 9093 and apply firewall rules (ufw or DigitalOcean Cloud Firewall).
2. **Volumes**: create persistent directories (typically `/opt/pyron-monitor-stack`) and set proper permissions for Docker.
3. **Spaces**: configure an S3-compatible bucket so Loki can store indexes and chunks; reuse those credentials inside the droplet’s `.env`.
4. **Remote `.env`**: keep this file out of git. The GitHub Actions workflow overwrites it automatically (see below), but manual maintenance also works.
5. **Initial run**:
   ```sh
   cd /opt/pyron-monitor-stack
   docker compose pull
   docker compose up -d
   ```
6. **Node monitoring**: `node-exporter` maps `/proc`, `/sys`, and `/` for host telemetry. Ensure the Docker user (usually root) has read access to those paths.

## Terraform provisioning

Terraform runs as the first job (`infra-staging` / `infra-production`) in the GitHub Actions pipeline, but you can still execute it locally with the same variables:

1. Edit the tracked `terraform/stage.tfvars` and `terraform/prod.tfvars` to set the bucket suffix, droplet name/size, and any other per-environment overrides. Secrets such as `do_token` and `ssh_key_fingerprint` continue to be supplied via the pipeline.
2. Run `terraform init` followed by `terraform plan -var-file=terraform/<env>.tfvars` to inspect the planned output for each environment (replace `<env>` with `stage` or `prod`).
3. Apply with `terraform apply -var-file=terraform/<env>.tfvars`. The results include:
   - `droplet_ip`: the public IP that the deploy job consumes, so you do not have to hardcode `DO_DEPLOY_HOST`.
   - `spaces_bucket_*`: the bucket metadata used by Loki (and optionally other tooling).
4. Environments are isolated via Terraform workspaces (`staging` / `production`), and the firewall rules match the ports exposed in `docker-compose.yml`, so the droplet is ready as soon as Docker is installed.

## GitHub Actions deployment

The workflow now runs five jobs across the branches:

1. `ci-check`: executes on pushes to `feature/**` and on pull requests targeting `stage`. It validates `docker compose` and checks `terraform fmt`.
2. `infra-staging` / `infra-production`: trigger on pushes to `stage` and `main`, respectively. Each job sets up Terraform, selects the proper workspace, and runs `terraform apply -var-file=terraform/<env>.tfvars -auto-approve` (where `<env>` is `stage`/`prod`), then exports the droplet IP for the deploy job.
3. `deploy-staging` / `deploy-production`: wait on the matching Terraform job, rsync the repo (excluding `.git` and `.env`), optionally rewrite the environment file, and run `docker compose pull && docker compose up -d --remove-orphans`.

### Required GitHub secrets
- `DO_TOKEN_STAGING` / `DO_TOKEN_PRODUCTION`: DigitalOcean API tokens with rights to manage droplets, firewalls, and Spaces.
- `DO_SSH_FINGERPRINT_STAGING` / `DO_SSH_FINGERPRINT_PRODUCTION`: fingerprints of the SSH keys registered in DigitalOcean.
- `DO_DEPLOY_SSH_KEY`: SSH private key that can log into both droplets.
- `DO_DEPLOY_USER_STAGING` / `DO_DEPLOY_USER_PRODUCTION`: remote users for each environment (e.g., `root` or `monitor`).
- `DO_DEPLOY_PATH_STAGING` / `DO_DEPLOY_PATH_PRODUCTION`: target deployment paths (typically `/opt/pyron-monitor-stack` or `/opt/pyron-monitor-stack-staging`).
- `MONITOR_ENV_STAGING` / `MONITOR_ENV_PRODUCTION`: the `.env` payloads for each environment; the jobs skip pushing the file if the secret is empty.

## Verification and maintenance

- Inspect service logs via `docker compose logs -f grafana` (and other containers).
- Grafana dashboards are already attached to the configured datasources.
- Test Alertmanager with `amtool` or by sending alerts to the webhook.
- When `.env` changes, update the `MONITOR_ENV` secret to sync the droplet again.
- For major upgrades, use `docker compose down --volumes` carefully to preserve data.

