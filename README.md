# naive-caddy-installer

One-command installer for [NaïveProxy](https://github.com/klzgrad/naiveproxy) + [Caddy](https://caddyserver.com/) with the `caddy-forwardproxy@naive` plugin on Debian/Ubuntu VPS. The klzgrad stack: a single Caddy on :443 that both serves the Naive tunnel and acts as a cover site for everyone else.

## What it does

- Enables TCP BBR
- Installs the latest stable Go (resolved from go.dev)
- Builds Caddy with `klzgrad/forwardproxy@naive` via `xcaddy`
- Generates 16-char alphanumeric credentials
- Writes a `Caddyfile` with `basic_auth` + `probe_resistance` + `reverse_proxy` to a mask site
- Sets up the `caddy.service` systemd unit and waits for the Let's Encrypt TLS certificate
- At the end, prints:
  - credentials
  - a `config.json` for the [`naive`](https://github.com/klzgrad/naiveproxy/releases) CLI client (also saved to `/root/naive-client-config.json`)
  - a `naive+https://...` URI (SagerNet/NekoBox de-facto format) for Android clients [Exclave](https://github.com/dyhkwong/Exclave), NekoBox, sing-box-for-android with the Naïve plugin
  - a QR code for that URI rendered straight to the terminal
  - a sing-box outbound JSON block (for [Karing](https://github.com/KaringX/karing) and other sing-box-based clients that don't parse the `naive+https://` URI directly)

## Run

```bash
sudo bash <(wget -qO- https://raw.githubusercontent.com/Ieveltyanna/naive-caddy-installer/main/setup.sh)
```

Or, if you want to read the script first:

```bash
wget https://raw.githubusercontent.com/Ieveltyanna/naive-caddy-installer/main/setup.sh
sudo bash setup.sh
```

The script is interactive: it asks for the domain and the mask site, everything else is detected automatically (architecture, Go version, credentials).

### Non-interactive mode

All inputs can be provided via env vars — no prompts will be shown:

```bash
sudo NAIVE_DOMAIN=proxy.example.com \
     NAIVE_MASK_SITE=https://www.lovense.com \
     bash <(wget -qO- https://raw.githubusercontent.com/Ieveltyanna/naive-caddy-installer/main/setup.sh)
```

## Prerequisites

1. **VPS** running Debian 12 or Ubuntu 22.04+/24.04 with a public IPv4. Architecture: amd64 or arm64.
2. **Domain** with an A-record pointing at this VPS.
   - Any registrar. Free subdomains (DuckDNS, etc.) work.
   - **Do not proxy through Cloudflare** (orange-cloud). Cloudflare breaks both ACME and the Naive tunnel. Use grey-cloud / DNS-only mode, or a different DNS provider entirely.
3. **Open ports :80 and :443** to the public internet.
   - :443 — the main channel.
   - :80 — needed only at certificate issuance time (ACME HTTP-01 challenge). After that, you can close it; Caddy will renew via TLS-ALPN.
4. **Root SSH access.** The script runs as root.

## Picking a mask site

Caddy's `reverse_proxy` will serve the chosen site to anyone hitting :443 without valid credentials. The closer that site's TLS fingerprint is to neighbours on your IP subnet, the lower the chance of mass IP scanning identifying your VPS.

**Important: the scanner runs from a different machine, NOT from the VPS itself** (it makes noise across the subnet and would log your IP in the same analytics bucket as the cover sites). Run it from a local desktop or a temporary throwaway VPS.

```bash
# On your local machine or a temp VPS (NOT the proxy VPS)
wget https://github.com/XTLS/RealiTLScanner/releases/latest/download/RealiTLScanner-linux-64
chmod +x RealiTLScanner-linux-64
./RealiTLScanner-linux-64 --addr <YOUR_VPS_IP>
```

In the output, look for lines like:

```
time=... level=INFO msg="Connected to target" feasible=true ip=... origin=... tls="TLS 1.3" alpn=h2 cert-domain=someexample.com cert-issuer="Let's Encrypt" geo=N/A
```

Pick a `cert-domain` that has:
- `feasible=true`
- `tls="TLS 1.3"`
- `alpn=h2`
- preferably `cert-issuer="Let's Encrypt"` (same CA your domain will use → matching cipher-suite chain)

Pass the result to the script as `https://<domain>` (e.g. `https://someexample.com`).

**If the scanner finds nothing useful** or you'd rather skip the step — leave the default `https://www.lovense.com` (a large public site with a Let's Encrypt certificate). Don't use `https://demo.cloudreve.org` from older guides — it's a known fingerprint of mass-scanned naive servers.

## After installation

The script saves:
- `/etc/caddy/credentials.txt` — login / password / URI (chmod 600)
- `/root/naive-client-config.json` — client config for the CLI (chmod 600)

And prints all of the above to stdout along with a QR code.

### CLI client (desktop)

1. Download `naive` for your OS: <https://github.com/klzgrad/naiveproxy/releases>
2. Copy `/root/naive-client-config.json` from the VPS to your machine (e.g. `scp root@<vps>:/root/naive-client-config.json .`)
3. Run: `./naive naive-client-config.json`
4. Local SOCKS5 is now on `127.0.0.1:10808`. Use it as:
   - system proxy
   - browser proxy (SwitchyOmega, FoxyProxy)
   - `ALL_PROXY=socks5h://127.0.0.1:10808`

### Android

NaïveProxy has no official URI standard from klzgrad. The de-facto format used across the SagerNet/NekoBox/NekoRay family is:

```
naive+https://user:pass@host:port?padding=1#tag
```

The script outputs this URI and a QR for it. `padding=1` enables HTTP/2 padding (the whole point of Naive); SagerNet-family clients respect it, others ignore it.

#### Exclave (recommended)

1. Install [Exclave](https://github.com/dyhkwong/Exclave/releases) and the [Naïve plugin](https://github.com/klzgrad/naiveproxy/releases) (the *NaiveProxy Plugin* APK from the upstream releases).
2. In Exclave: «+» → «Scan QR code» → scan the QR from the script's output.
3. The profile appears in the list. Tap «Connect».

Exclave parses the URI directly ([`NaiveFmt.kt:28-47`](https://github.com/dyhkwong/Exclave/blob/dev/app/src/main/java/io/nekohasekai/sagernet/fmt/naive/NaiveFmt.kt#L28-L47)) — recognised query params: `sni`, `extra-headers`, `insecure-concurrency`. `padding` is ignored (Naive plugin uses padding by default anyway).

#### NekoBox

Same flow as Exclave — scan the QR. NekoBox is part of the same SagerNet lineage and parses the same URI shape.

#### Karing / sing-box-for-android

These clients are sing-box-based and may not parse the `naive+https://` URI directly. Use the sing-box outbound JSON block from the script's output instead — paste it into the `outbounds[]` array of your sing-box config (or your subscription provider's template).

The script prints a ready-to-paste block like:

```json
{
  "type": "naive",
  "tag": "NaiveProxy",
  "server": "your-domain.com",
  "server_port": 443,
  "username": "user",
  "password": "pass",
  "tls": {
    "enabled": true,
    "server_name": "your-domain.com",
    "utls": { "enabled": true, "fingerprint": "chrome" }
  }
}
```

## Final check

After starting the CLI client:

```bash
curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.me
```

Should return your VPS's IP. If it returns your client ISP's IP — the client isn't connecting to the server (see troubleshooting).

In parallel, hit the domain directly from the outside:

```bash
curl -v https://your-domain.com
```

Should serve the mask site's content. No trace of «proxy here» — no `Server: Caddy` headers, no weird redirects, no unusual status codes.

## Service management

```bash
systemctl status caddy           # status
systemctl restart caddy          # restart
journalctl -u caddy -f           # live logs
journalctl -u caddy -n 100       # last 100 lines
cat /etc/caddy/credentials.txt   # creds (if you lost them)
```

To change domain / mask / credentials — edit `/etc/caddy/Caddyfile` and `systemctl reload caddy`. Or rerun the script — when an existing install is detected it offers a menu:

1. Rebuild Caddy from sources + regenerate Caddyfile (new credentials), restart
2. Keep existing Caddy binary + regenerate Caddyfile (new credentials), restart
3. **Reuse existing Caddyfile and credentials, just restart** — useful for pulling fresh QR / config output without invalidating credentials you've already shared with clients
4. Exit, leave system untouched

## Troubleshooting

### `acme: error: 403` or certificate isn't issued

- Verify the A-record actually points to the VPS: `dig +short your-domain.com` **from the VPS itself**.
- If using Cloudflare — switch to grey-cloud (DNS-only). Orange-cloud is incompatible with this stack.
- :80 must be reachable from the public internet at issuance time (ACME HTTP-01 challenge).

### `caddy.service` fails with `address already in use`

Something else is listening on :443 — old Caddy, nginx, apache, container. Find and kill it:

```bash
ss -tlnp | grep :443
```

The script does this preflight automatically, but if you launched Caddy manually in parallel, you'll get a conflict.

### `curl --socks5-hostname` returns the client's IP

The CLI client `naive` isn't running or isn't listening on :10808. Check:

```bash
# on the client
netstat -tlnp | grep 10808   # or: ss -tlnp | grep 10808
```

And confirm `config.json` has exactly the same `user:pass` as `/etc/caddy/credentials.txt`.

### `xcaddy build` fails with `no space left on device`

The script uses `TMPDIR=/root/tmp`, but if `/root` itself is tight — free up space or rebuild on a machine with a bigger disk.

### Exclave: «Profile not found» / QR doesn't scan

Copy the URI string from the script's output (`naive+https://...`) and in Exclave use «+» → «Add manual» → paste the URI.

### Karing imports the URI but the connection fails

Karing's URI parser may not handle `naive+https://` reliably across versions. Use the sing-box outbound JSON block from the script's output instead — either paste it into a manual sing-box config or wrap it in a subscription URL that Karing imports.

## What this script does NOT do

- **No firewall configuration** (`ufw`, `firewalld`). Open :22, :80, :443/tcp manually via your provider or `ufw`.
- **No Cloudflare WARP** for split ingress/egress IP. That's a separate setup.
- **No mobile client installation.** Server-side only, plus URI/QR for client import.
- **No `apt upgrade`.** Considered risky on a loaded VPS without a snapshot.
- **No RHEL/Arch/Alpine support.** Debian/Ubuntu only.

## Sources

- Canonical klzgrad-stack guide: original gist [swrneko/09e60de4d3d8f9a551a1a2c1ab9283c5](https://gist.github.com/swrneko/09e60de4d3d8f9a551a1a2c1ab9283c5)
- klzgrad/naiveproxy: <https://github.com/klzgrad/naiveproxy>
- caddy-forwardproxy (klzgrad fork): <https://github.com/klzgrad/forwardproxy/tree/naive>
- Exclave: <https://github.com/dyhkwong/Exclave>
- RealiTLScanner: <https://github.com/XTLS/RealiTLScanner>
