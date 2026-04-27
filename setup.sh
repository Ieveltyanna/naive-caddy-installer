#!/usr/bin/env bash
# NaiveProxy + Caddy auto-setup for Debian/Ubuntu VPS.
# Repository: https://github.com/Ieveltyanna/naive-caddy-installer

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
    # confirm "Question" [default-yes|default-no]
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
    # prompt_value "Question" [default]
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
readonly CADDY_BIN="/usr/bin/caddy"
readonly CADDY_DIR="/etc/caddy"
readonly CADDYFILE="${CADDY_DIR}/Caddyfile"
readonly CRED_FILE="${CADDY_DIR}/credentials.txt"
readonly CLIENT_CONFIG="/root/naive-client-config.json"
readonly SYSTEMD_UNIT="/etc/systemd/system/caddy.service"
readonly TMP_BUILD_DIR="/root/tmp"
readonly GO_INSTALL_DIR="/usr/local/go"

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
    # Try multiple endpoints; first one wins.
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
    local domain="$1" external_ip resolved_ip
    log "Checking DNS for $domain..."

    if ! external_ip="$(get_external_ip)"; then
        warn "Could not detect this server's external IP — skipping DNS check."
        return 0
    fi
    log "Server external IP: $external_ip"

    require_cmd dig
    resolved_ip="$(dig +short A "$domain" @1.1.1.1 | tail -n1)"
    if [[ -z "$resolved_ip" ]]; then
        warn "Domain $domain has no A-record (or DNS not yet propagated)."
        confirm "Continue anyway (ACME will fail until DNS resolves)" default-no \
            || die "Aborted by user. Configure DNS A-record first."
        return 0
    fi

    if [[ "$resolved_ip" != "$external_ip" ]]; then
        warn "DNS mismatch: $domain → $resolved_ip, but server IP is $external_ip"
        warn "Possible causes: A-record not updated yet; Cloudflare orange-cloud (must be grey)."
        confirm "Continue anyway" default-no \
            || die "Aborted by user. Fix DNS A-record first."
    else
        ok "DNS check passed: $domain → $external_ip"
    fi
}

check_ports() {
    local port busy_pid busy_proc
    require_cmd ss
    for port in 80 443; do
        busy_pid="$(ss -tlnpH "sport = :${port}" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1 || true)"
        if [[ -n "$busy_pid" ]]; then
            busy_proc="$(ps -p "$busy_pid" -o comm= 2>/dev/null || echo unknown)"
            warn "Port :$port is occupied by PID $busy_pid ($busy_proc)"
            if [[ "$busy_proc" == "caddy" ]]; then
                log "It's a previous Caddy process — will be replaced by systemd unit."
                continue
            fi
            confirm "Stop process $busy_proc (PID $busy_pid) and continue" default-no \
                || die "Aborted by user. Free port :$port manually and retry."
            kill "$busy_pid" 2>/dev/null || true
            sleep 2
            kill -9 "$busy_pid" 2>/dev/null || true
        fi
    done
    ok "Ports :80 and :443 are free"
}

handle_existing_caddy() {
    # Returns mode via stdout: "rebuild" | "reconfigure" | "fresh"
    if [[ ! -x "$CADDY_BIN" ]] && ! systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        echo "fresh"
        return 0
    fi

    warn "Caddy is already installed on this system." >&2
    if systemctl is-active --quiet caddy 2>/dev/null; then
        warn "caddy.service is currently active." >&2
    fi

    echo "" >&2
    echo "Choose action:" >&2
    echo "  1) Rebuild Caddy from sources, regenerate Caddyfile, restart" >&2
    echo "  2) Keep existing Caddy binary, regenerate Caddyfile, restart" >&2
    echo "  3) Exit, leave system untouched" >&2
    echo "" >&2

    local choice
    while true; do
        read -r -p "Enter 1, 2 or 3: " choice </dev/tty
        case "$choice" in
            1) echo "rebuild";     return 0 ;;
            2) echo "reconfigure"; return 0 ;;
            3) die "Exited by user choice." ;;
            *) echo "Invalid choice." >&2 ;;
        esac
    done
}

#─────────────────────────────────────────────────────────────────────────────
# Inputs
#─────────────────────────────────────────────────────────────────────────────

