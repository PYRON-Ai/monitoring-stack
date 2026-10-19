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

**Lost the token later?** You do not need to recreate the tunnel. Open the tunnel
→ **Configure**, and the install command shown there contains the token (it is
the long string after `--token`). Same value, retrievable any time — which is
also why access to the Cloudflare dashboard is itself a credential worth
guarding.

On the droplet the token is already on disk at `/etc/cloudflared/token` (0600,
root-only), so `cat` it there if you have SSH but not the dashboard.

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

**Until this step is done the tunnel is a public URL.** The hostname resolves for
anyone on the internet and only Grafana's own login stands in the way — which is
how staging sat exposed for a while. Access is what makes the tunnel safe; the
tunnel itself is just a door.

Zero Trust → **Access → Applications → Add an application → Self-hosted**.

**4a. Basic information**

| Field | Value |
|---|---|
| Application name | `Pyron Monitoring (staging)` |
| Session duration | `24 hours` |
| Subdomain / Domain | `monitoring-stage` / `pyron-ai.com` |
| Path | *(leave empty — protects everything)* |

**4b. Authentication** — the step that is easy to miss

This is a **separate tab** in the same form, and the form lets you save without
touching it. Skipping it produces an application with no login method at all:
the sign-in page appears, accepts an email, and then nothing happens — no PIN,
no error.

Set **either**:
- **Accept all available identity providers** → on, or
- select **One-time PIN** explicitly in the provider list.

If One-time PIN is not in that list, it is not enabled on the account: **Settings
→ Authentication → Login methods → Add new → One-time PIN**. It is built in and
needs no configuration.

⚠️ Leave **"Authenticate with Cloudflare One Client"** OFF. Turning it on fails
the save with:

```
access.api.error.invalid_request: allow_authenticate_via_warp cannot be set until
a Cloudflare One Client Authentication session duration is set for the account.
```

That toggle is for the WARP client on managed devices. It has nothing to do with
email login, and the error message does not make that obvious.

**4c. Policies**

| Field | Value |
|---|---|
| Policy name | `Pyron team` |
| Action | **Allow** |
| Rule | **Include** → **Emails** → the list of people |

An explicit email list beats *"emails ending in @yourcompany.com"* for a small
team: it is tighter, and a new account on the domain does not silently inherit
access.

⚠️ **Add your own address before saving**, or you lock yourself out of what you
just protected. (The SSH forward still works, but you should not need it for
this.)

Note the rule must be under **Include**. A rule placed only under *Require*
matches nobody, and the symptom is identical to every other misconfiguration
here: you enter an email and no PIN arrives.

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

**The one check that tells you Access is really in front:**

```bash
curl -sS -o /dev/null -w '%{redirect_url}\n' https://monitoring-stage.pyron-ai.com/
```

- `…cloudflareaccess.com/cdn-cgi/access/login/…` → Access is protecting it ✅
- `…/login` → that is **Grafana's own** login page, meaning requests reach it
  directly and the service is exposed to the internet ❌

The second case looks reassuring in a browser — you get a login form, so it feels
protected — which is exactly why it went unnoticed.

---

## When it does not work

Nearly every failure below produces the same symptom: **you enter your email and
no PIN arrives**. Access does not explain itself, so work through the causes in
order.

| Symptom | Cause | Fix |
|---|---|---|
| No PIN, login page looks normal | Application has no identity provider selected | Step 4b — this was the real cause here |
| No PIN, email is in the policy | Email not matching, or rule under *Require* instead of *Include* | Step 4c; check for typos and stray whitespace |
| No PIN, everything configured | Mail in spam | Sender is `noreply@notify.cloudflare.com`; allow a couple of minutes |
| Save fails with `allow_authenticate_via_warp` | "Authenticate with Cloudflare One Client" is on | Turn it off — step 4b |
| `connection refused` in the cloudflared log | Origin points at `localhost:3000` | Step 3 — use `172.28.0.20:3000` |
| Redirect goes to `/login`, not cloudflareaccess.com | No Access application on the hostname | Step 4 — the tunnel is public until then |

**Access deliberately stays silent when an email is not authorised.** It does not
send a PIN and does not say you lack permission, so that it reveals nothing about
who has access. Useful for security, confusing while debugging: an unauthorised
address and a broken configuration look identical from the outside.

**Where to look from the droplet:**

```bash
journalctl -u cloudflared -n 30 --no-pager | grep -iE "registered|error"
```

`Unable to reach the origin service … connection refused` means the tunnel is up
and Cloudflare is routing correctly — only the last hop is wrong. That is the
step-3 mistake, and it is good news: everything before it works.

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
