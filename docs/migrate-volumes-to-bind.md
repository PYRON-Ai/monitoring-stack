# One-time migration: named volumes → `./data` bind mounts

Run this **on the droplet, before deploying** the change that switches
`docker-compose.yml` to bind mounts. Deploying first would start the stack
against empty directories: nothing is deleted, but Prometheus, Loki and Grafana
would all come up blank and the old data would sit unreferenced in
`/var/lib/docker/volumes/`.

Takes a couple of minutes. ~1GB is copied.

```bash
cd /root/123          # DEPLOY_PATH

# 1. Stop the stack (NOT --volumes — that is the thing this change exists to
#    protect against, and the data is still in those volumes right now).
docker compose down

# 2. Create the directories with the uid each image runs as. A bind mount is
#    root-owned by default and the container then cannot write to it.
mkdir -p data/prometheus data/grafana data/loki data/alertmanager data/promtail

# 3. Copy each volume's contents across, preserving ownership.
for v in prometheus grafana loki alertmanager; do
  docker run --rm \
    -v "123_${v}_data:/from" \
    -v "$(pwd)/data/${v}:/to" \
    alpine sh -c 'cp -a /from/. /to/ 2>/dev/null || true'
done
docker run --rm \
  -v 123_promtail_positions:/from \
  -v "$(pwd)/data/promtail:/to" \
  alpine sh -c 'cp -a /from/. /to/ 2>/dev/null || true'

# 4. Fix ownership (cp -a preserves it, but the directories themselves are new).
chown -R 65534:65534 data/prometheus data/alertmanager
chown -R 472:0       data/grafana
chown -R 10001:10001 data/loki
chown -R 0:0         data/promtail
chmod 750 data

# 5. Check the sizes look like the originals before trusting it.
du -sh data/*
docker system df -v | grep 123_
```

Then deploy the branch normally. Verify before cleaning up:

```bash
docker compose ps                                     # all Up
curl -s localhost:9090/api/v1/query --data-urlencode \
  'query=count(up)' | head -c 120                     # Prometheus has series
# and log in to Grafana with the existing admin password — if that works, the
# grafana.db came across intact
```

## Only after it is verified

The old volumes still hold a full copy, which is a free safety net. Keep them
for a few days, then:

```bash
docker volume rm 123_prometheus_data 123_grafana_data 123_loki_data \
                 123_alertmanager_data 123_promtail_positions
docker volume rm loki_data loki_wal   # orphans from an older bootstrap step
```

## If it goes wrong

Nothing was deleted. Revert the deploy (or check out the previous
`docker-compose.yml`) and `docker compose up -d` — the named volumes are
untouched and the stack comes back exactly as it was.
