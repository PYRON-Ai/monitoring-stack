# Getting into Grafana

Two ways in, on purpose: one for every day, one for when the first is unavailable.

| | Day-to-day | Break-glass |
|---|---|---|
| Path | Cloudflare Access → cloudflared → Grafana | SSH port-forward → Grafana |
| Identity | the developer's own corporate account + MFA | the Grafana admin password |
| Depends on | Cloudflare being up | nothing but SSH |
| Who | everyone | whoever holds an SSH key on the droplet |

The second exists because the first has a dependency we do not control. If
Cloudflare has an outage during an incident, the monitoring stack is exactly what
you need and exactly what you would have lost.

---

## Day-to-day: Cloudflare Access

Open the Grafana URL, sign in with your corporate account, done. No VPN, no
binary to download, no shared password, nothing to install.

Your Grafana account is created on first login from the email Access reports, as
a **Viewer**. If you need to edit dashboards, ask an admin to change your role —
once, in Grafana.

**Access is the whole membership list.** Adding a developer means adding them to
the Access policy; removing them there removes their Grafana access on the next
request. Nobody is ever added or removed inside Grafana.

---

## Break-glass: SSH port-forward

When Cloudflare is unavailable — or you need admin while SSO is broken:

```bash
ssh -L 3000:172.28.0.20:3000 <user>@<droplet-ip>
# then open http://localhost:3000 and log in with the admin account
```

The target is the container's **address on the compose bridge**, and both
obvious-looking alternatives fail:

- `localhost:3000` — reaches the droplet's own port 3000, which nothing
  publishes any more.
- `grafana:3000` — `sshd` runs on the host, outside the compose network, so it
  cannot resolve container names: *"Temporary failure in name resolution"*.

`172.28.0.20` is pinned in `docker-compose.yml` precisely so this command stays
copy-pasteable; nobody should be looking up a container IP mid-incident. If it
ever does move, `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' <grafana-container>` on the droplet gives the current one.

The admin credentials live in `MONITOR_ENV_STAGING` (`GF_SECURITY_ADMIN_USER` /
`GF_SECURITY_ADMIN_PASSWORD`). Treat them as break-glass: not the daily login,
not shared in chat, rotated if they are ever used and seen by more than one
person.

> `pyron-tunnel` (the Go binary) automates this same SSH forward. It predates
> Access and still works, but it ships one shared key and one shared password to
> everyone, so it cannot tell you who connected. Keep it for admins; it is not the
> path for the team any more. Its built-in default host is also stale — pass
> `-h <user>@<current-droplet-ip>` explicitly.

---

## Setting it up (admin, once)

> **Do step 3 before merging.** Removing Grafana's published port and adding the
> tunnel land in the same change, so deploying without `TUNNEL_TOKEN` set leaves
> cloudflared restart-looping and Grafana reachable only over the break-glass
> forward — the old `-L 3000:localhost:3000` stops working at that moment. Get
> the token into `MONITOR_ENV_STAGING` first, or expect that gap.

### 1. Create the tunnel

Cloudflare dashboard → **Zero Trust → Networks → Tunnels → Create a tunnel**
(type: *Cloudflared*). Name it something like `pyron-monitoring-staging`.

Copy the **tunnel token** it shows. That token is the credential the container
authenticates with — treat it like a password.

### 2. Point the tunnel at Grafana

In the tunnel's **Public Hostnames** tab, add:

| Field | Value |
|---|---|
| Subdomain | `grafana` (or whatever you prefer) |
| Domain | your Cloudflare zone |
| Service | `http://grafana:3000` |

`grafana:3000` is the container's name on the compose network — cloudflared
resolves it internally, which is why Grafana needs no published port.

### 3. Put the token in the environment

The droplet's `.env` is written wholesale from the `MONITOR_ENV_STAGING` GitHub
secret, so add this line to that secret (it is not a separate secret):

```
TUNNEL_TOKEN=<the token from step 1>
```

While editing it, add the `GF_AUTH_PROXY_*` block from `.env.example` too.

### 4. Protect it with Access

Zero Trust → **Access → Applications → Add an application** (Self-hosted), on the
hostname from step 2. Add a policy:

- Action: **Allow**
- Rule: *Emails ending in* `@yourcompany.com` — or an explicit email list, which
  is tighter and worth it for a small team.

Require MFA in your identity provider or in the Access policy itself.

**Verify the header name.** This setup assumes Access sends
`Cf-Access-Authenticated-User-Email`, which is its default. If your policy sends
a different header, `GF_AUTH_PROXY_HEADER_NAME` must match it exactly or logins
will fail closed (not open).

### 5. Deploy

Push to `stage`. The pipeline writes the new `.env` and restarts the stack.

---

## Checking it actually works

```bash
# cloudflared connected to Cloudflare's edge?
docker compose logs cloudflared | grep -i "registered tunnel connection"

# restart-looping instead? almost always a missing/invalid TUNNEL_TOKEN. The
# image is distroless and cannot explain itself, so the deploy job warns about
# the missing variable — check the pipeline log for that warning.

# Grafana must NOT be reachable from outside
curl -sS --max-time 5 http://<droplet-ip>:3000   # expect: connection refused
```

Then open the URL from a browser: you should be asked to authenticate, and land
in Grafana already signed in as yourself. If it drops you at Grafana's own login
form instead, the header is not arriving — check the name in step 4.

---

## Why this shape

**Nothing listens for Grafana.** cloudflared dials *out* to Cloudflare, so there
is no inbound port to scan, firewall, or forget about. Port 3000 is gone from the
droplet, not merely restricted.

**Identity is one list.** Membership lives in the Access policy: one place to add
someone, one place to cut them off, and a log of who reached the service.
Previously access meant a shared SSH key plus a shared password — which nobody
could rotate cheaply and which recorded nothing about who connected.

**The trust is deliberately narrow.** `auth.proxy` makes Grafana believe an
identity header, which is dangerous exactly to the degree that something else can
send it. Grafana's own documentation names the IP whitelist as the defence
("can be used to prevent users spoofing the ... header"), and that is what
`GF_AUTH_PROXY_WHITELIST` does here — it names only the cloudflared container's
fixed address. Together with Grafana publishing no port, there is no route that
skips Access. Both must hold: republishing the port would quietly turn
header-trust into "anyone can be anyone".

**A stronger option exists, if this ever needs to be tighter.** Access also sends
`Cf-Access-Jwt-Assertion`, a signed JWT that Grafana can verify against
Cloudflare's public keys (`auth.jwt`). That shifts the guarantee from "we trust
the network path" to "we verified a signature", and would survive a
misconfiguration that exposes the port. It costs more setup — a certs URL, claim
mapping, key rotation — and the header approach is sound as long as the two
conditions above hold. Worth revisiting if Grafana ever needs to be reachable by
anything other than cloudflared.
