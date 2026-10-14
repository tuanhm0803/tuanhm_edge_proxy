# tuanhm_edge_proxy

Shared nginx reverse proxy sitting in front of every app on the
`72.60.43.33` VPS that needs ports 80/443. Only one process can bind those
ports, so this is the single entry point for the box; everything else
(aifakenews, autopretty, tuanhm.pro, future apps) reaches the internet
through it instead of binding host ports directly.

| Domain | Routed to | TLS terminated by |
|---|---|---|
| `aifakenews.cloud`, `www.` | `aifakenews-frontend-prod:443` | the app itself |
| `autopretty.tuanhm.pro` | `127.0.0.1:8443` → `autopretty-frontend:80` | this proxy |
| `tuanhm.pro` (`www.` redirects) | `127.0.0.1:8444` → `tuanhm-frontend:80` | this proxy |

## How it works

- **Port 443**: a layer-4 (`stream {}`) SNI router. It reads the domain name
  out of the TLS handshake *without decrypting it* and forwards the raw
  connection to the right backend. `aifakenews.cloud` is routed straight to
  the existing `aifakenews-frontend-prod` container, which keeps
  terminating its own TLS with its own certificate exactly as it always
  has — this proxy never touches that cert or that app's nginx config.
- **Port 80**: serves Let's Encrypt's `.well-known/acme-challenge/` path
  (needed to issue/renew certificates for any new domain) and redirects
  everything else to HTTPS.
- **New domains that don't terminate their own TLS** (like `autopretty`) get
  a dedicated `server { listen 127.0.0.1:PORT ssl; }` block in `nginx.conf`
  that terminates HTTPS here, using a certificate this proxy's own
  `edge-certbot` container issues and auto-renews.

## Deploying changes

Push to `main`. The workflow in `.github/workflows/deploy.yml` SSHes in,
pulls this repo into `/opt/edge` on the VPS, and runs
`docker compose up -d --remove-orphans`. No manual SSH needed for routine
config changes.

**Required GitHub secrets** (repo Settings → Secrets and variables →
Actions): `VPS_HOST`, `VPS_USERNAME`, `VPS_SSH_KEY`, `VPS_PORT` — same
values as the `aifakenews` repo's secrets of the same names.

## Adding a new domain

1. Point DNS for the new (sub)domain at `72.60.43.33`.
2. In `nginx.conf`, add a `server { listen 127.0.0.1:PORT ssl; ... }` block
   for the new domain (pick an unused loopback port) pointing at its
   container, and add a line to the `stream{}` block's `map` routing its
   SNI name to `127.0.0.1:PORT`. Use `$ssl_server_name` in the
   `ssl_certificate`/`ssl_certificate_key` paths (copy the autopretty
   block) so nginx starts fine before the certificate exists.
3. Add the domain to `CERT_DOMAINS` in `docker-compose.yml`.
4. Make sure the new app's own container joins the external `edge-network`
   (`networks: - edge-network`, `networks: edge-network: { external: true,
   name: edge-network }`) and does **not** publish its own 80/443 to the
   host.
5. Commit and push. The workflow restarts the stack; `edge-certbot` issues
   the certificate on startup (retrying every 20 minutes if validation
   fails) and renews it automatically. Check progress with
   `docker logs edge-certbot` on the VPS.

## Why `aifakenews.cloud` is special-cased

`aifakenews` already had its own working certificate and TLS setup before
this proxy existed. Rather than re-issue a certificate and duplicate that
setup here, port 443 traffic for it is passed through at the TCP level
(SNI routing), so its existing cert and renewal process keep working
completely unmodified. Only genuinely new domains terminate TLS in this
proxy.
