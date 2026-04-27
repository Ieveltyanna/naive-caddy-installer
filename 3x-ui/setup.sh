#!/usr/bin/env bash
# NaiveProxy + Caddy installer for servers ALREADY running x-ui-pro
# (https://github.com/mozaroc/x-ui-pro). Plugs Naive into the existing
# nginx SNI router on :443 instead of binding :443 itself.
#
# Companion to setup.sh from https://github.com/Ieveltyanna/naive-caddy-installer

set -euo pipefail

#─────────────────────────────────────────────────────────────────────────────
# Helpers
#─────────────────────────────────────────────────────────────────────────────

readonly C_RED=$'\033[0;31m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[0;33m'
readonly C_BLUE=$'\033[0;34m'
readonly C_BOLD=$'\033[1m'
readonly C_RST=$'\033[0m'

log()   { printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RST" "$*"; }
err()   { printf '%s[x]%s %s\n' "$C_RED"    "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }

on_err() {
    local code=$? line=${1:-?}
    err "Failed at line $line (exit $code). Last command: ${BASH_COMMAND}"
    exit "$code"
}
trap 'on_err $LINENO' ERR

confirm() {
    local prompt="$1" default="${2:-default-no}" reply
    local hint="[y/N]"
    [[ "$default" == "default-yes" ]] && hint="[Y/n]"
    while true; do
        read -r -p "$(printf '%s? %s ' "$prompt" "$hint")" reply </dev/tty || return 1
        reply="${reply:-}"
        if [[ -z "$reply" ]]; then
            [[ "$default" == "default-yes" ]] && return 0 || return 1
        fi
        case "$reply" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *) echo "Please answer y or n." >&2 ;;
        esac
    done
}

prompt_value() {
    local prompt="$1" default="${2:-}" reply
    local suffix=""
    [[ -n "$default" ]] && suffix=" [$default]"
    while true; do
        read -r -p "$(printf '%s%s: ' "$prompt" "$suffix")" reply </dev/tty || return 1
        reply="${reply:-$default}"
        if [[ -n "$reply" ]]; then
            printf '%s' "$reply"
            return 0
        fi
        echo "Value required, please enter." >&2
    done
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

#─────────────────────────────────────────────────────────────────────────────
# Constants
#─────────────────────────────────────────────────────────────────────────────

readonly DEFAULT_MASK_SITE="https://www.lovense.com"
readonly DEFAULT_BACKEND_PORT=8444

readonly CADDY_BIN="/usr/bin/caddy"
readonly CADDY_DIR="/etc/caddy"
readonly CADDYFILE="${CADDY_DIR}/Caddyfile"
readonly CRED_FILE="${CADDY_DIR}/credentials.txt"
readonly CLIENT_CONFIG="/root/naive-client-config.json"
readonly SINGBOX_CONFIG="/root/naive-singbox.json"
readonly SYSTEMD_UNIT="/etc/systemd/system/caddy.service"
readonly TMP_BUILD_DIR="/root/tmp"
readonly GO_INSTALL_DIR="/usr/local/go"

readonly NGINX_STREAM_DIR="/etc/nginx/stream-enabled"
readonly NGINX_STREAM_CONF="${NGINX_STREAM_DIR}/stream.conf"
readonly NGINX_CONFD_ACME="/etc/nginx/conf.d/naive-acme.conf"

readonly LE_DIR="/etc/letsencrypt/live"
readonly ACME_WEBROOT="/var/www/acme"

readonly STATE_DIR="/etc/naive-proxy"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly STREAM_FRAGMENT="${STATE_DIR}/stream.conf.canonical"

readonly DEPLOY_HOOK_DIR="/etc/letsencrypt/renewal-hooks/deploy"
readonly DEPLOY_HOOK="${DEPLOY_HOOK_DIR}/naive-caddy.sh"
readonly RENEW_CRON="/etc/cron.d/naive-cert-renew"

#─────────────────────────────────────────────────────────────────────────────
# Preflight
#─────────────────────────────────────────────────────────────────────────────

check_root() {
    [[ $EUID -eq 0 ]] || die "Run as root (try: sudo bash $0)"
}

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *) die "Unsupported architecture: $m (supported: x86_64, aarch64)" ;;
    esac
}

detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; this script supports Debian/Ubuntu only."
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ok "Detected ${PRETTY_NAME:-$ID}" ;;
        *) die "Unsupported OS: ${ID:-unknown} (supported: debian, ubuntu)" ;;
    esac
}

get_external_ip() {
    local ip
    for url in https://api.ipify.org https://ifconfig.me https://ipinfo.io/ip; do
        ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

check_dns() {
    local domain="$1" external_ip resolved_ips
    log "Checking DNS for $domain..."

    if ! external_ip="$(get_external_ip)"; then
        warn "Could not detect this server's external IP — skipping DNS check."
        return 0
    fi
    log "Server external IP: $external_ip"

    require_cmd dig
    resolved_ips="$(dig +short A "$domain" @1.1.1.1)"
    if [[ -z "$resolved_ips" ]]; then
        warn "Domain $domain has no A-record (or DNS not yet propagated)."
        confirm "Continue anyway (ACME will fail until DNS resolves)" default-no \
            || die "Aborted by user. Configure DNS A-record first."
        return 0
    fi

    if printf '%s\n' "$resolved_ips" | grep -Fxq "$external_ip"; then
        ok "DNS check passed: $domain → $external_ip"
    else
        warn "DNS mismatch: $domain resolves to [$(printf '%s' "$resolved_ips" | tr '\n' ' ')], server IP is $external_ip"
        warn "Possible causes: A-record not updated yet; Cloudflare orange-cloud (must be grey)."
        confirm "Continue anyway" default-no \
            || die "Aborted by user. Fix DNS A-record first."
    fi
}

check_x_ui_pro() {
    log "Checking for an existing x-ui-pro install..."

    [[ -s "$NGINX_STREAM_CONF" ]] \
        || die "$NGINX_STREAM_CONF missing or empty — x-ui-pro doesn't appear to be installed.
This script is a companion to https://github.com/mozaroc/x-ui-pro. If you only want a vanilla Naive setup on a clean VPS, run setup.sh instead."

    grep -q 'ssl_preread' "$NGINX_STREAM_CONF" \
        || die "$NGINX_STREAM_CONF doesn't look like an x-ui-pro stream config (no 'ssl_preread' directive)."
    grep -q 'proxy_protocol on' "$NGINX_STREAM_CONF" \
        || die "$NGINX_STREAM_CONF doesn't look like an x-ui-pro stream config (no 'proxy_protocol on' directive)."

    require_cmd nginx
    require_cmd certbot

    ok "x-ui-pro install detected"
}

# Parse domains AND upstream ports out of x-ui-pro's existing stream.conf.
# We re-detect ports rather than hardcoding 7443/8443 — only :8443 (Reality)
# and :9443 (mask) are confirmed in upstream docs; the panel port (currently
# 7443 in mozaroc/x-ui-pro) is implementation-detail and could change.
detect_existing_domains() {
    local f="$NGINX_STREAM_CONF" line
    PANEL_DOMAIN=""
    REALITY_DOMAIN=""
    PANEL_UPSTREAM_PORT=""
    XRAY_UPSTREAM_PORT=""

    while IFS= read -r line; do
        local stripped
        stripped="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        case "$stripped" in
            ''|'#'*|'map '*|'}'|'hostnames;'|'default'*) continue ;;
        esac
        local host upstream
        host="$(printf '%s' "$stripped" | awk '{print $1}')"
        upstream="$(printf '%s' "$stripped" | awk '{print $2}' | tr -d ';')"
        case "$upstream" in
            www)   PANEL_DOMAIN="$host" ;;
            xray)  REALITY_DOMAIN="$host" ;;
            naive) ;;  # already patched — skip
            *) ;;
        esac
    done < <(awk '/map \$ssl_preread_server_name/,/^\}/' "$f")

    # Extract ports from `upstream <name> { server 127.0.0.1:N; }` blocks.
    PANEL_UPSTREAM_PORT="$(awk '
        /^[[:space:]]*upstream[[:space:]]+www[[:space:]]*\{/  { in_block = 1; next }
        in_block && /server[[:space:]]+127\.0\.0\.1:[0-9]+/   { match($0, /:[0-9]+/); print substr($0, RSTART+1, RLENGTH-1); exit }
        in_block && /\}/                                       { in_block = 0 }
    ' "$f")"
    XRAY_UPSTREAM_PORT="$(awk '
        /^[[:space:]]*upstream[[:space:]]+xray[[:space:]]*\{/ { in_block = 1; next }
        in_block && /server[[:space:]]+127\.0\.0\.1:[0-9]+/  { match($0, /:[0-9]+/); print substr($0, RSTART+1, RLENGTH-1); exit }
        in_block && /\}/                                      { in_block = 0 }
    ' "$f")"

    [[ -n "$PANEL_DOMAIN" && -n "$REALITY_DOMAIN" ]] \
        || die "Could not parse panel/reality domains from $NGINX_STREAM_CONF.
