# Getting into Grafana

Two ways in, on purpose: one for every day, one for when the first is unavailable.

| | Day-to-day | Break-glass |
|---|---|---|
| Path | Cloudflare Access → cloudflared → Grafana | SSH port-forward → Grafana |
| Identity | corporate account + MFA at the door; shared Grafana login inside | the Grafana admin password |
| Depends on | Cloudflare being up | nothing but SSH |
| Who | everyone | whoever holds an SSH key on the droplet |

The second exists because the first has a dependency we do not control. If
Cloudflare has an outage during an incident, the monitoring stack is exactly what
you need and exactly what you would have lost.

---

## Day-to-day: Cloudflare Access

Open `https://monitoring-stage.pyron-ai.com`, sign in with your corporate
account, then sign in to Grafana. No VPN, no binary to download, nothing to
install.

**Access is the membership list.** Adding a developer means adding them to the
Access policy; removing them there cuts off their access on the next request.

⚠️ **Two logins, for now.** Cloudflare Access decides *who may reach* Grafana,
but Grafana still asks for its own credentials, which today are the shared admin
account. So Grafana's audit log cannot tell your team apart — Access can, and its
log is the one that carries identity.

Making Grafana adopt the Access identity needs `auth.jwt` (see
[Why this shape](#why-this-shape)); the header-based approach that was here
before does not hold now that the tunnel runs on the host.

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

cloudflared runs as a **systemd unit on the droplet**, not as a container in the
stack. That is deliberate: the tunnel then survives `docker compose down`, which
is precisely when you most want to reach Grafana, and the token stays in a
root-only file instead of passing through the deploy pipeline.

### 1. Create the tunnel

Cloudflare dashboard → **Zero Trust → Networks → Tunnels → Create a tunnel**
(type: *Cloudflared*). Copy the token it shows; treat it like a password.

### 2. Install it on the droplet

Cloudflare's dashboard gives you the install command. What matters is where the
token ends up:

```bash
install -d -m 0700 /etc/cloudflared
printf '%s' '<token>' > /etc/cloudflared/token
chmod 0600 /etc/cloudflared/token
systemctl enable --now cloudflared
```

### 3. Point it at Grafana

In the tunnel's **Public Hostnames** tab:

| Field | Value |
|---|---|
| Hostname | `monitoring-stage.pyron-ai.com` |
| Service | `http://172.28.0.20:3000` |

⚠️ **Not `localhost:3000`.** Grafana publishes no host port, so localhost reaches
nothing — this is the single most likely thing to be wrong, and it fails with
`connection refused` in the cloudflared log. `172.28.0.20` is Grafana's pinned
address on the compose bridge, which the host can route to.

### 4. Protect it with Access

Zero Trust → **Access → Applications → Add an application** (Self-hosted), on the
hostname from step 3. Add a policy:

- Action: **Allow**
- Rule: *Emails ending in* `@yourcompany.com`, or an explicit email list — tighter,
  and worth it for a small team.

Require MFA in your identity provider or in the Access policy itself.

Without this step the tunnel is a **public URL**: the hostname resolves for
anyone on the internet, and only Grafana's own login stands in the way. Access is
what makes the tunnel safe, not the tunnel itself.

---

## Checking it actually works

```bash
# on the droplet — is the tunnel connected?
systemctl status cloudflared
journalctl -u cloudflared -n 20 --no-pager | grep -iE "registered|error"

# does the origin actually answer? (the step-3 mistake shows up here)
curl -sS --max-time 5 -o /dev/null -w '%{http_code}\n' http://172.28.0.20:3000/api/health   # expect 200

# Grafana must NOT be reachable from outside
curl -sS --max-time 5 http://<droplet-ip>:3000   # expect: connection refused
```

Then open the hostname in a browser: Access should challenge you, and Grafana's
login should follow.

---

## Why this shape

**Nothing listens for Grafana.** cloudflared dials *out* to Cloudflare, so there
is no inbound port to scan, firewall, or forget about. Port 3000 is gone from the
droplet, not merely restricted.

**Identity is one list.** Membership lives in the Access policy: one place to add
someone, one place to cut them off, and a log of who reached the service.
Previously access meant a shared SSH key plus a shared password — which nobody
could rotate cheaply and which recorded nothing about who connected.

**The tunnel outlives the stack.** Running cloudflared as a host unit rather than
a compose service means `docker compose down`, a failed deploy, or a stack
restart does not take the door away with the room. The token also stays in a
root-only file on the droplet instead of travelling through a GitHub secret, the
pipeline, and a `.env`.

**Grafana does not yet know who you are — and that is the open gap.** Access
authenticates at the door and forwards the user's email in a header, but Grafana
is not configured to trust it, so everyone signs in with the shared admin
account.

The reason is specific rather than lazy. `auth.proxy` trusts an identity header
from a whitelisted source address, which only works if that address is something
*nothing else* can send from. When cloudflared was a container it had its own
pinned address on the bridge and that held. Now that it runs on the host, its
traffic arrives from the bridge gateway (`172.28.0.1`) — an address every
container on the network can also reach. Whitelisting it would mean any container
could claim to be any user, which is a weaker promise than the one this was built
to make.

**The fix is `auth.jwt`.** Access also sends `Cf-Access-Jwt-Assertion`, a signed
token Grafana can verify against Cloudflare's public keys. That replaces "we
trust where this packet came from" with "we checked the signature", so it is
indifferent to where the tunnel runs. It needs a certs URL, claim mapping and key
rotation — the work is real, which is why the shared login stands in the interim
rather than a whitelist that would only look secure.