gather_inputs() {
    # Populates globals: DOMAIN, MASK_SITE
    if [[ -n "${NAIVE_DOMAIN:-}" ]]; then
        DOMAIN="$NAIVE_DOMAIN"
        log "Domain from env: $DOMAIN"
    else
        DOMAIN="$(prompt_value 'Your domain (must point to this server, no Cloudflare proxy)')"
    fi

    if [[ -n "${NAIVE_MASK_SITE:-}" ]]; then
        MASK_SITE="$NAIVE_MASK_SITE"
        log "Mask site from env: $MASK_SITE"
    else
        MASK_SITE="$(prompt_value 'Mask site URL (used as cover when probed; see README)' "$DEFAULT_MASK_SITE")"
    fi

    # Sanity-check mask-site format.
    [[ "$MASK_SITE" =~ ^https?:// ]] || die "Mask site must start with http:// or https://: $MASK_SITE"
}

#─────────────────────────────────────────────────────────────────────────────
# Install steps
#─────────────────────────────────────────────────────────────────────────────

install_dependencies() {
    log "Installing apt dependencies..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        curl wget ca-certificates \
        dnsutils iproute2 procps \
        openssl tar \
        qrencode >/dev/null
    ok "apt dependencies installed"
}

enable_bbr() {
    log "Enabling TCP BBR..."
    local sysctl_file=/etc/sysctl.conf
    local changed=0
    if ! grep -q '^net.core.default_qdisc=fq' "$sysctl_file" 2>/dev/null; then
        echo 'net.core.default_qdisc=fq' >> "$sysctl_file"
        changed=1
    fi
    if ! grep -q '^net.ipv4.tcp_congestion_control=bbr' "$sysctl_file" 2>/dev/null; then
        echo 'net.ipv4.tcp_congestion_control=bbr' >> "$sysctl_file"
        changed=1
    fi
    if [[ "$changed" -eq 1 ]]; then
        sysctl -p >/dev/null
    fi
    local cc
    cc="$(sysctl -n net.ipv4.tcp_congestion_control)"
    if [[ "$cc" == "bbr" ]]; then
        ok "BBR active (tcp_congestion_control=$cc)"
    else
        warn "BBR not active (tcp_congestion_control=$cc). Kernel may be too old; continuing."
    fi
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
    BUILT_CADDY_BIN="${build_dir}/caddy"
    popd >/dev/null
    ok "Caddy built: $BUILT_CADDY_BIN"
}

install_caddy_binary() {
    log "Installing Caddy binary to ${CADDY_BIN}..."
    if systemctl is-active --quiet caddy 2>/dev/null; then
        log "Stopping running caddy.service before binary swap..."
        systemctl stop caddy
    fi
    install -m 0755 "$BUILT_CADDY_BIN" "$CADDY_BIN"
    ok "Installed: $($CADDY_BIN version | head -n1)"
}

generate_credentials() {
    log "Generating credentials..."
    NAIVE_USER="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    NAIVE_PASS="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    [[ ${#NAIVE_USER} -eq 16 && ${#NAIVE_PASS} -eq 16 ]] \
        || die "Failed to generate credentials"
    ok "Credentials generated"
}

write_caddyfile() {
    log "Writing ${CADDYFILE}..."
    mkdir -p "$CADDY_DIR"
    cat > "$CADDYFILE" <<EOF
:443, ${DOMAIN}
tls

route {
  forward_proxy {
    basic_auth ${NAIVE_USER} ${NAIVE_PASS}
    hide_ip
    hide_via
    probe_resistance
  }

  reverse_proxy ${MASK_SITE} {
    header_up Host {upstream_hostport}
    header_up X-Forwarded-Host {host}
  }
}
EOF
    chmod 600 "$CADDYFILE"
    ok "Caddyfile written"
}

write_systemd_unit() {
    log "Writing ${SYSTEMD_UNIT}..."
    cat > "$SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=Caddy with NaiveProxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    ok "systemd unit written"
}

start_caddy() {
    log "Enabling and starting caddy.service..."
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy
}

wait_for_caddy_active() {
    log "Waiting for Caddy to become active and obtain TLS certificate..."
    local i=0
    while (( i < 60 )); do
        if systemctl is-active --quiet caddy; then
            # Systemd reports active even before ACME finishes — probe TLS to confirm
            # cert issued. Drop -f so HTTP 4xx/5xx from the mask reverse_proxy still
            # counts as a successful TLS handshake.
            if curl -sS --max-time 5 -o /dev/null "https://${DOMAIN}" 2>/dev/null; then
                ok "Caddy is active and TLS endpoint responding"
                return 0
            fi
        elif systemctl is-failed --quiet caddy; then
            err "caddy.service failed. Last 50 log lines:"
            journalctl -u caddy -n 50 --no-pager >&2
            die "Aborting. Inspect logs above (often: ACME error, port conflict, DNS misconfig)."
        fi
        sleep 2
        ((i++))
    done
    warn "Caddy did not respond on https://${DOMAIN} within 120s."
    warn "Recent logs:"
    journalctl -u caddy -n 30 --no-pager >&2
    confirm "Continue anyway (cert may still be issuing)" default-no \
        || die "Aborted. Run 'journalctl -u caddy -f' to debug."
}

#─────────────────────────────────────────────────────────────────────────────
# Output
#─────────────────────────────────────────────────────────────────────────────

save_credentials_file() {
    cat > "$CRED_FILE" <<EOF
# NaiveProxy credentials — generated $(date -Iseconds)
# Domain:    ${DOMAIN}
# Mask site: ${MASK_SITE}
NAIVE_USER=${NAIVE_USER}
NAIVE_PASS=${NAIVE_PASS}
NAIVE_URL=naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=1#NaiveProxy
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

print_summary() {
    local uri="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=1#NaiveProxy"

    echo
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    printf '%s  NaiveProxy is up at https://%s%s\n' "$C_BOLD" "$DOMAIN" "$C_RST"
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    echo

    printf '%sCredentials%s\n' "$C_BOLD" "$C_RST"
    printf '  user: %s\n' "$NAIVE_USER"
    printf '  pass: %s\n' "$NAIVE_PASS"
    printf '  saved to: %s\n' "$CRED_FILE"
    echo

    printf '%sClient config (klzgrad/naive CLI)%s\n' "$C_BOLD" "$C_RST"
    printf '  saved to: %s\n' "$CLIENT_CONFIG"
    printf '  download CLI binary for your OS: https://github.com/klzgrad/naiveproxy/releases\n'
    printf '  run: ./naive %s\n' "$(basename "$CLIENT_CONFIG")"
    echo
    printf '  contents:\n'
    sed 's/^/    /' "$CLIENT_CONFIG"
    echo

    printf '%sURI for SagerNet-family Android clients%s (Exclave, NekoBox, sing-box-for-android via plugin)\n' "$C_BOLD" "$C_RST"
    printf '  %s\n' "$uri"
    echo
    printf '  QR (scan in Exclave → Add → From QR Code):\n'
    echo
    qrencode -t UTF8 -m 2 "$uri" | sed 's/^/    /'
    echo

    printf '%ssing-box outbound JSON%s (for Karing / sing-box-for-android — paste into outbounds[]):\n' "$C_BOLD" "$C_RST"
    cat <<EOF | sed 's/^/    /'
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
EOF
    echo

    printf '%sFinal check%s — from your client (after launching naive CLI):\n' "$C_BOLD" "$C_RST"
    printf '  curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.me\n'
    printf '  expected output: %s (this server)\n' "$(get_external_ip 2>/dev/null || echo "<this-server-IP>")"
    echo
    printf '%sService status%s — manage with:\n' "$C_BOLD" "$C_RST"
    printf '  systemctl status caddy\n'
    printf '  journalctl -u caddy -f\n'
    echo
}

#─────────────────────────────────────────────────────────────────────────────
# Main
#─────────────────────────────────────────────────────────────────────────────

main() {
    check_root
    detect_os
    ARCH="$(detect_arch)"
    ok "Architecture: $ARCH"

    gather_inputs
    echo
    log "About to set up NaiveProxy on this server with:"
    log "  Domain:    $DOMAIN"
    log "  Mask site: $MASK_SITE"
    echo
    confirm "Proceed" default-yes || die "Aborted by user."

    install_dependencies

    check_dns "$DOMAIN"
    check_ports

    MODE="$(handle_existing_caddy)"
    log "Install mode: $MODE"

    enable_bbr

    if [[ "$MODE" == "rebuild" || "$MODE" == "fresh" ]]; then
        install_go
        build_caddy
        install_caddy_binary
    fi

    generate_credentials
    write_caddyfile
    write_systemd_unit
    start_caddy
    wait_for_caddy_active

    save_credentials_file
    write_client_config
    print_summary
}

main "$@"