Either the x-ui-pro install is non-standard, or the stream.conf has been edited by hand."
    [[ -n "$PANEL_UPSTREAM_PORT" && -n "$XRAY_UPSTREAM_PORT" ]] \
        || die "Could not parse upstream ports from $NGINX_STREAM_CONF (expected 'upstream www' and 'upstream xray' blocks)."

    log "Detected x-ui-pro layout:"
    log "  panel:   $PANEL_DOMAIN  → 127.0.0.1:$PANEL_UPSTREAM_PORT"
    log "  reality: $REALITY_DOMAIN  → 127.0.0.1:$XRAY_UPSTREAM_PORT"
}

check_backend_port_free() {
    local port="$1" busy_pid busy_proc
    require_cmd ss
    busy_pid="$(ss -tlnpH "sport = :${port}" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1 || true)"
    if [[ -n "$busy_pid" ]]; then
        busy_proc="$(ps -p "$busy_pid" -o comm= 2>/dev/null || echo unknown)"
        if [[ "$busy_proc" == "caddy" ]]; then
            log "Port :$port held by an existing caddy process — will be replaced."
            return 0
        fi
        die "Port :$port (intended for Caddy backend) is held by PID $busy_pid ($busy_proc).
Free it manually or set NAIVE_BACKEND_PORT to a different port and re-run."
    fi
}

#─────────────────────────────────────────────────────────────────────────────
# Inputs
#─────────────────────────────────────────────────────────────────────────────

gather_inputs() {
    if [[ -n "${NAIVE_DOMAIN:-}" ]]; then
        DOMAIN="$NAIVE_DOMAIN"
        log "Naive domain from env: $DOMAIN"
    else
        DOMAIN="$(prompt_value 'Naive domain (must point to this server, no Cloudflare proxy; must differ from panel/reality)')"
    fi

    [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
        || die "Invalid domain: '$DOMAIN' (expected something like naive.example.com — no scheme, no port, no path)"

    [[ "$DOMAIN" != "$PANEL_DOMAIN" ]]   || die "Naive domain must not equal the x-ui-pro panel domain ($PANEL_DOMAIN)."
    [[ "$DOMAIN" != "$REALITY_DOMAIN" ]] || die "Naive domain must not equal the x-ui-pro reality domain ($REALITY_DOMAIN)."

    if [[ -n "${NAIVE_MASK_SITE:-}" ]]; then
        MASK_SITE="$NAIVE_MASK_SITE"
        log "Mask site from env: $MASK_SITE"
    else
        MASK_SITE="$(prompt_value 'Mask site URL (cover when probed; see README)' "$DEFAULT_MASK_SITE")"
    fi

    local mask_clean
    mask_clean="$(printf '%s' "$MASK_SITE" | sed -E 's|^(https?://[^/?#]+).*$|\1|')"
    [[ "$mask_clean" =~ ^https?://[^/?#]+$ ]] || die "Mask site must start with http:// or https:// and contain a host: $MASK_SITE"
    if [[ "$mask_clean" != "$MASK_SITE" ]]; then
        log "Stripped path/slash from mask site: $MASK_SITE → $mask_clean"
        MASK_SITE="$mask_clean"
    fi

    BACKEND_PORT="${NAIVE_BACKEND_PORT:-$DEFAULT_BACKEND_PORT}"
    if ! [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]] || (( BACKEND_PORT <= 0 || BACKEND_PORT >= 65536 )); then
        die "Invalid NAIVE_BACKEND_PORT: '$BACKEND_PORT'"
    fi
    case "$BACKEND_PORT" in
        443|7443|8443|9443|80) die "Backend port $BACKEND_PORT clashes with nginx/x-ui-pro. Pick a free local port (default $DEFAULT_BACKEND_PORT)." ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# Install steps
#─────────────────────────────────────────────────────────────────────────────

install_dependencies() {
    local pkgs=(curl wget ca-certificates dnsutils iproute2 procps openssl tar qrencode certbot)
    local missing=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} == 0 )); then
        ok "apt dependencies already installed"
        return 0
    fi
    log "Installing apt dependencies (${missing[*]})..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}" >/dev/null
    ok "apt dependencies installed"
}

caddy_has_forwardproxy() {
    [[ -x "$CADDY_BIN" ]] || return 1
    "$CADDY_BIN" list-modules 2>/dev/null | grep -q '^http\.handlers\.forward_proxy' || return 1
}

install_go() {
    local latest tarball url
    log "Resolving latest stable Go version..."
    latest="$(curl -fsS --max-time 10 https://go.dev/VERSION?m=text | head -n1)"
    [[ "$latest" =~ ^go[0-9] ]] || die "Could not resolve latest Go version (got: '$latest')"

    if [[ -x "${GO_INSTALL_DIR}/bin/go" ]]; then
        local current
        current="$("${GO_INSTALL_DIR}/bin/go" version | awk '{print $3}')"
        if [[ "$current" == "$latest" ]]; then
            ok "Go ${latest} already installed"
            export PATH="${GO_INSTALL_DIR}/bin:$PATH"
            return 0
        fi
        log "Replacing existing Go ${current} with ${latest}"
    fi

    tarball="${latest}.linux-${ARCH}.tar.gz"
    url="https://go.dev/dl/${tarball}"
    log "Downloading $url"
    wget -q --show-progress -O "/tmp/${tarball}" "$url"

    rm -rf "${GO_INSTALL_DIR}"
    tar -C /usr/local -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"

    export PATH="${GO_INSTALL_DIR}/bin:$PATH"
    ok "Installed $(go version)"
}

build_caddy() {
    log "Preparing build environment..."
    mkdir -p "$TMP_BUILD_DIR"
    export TMPDIR="$TMP_BUILD_DIR"
    export GOPATH="${GOPATH:-/root/go}"
    export PATH="${GOPATH}/bin:${GO_INSTALL_DIR}/bin:$PATH"

    log "Installing xcaddy..."
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

    log "Building Caddy with klzgrad/forwardproxy@naive (this takes a few minutes)..."
    local build_dir
    build_dir="$(mktemp -d -p "$TMP_BUILD_DIR" caddy-build.XXXXXX)"
    pushd "$build_dir" >/dev/null
    "${GOPATH}/bin/xcaddy" build \
        --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive
    [[ -x ./caddy ]] || die "xcaddy build failed: ./caddy not produced"
    BUILT_CADDY_BIN="${TMP_BUILD_DIR}/caddy.new"
    install -m 0755 ./caddy "$BUILT_CADDY_BIN"
    popd >/dev/null
    rm -rf "$build_dir"
    ok "Caddy built: $BUILT_CADDY_BIN"
}

install_caddy_binary() {
    log "Installing Caddy binary to ${CADDY_BIN}..."
    if systemctl is-active --quiet caddy 2>/dev/null; then
        log "Stopping running caddy.service before binary swap..."
        systemctl stop caddy
    fi
    install -m 0755 "$BUILT_CADDY_BIN" "$CADDY_BIN"
    rm -f "$BUILT_CADDY_BIN"
    ok "Installed: $($CADDY_BIN version | head -n1)"
}

ensure_caddy_binary() {
    if caddy_has_forwardproxy; then
        ok "Existing Caddy binary already includes forward_proxy plugin (skipping build)"
        log "  $($CADDY_BIN version | head -n1)"
        return 0
    fi
    if [[ -x "$CADDY_BIN" ]]; then
        warn "Existing $CADDY_BIN doesn't include forward_proxy — rebuilding."
    fi
    install_go
    build_caddy
    install_caddy_binary
}

generate_credentials() {
    log "Generating credentials..."
    NAIVE_USER="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    NAIVE_PASS="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    [[ ${#NAIVE_USER} -eq 16 && ${#NAIVE_PASS} -eq 16 ]] \
        || die "Failed to generate credentials"
    ok "Credentials generated"
}

# Reuse existing Caddyfile credentials if they're present and look sane.
# We rewrite the Caddyfile (its layout differs from vanilla setup.sh anyway),
# but we don't want to invalidate creds the user has already shared with clients.
maybe_reuse_credentials() {
    if [[ ! -s "$CADDYFILE" ]]; then
        return 1
    fi
    local creds_line user pass
    creds_line="$(awk '/^[[:space:]]*basic_auth[[:space:]]/ {print $2, $3; exit}' "$CADDYFILE")"
    user="${creds_line%% *}"
    pass="${creds_line##* }"
    [[ -n "$user" && -n "$pass" && "$user" != "$pass" && ${#user} -ge 8 && ${#pass} -ge 8 ]] || return 1
    NAIVE_USER="$user"
    NAIVE_PASS="$pass"
    return 0
}

write_acme_server_block() {
    log "Writing ${NGINX_CONFD_ACME} for Let's Encrypt HTTP-01 challenge..."
    mkdir -p "$ACME_WEBROOT/.well-known/acme-challenge"
    chown -R root:root "$ACME_WEBROOT"
    chmod -R 0755 "$ACME_WEBROOT"

    cat > "$NGINX_CONFD_ACME" <<EOF
# Managed by naive-caddy-installer (setup-with-3x-ui-pro.sh).
# Survives x-ui-pro re-runs (it lives in conf.d/, not sites-{available,enabled}/).
server {
    listen 80;
    server_name ${DOMAIN};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_WEBROOT};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    nginx -t >/dev/null 2>&1 || die "nginx -t failed after writing ${NGINX_CONFD_ACME}"
    systemctl reload nginx
    ok "nginx :80 ACME server block in place"
}

issue_certificate() {
    if [[ -s "${LE_DIR}/${DOMAIN}/fullchain.pem" && -s "${LE_DIR}/${DOMAIN}/privkey.pem" ]]; then
        ok "Certificate for $DOMAIN already exists at ${LE_DIR}/${DOMAIN}/ (skipping issuance)"
        return 0
    fi
    log "Requesting certificate for $DOMAIN via webroot ($ACME_WEBROOT)..."
    certbot certonly \
        --webroot -w "$ACME_WEBROOT" \
        --non-interactive --agree-tos --register-unsafely-without-email \
        --cert-name "$DOMAIN" \
        -d "$DOMAIN" \
        || die "certbot failed. Check DNS A-record and that nginx is serving :80 for $DOMAIN."
    [[ -s "${LE_DIR}/${DOMAIN}/fullchain.pem" ]] || die "Cert not at expected path after issuance."
    ok "Certificate issued for $DOMAIN"
}

write_caddyfile() {
    log "Writing ${CADDYFILE}..."
    mkdir -p "$CADDY_DIR"
    cat > "$CADDYFILE" <<EOF
# Managed by naive-caddy-installer (setup-with-3x-ui-pro.sh).
# Caddy listens ONLY on 127.0.0.1:${BACKEND_PORT}; nginx fronts :443 publicly
# and dispatches by SNI (see ${NGINX_STREAM_CONF}).
{
    auto_https off
    servers 127.0.0.1:${BACKEND_PORT} {
        listener_wrappers {
            proxy_protocol {
                timeout 5s
                allow 127.0.0.1/32 ::1/128
            }
            tls
        }
    }
}

https://${DOMAIN} {
    bind 127.0.0.1:${BACKEND_PORT}

    tls ${LE_DIR}/${DOMAIN}/fullchain.pem ${LE_DIR}/${DOMAIN}/privkey.pem

    route {
        forward_proxy {
            basic_auth ${NAIVE_USER} ${NAIVE_PASS}
            hide_ip
            hide_via
            probe_resistance
        }

        reverse_proxy ${MASK_SITE} {
            header_up Host {upstream_hostport}
        }
    }
}
EOF
    chmod 600 "$CADDYFILE"
    "$CADDY_BIN" validate --config "$CADDYFILE" >/dev/null 2>&1 \
        || die "caddy validate failed for ${CADDYFILE}"
    ok "Caddyfile written and validated"
}

write_systemd_unit() {
    log "Writing ${SYSTEMD_UNIT}..."
    cat > "$SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=Caddy with NaiveProxy (behind nginx SNI router)
After=network.target network-online.target nginx.service
Wants=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "systemd unit written"
}

write_stream_conf() {
    log "Patching ${NGINX_STREAM_CONF} to add Naive SNI route..."
    mkdir -p "$NGINX_STREAM_DIR"

    cat > "$NGINX_STREAM_CONF" <<EOF
# Stream router managed jointly by x-ui-pro and naive-caddy-installer.
# Re-run 3x-ui/setup.sh (with NAIVE_REPAIR=1) if x-ui-pro overwrites this.
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${REALITY_DOMAIN}      xray;
    ${PANEL_DOMAIN}        www;
    ${DOMAIN}              naive;
    default                xray;
}

upstream xray {
    server 127.0.0.1:${XRAY_UPSTREAM_PORT};
}

upstream www {
    server 127.0.0.1:${PANEL_UPSTREAM_PORT};
}

upstream naive {
    server 127.0.0.1:${BACKEND_PORT};
}

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen          443;
    proxy_pass      \$sni_name;
    ssl_preread     on;
}
EOF
    install -D -m 0644 "$NGINX_STREAM_CONF" "$STREAM_FRAGMENT"
    nginx -t >/dev/null 2>&1 || die "nginx -t failed after patching stream.conf. Check $NGINX_STREAM_CONF."
    systemctl reload nginx
    ok "nginx stream.conf patched and nginx reloaded"
}

write_state_file() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    cat > "$STATE_FILE" <<EOF
# State for setup-with-3x-ui-pro.sh — managed file, do not edit by hand.
NAIVE_DOMAIN='${DOMAIN}'
NAIVE_PANEL_DOMAIN='${PANEL_DOMAIN}'
NAIVE_REALITY_DOMAIN='${REALITY_DOMAIN}'
NAIVE_BACKEND_PORT='${BACKEND_PORT}'
NAIVE_MASK_SITE='${MASK_SITE}'
EOF
    chmod 600 "$STATE_FILE"
}

write_renewal_artifacts() {
    log "Installing renewal hook + cron..."
    mkdir -p "$DEPLOY_HOOK_DIR"
    cat > "$DEPLOY_HOOK" <<EOF
#!/usr/bin/env bash
# Managed by naive-caddy-installer. Reload Caddy when the Naive cert renews.
# RENEWED_LINEAGE is set by certbot to the live/<lineage>/ path.
set -e
if [[ "\${RENEWED_LINEAGE:-}" == "/etc/letsencrypt/live/${DOMAIN}" ]]; then
    /usr/bin/systemctl reload caddy 2>/dev/null || /usr/bin/systemctl restart caddy
fi
EOF
    chmod 0755 "$DEPLOY_HOOK"

    # Use /etc/cron.d/ — root's user crontab gets de-duped by x-ui-pro
    # (line 1107: grep -v "certbot|x-ui|cloudflareips") on every re-run.
    cat > "$RENEW_CRON" <<EOF
# Managed by naive-caddy-installer. Renews ${DOMAIN} via webroot.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 3 * * * root certbot renew --cert-name ${DOMAIN} --webroot -w ${ACME_WEBROOT} --quiet
EOF
    chmod 0644 "$RENEW_CRON"
    ok "Renewal hook + cron installed"
}

start_caddy() {
    log "Enabling and starting caddy.service..."
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy
}

wait_for_caddy_active() {
    log "Waiting for Caddy to become active and serve via nginx SNI..."
    local i=0
    while (( i < 30 )); do
        if systemctl is-active --quiet caddy; then
            # Probe the public endpoint via nginx :443 → SNI → Caddy backend.
            if curl -sS --max-time 5 -o /dev/null --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}" 2>/dev/null; then
                ok "Caddy is active; nginx → Caddy SNI route works"
                return 0
            fi
        elif systemctl is-failed --quiet caddy; then
            err "caddy.service failed. Last 50 log lines:"
            journalctl -u caddy -n 50 --no-pager >&2
            die "Aborting. Inspect logs above (often: cert path readable? PROXY protocol mismatch?)."
        fi
        sleep 2
        ((++i))
    done
    warn "Caddy did not respond on https://${DOMAIN} (via 127.0.0.1) within 60s."
    warn "Recent logs:"
    journalctl -u caddy -n 30 --no-pager >&2
    confirm "Continue anyway" default-no \
        || die "Aborted. Run 'journalctl -u caddy -f' to debug."
}

#─────────────────────────────────────────────────────────────────────────────
# Output
#─────────────────────────────────────────────────────────────────────────────

save_credentials_file() {
    cat > "$CRED_FILE" <<EOF
# NaiveProxy credentials — generated $(date -Iseconds)
# Domain:       ${DOMAIN}
# Mask site:    ${MASK_SITE}
# Backend:      127.0.0.1:${BACKEND_PORT} (behind nginx SNI router on :443)
NAIVE_USER='${NAIVE_USER}'
NAIVE_PASS='${NAIVE_PASS}'
NAIVE_URL='naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=1#NaiveProxy'
EOF
    chmod 600 "$CRED_FILE"
}

write_client_config() {
    cat > "$CLIENT_CONFIG" <<EOF
{
  "listen": "socks://127.0.0.1:10808",
  "proxy": "https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}"
}
EOF
    chmod 600 "$CLIENT_CONFIG"
}

write_singbox_config() {
    cat > "$SINGBOX_CONFIG" <<EOF
{
  "outbounds": [
    {
      "type": "naive",
      "tag": "NaiveProxy",
      "server": "${DOMAIN}",
      "server_port": 443,
      "username": "${NAIVE_USER}",
      "password": "${NAIVE_PASS}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    }
  ]
}
EOF
    chmod 600 "$SINGBOX_CONFIG"
}

print_summary() {
    local uri="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=1#NaiveProxy"

    echo
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    printf '%s  NaiveProxy is up at https://%s%s (behind x-ui-pro nginx)\n' "$C_BOLD" "$DOMAIN" "$C_RST"
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    echo

    printf '%sCredentials%s\n' "$C_BOLD" "$C_RST"
    printf '  user: %s\n' "$NAIVE_USER"
    printf '  pass: %s\n' "$NAIVE_PASS"
    printf '  saved to: %s\n' "$CRED_FILE"
    echo

    printf '%sBackend layout%s\n' "$C_BOLD" "$C_RST"
    printf '  public  :443       — nginx (x-ui-pro), routes by SNI\n'
    printf '    SNI=%s → 127.0.0.1:8443 (Reality / xray)\n' "$REALITY_DOMAIN"
    printf '    SNI=%s → 127.0.0.1:7443 (panel)\n' "$PANEL_DOMAIN"
    printf '    SNI=%s → 127.0.0.1:%s (Caddy/Naive, this script)\n' "$DOMAIN" "$BACKEND_PORT"
    echo

    printf '%sClient config (klzgrad/naive CLI)%s\n' "$C_BOLD" "$C_RST"
    printf '  saved to: %s\n' "$CLIENT_CONFIG"
    echo
    printf '  contents:\n'
    sed 's/^/    /' "$CLIENT_CONFIG"
    echo

    printf '%sURI for SagerNet-family Android clients%s\n' "$C_BOLD" "$C_RST"
    printf '  %s\n' "$uri"
    echo
    printf '  QR:\n'
    echo
    qrencode -t UTF8 -m 2 "$uri" | sed 's/^/    /'
    echo

    printf '%ssing-box config%s\n' "$C_BOLD" "$C_RST"
    printf '  saved to: %s\n' "$SINGBOX_CONFIG"
    printf '  contents:\n'
    sed 's/^/    /' "$SINGBOX_CONFIG"
    echo

    if [[ "$MASK_SITE" == "$DEFAULT_MASK_SITE" ]]; then
        printf '%s%sNOTE — mask site is the default (%s)%s\n' "$C_BOLD" "$C_YELLOW" "$DEFAULT_MASK_SITE" "$C_RST"
        printf '  For per-VPS fingerprint hygiene, pick a cover site whose TLS profile matches\n'
        printf '  your IP-subnet neighbours. Use https://github.com/XTLS/RealiTLScanner from\n'
        printf '  a different machine, then re-run this script with NAIVE_MASK_SITE=https://...\n'
        echo
    fi

    printf '%s%sIMPORTANT — surviving x-ui-pro re-runs%s\n' "$C_BOLD" "$C_YELLOW" "$C_RST"
    printf '  x-ui-pro.sh wipes /etc/nginx/stream-enabled/* and sites-{available,enabled}/* on every run.\n'
    printf '  After any re-run of x-ui-pro.sh, repair the SNI route with:\n'
    printf '      wget -qO- https://raw.githubusercontent.com/Ieveltyanna/naive-caddy-installer/main/3x-ui/setup.sh | sudo NAIVE_REPAIR=1 bash\n'
    printf '  This re-injects the Naive SNI route into stream.conf without touching credentials.\n'
    printf '  /etc/nginx/conf.d/naive-acme.conf and /etc/cron.d/naive-cert-renew survive on their own.\n'
    echo
    printf '%sService management%s\n' "$C_BOLD" "$C_RST"
    printf '  systemctl status caddy\n'
    printf '  journalctl -u caddy -f\n'
    printf '  cat %s\n' "$CRED_FILE"
    echo
}

#─────────────────────────────────────────────────────────────────────────────
# Repair mode
#─────────────────────────────────────────────────────────────────────────────

# Re-applies just the nginx pieces (stream.conf + conf.d/naive-acme.conf) and
# reloads. Intended for use AFTER x-ui-pro re-runs and clobbers our config.
repair_mode() {
    log "REPAIR mode — re-applying nginx fragments without touching Caddy/creds."

    [[ -s "$STATE_FILE" ]] || die "No state file at $STATE_FILE. Run a full install first."
    # shellcheck disable=SC1090
    . "$STATE_FILE"

    DOMAIN="$NAIVE_DOMAIN"
    PANEL_DOMAIN="$NAIVE_PANEL_DOMAIN"
    REALITY_DOMAIN="$NAIVE_REALITY_DOMAIN"
    BACKEND_PORT="$NAIVE_BACKEND_PORT"
    MASK_SITE="$NAIVE_MASK_SITE"

    log "  Naive domain:   $DOMAIN"
    log "  Panel domain:   $PANEL_DOMAIN"
    log "  Reality domain: $REALITY_DOMAIN"
    log "  Backend port:   $BACKEND_PORT"

    check_x_ui_pro

    # Re-detect domains in case x-ui-pro install was rebuilt with different domains.
    detect_existing_domains
    if [[ "$PANEL_DOMAIN" != "$NAIVE_PANEL_DOMAIN" || "$REALITY_DOMAIN" != "$NAIVE_REALITY_DOMAIN" ]]; then
        warn "x-ui-pro domains changed since last install:"
        warn "  was:  panel=$NAIVE_PANEL_DOMAIN  reality=$NAIVE_REALITY_DOMAIN"
        warn "  now:  panel=$PANEL_DOMAIN        reality=$REALITY_DOMAIN"
        confirm "Update state and continue" default-yes || die "Aborted."
    fi

    write_acme_server_block
    write_stream_conf
    write_state_file

    if systemctl is-active --quiet caddy; then
        log "Reloading caddy..."
        systemctl reload caddy || systemctl restart caddy
    else
        warn "caddy.service is not active — starting it."
        systemctl start caddy
    fi

    ok "Repair complete. Public endpoint: https://${DOMAIN} (via nginx :443 SNI)"
}

#─────────────────────────────────────────────────────────────────────────────
# Main
#─────────────────────────────────────────────────────────────────────────────

main() {
    check_root
    detect_os
    ARCH="$(detect_arch)"
    ok "Architecture: $ARCH"

    if [[ "${NAIVE_REPAIR:-0}" == "1" ]]; then
        repair_mode
        exit 0
    fi

    install_dependencies

    check_x_ui_pro
    detect_existing_domains

    gather_inputs

    echo
    log "About to install NaiveProxy on this server, behind the existing x-ui-pro nginx:"
    log "  Naive domain:   $DOMAIN"
    log "  Panel domain:   $PANEL_DOMAIN     (already in use by x-ui-pro)"
    log "  Reality domain: $REALITY_DOMAIN   (already in use by x-ui-pro)"
    log "  Mask site:      $MASK_SITE"
    log "  Backend port:   127.0.0.1:${BACKEND_PORT}"
    echo
    confirm "Proceed" default-yes || die "Aborted by user."

    check_dns "$DOMAIN"
    check_backend_port_free "$BACKEND_PORT"

    if maybe_reuse_credentials; then
        log "Reusing credentials from existing $CADDYFILE"
    else
        generate_credentials
    fi

    ensure_caddy_binary

    write_acme_server_block
    issue_certificate

    write_caddyfile
    write_systemd_unit

    write_stream_conf
    write_renewal_artifacts
    write_state_file

    start_caddy
    wait_for_caddy_active

    save_credentials_file
    write_client_config
    write_singbox_config
    print_summary
}

main "$@"
