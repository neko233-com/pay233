#!/bin/sh
set -eu

# pay233-server installer
# curl -fsSL https://raw.githubusercontent.com/neko233-com/pay233/main/scripts/install-server.sh | sh
# curl -fsSL https://raw.githubusercontent.com/neko233-com/pay233/main/scripts/install-server.sh | sh -s -- v0.1.0

VERSION="${1:-latest}"
REPO="${PAY233_SERVER_REPO:-neko233-com/pay233-server}"
BINARY_NAME="pay233-server"
INSTALL_DIR="${PAY233_SERVER_INSTALL:-/usr/local/bin}"
CONFIG_DIR="${PAY233_SERVER_CONFIG_DIR:-/etc/pay233}"
CONFIG_FILE="${PAY233_SERVER_CONFIG:-${CONFIG_DIR}/config.json}"
LISTEN_ADDR="${PAY233_SERVER_ADDR:-:5500}"
SIGNING_SECRET="${PAY233_SIGNING_SECRET:-}"
SERVICE_NAME="${PAY233_SERVER_SERVICE:-pay233-server}"
LOG_DIR="${PAY233_SERVER_LOG_DIR:-${CONFIG_DIR}/logs}"
DATA_DIR="${PAY233_SERVER_DATA_DIR:-${CONFIG_DIR}/data}"
ADMIN_USERNAME="${PAY233_ADMIN_USERNAME:-root}"
ADMIN_PASSWORD="${PAY233_ADMIN_PASSWORD:-root}"

detect_os() {
    case "$(uname -s)" in
        Linux*) echo "linux" ;;
        Darwin*) echo "darwin" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *) echo "unsupported" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) echo "amd64" ;;
    esac
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing required command: $1" >&2
        exit 1
    }
}

normalize_version() {
    v="${1#v}"
    v="${v#V}"
    echo "$v"
}

get_latest_version() {
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null |
        grep '"tag_name":' | head -1 | sed -E 's/.*"v([^"]+)".*/\1/'
}

run_privileged() {
    if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "need root permission for: $*" >&2
        exit 1
    fi
}

write_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "Config exists: $CONFIG_FILE"
        return
    fi

    secret="$SIGNING_SECRET"
    if [ -z "$secret" ]; then
        if command -v openssl >/dev/null 2>&1; then
            secret="$(openssl rand -hex 32)"
        else
            secret="$(date +%s)-pay233-change-me"
        fi
    fi
    admin_secret="${PAY233_ADMIN_SESSION_SECRET:-}"
    if [ -z "$admin_secret" ]; then
        if command -v openssl >/dev/null 2>&1; then
            admin_secret="$(openssl rand -hex 32)"
        else
            admin_secret="$(date +%s)-pay233-admin-change-me"
        fi
    fi

    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
{
  "http": {
    "addr": "${LISTEN_ADDR}"
  },
  "api": {
    "signing_secret": "${secret}"
  },
  "admin": {
    "username": "${ADMIN_USERNAME}",
    "password": "${ADMIN_PASSWORD}",
    "session_secret": "${admin_secret}"
  },
  "logging": {
    "dir": "${LOG_DIR}",
    "retention_days": 31
  },
  "storage": {
    "payments_path": "${DATA_DIR}/payments.jsonl",
    "admin_users_path": "${DATA_DIR}/admin-users.json",
    "audit_path": "${DATA_DIR}/audit.jsonl",
    "audit_retention_days": 31
  },
  "monitor": {
    "channel_health_interval_seconds": 60,
    "channel_health_timeout_seconds": 5
  },
  "channels": [
    {
      "name": "mock",
      "provider": "mock",
      "enabled": true
    },
    {
      "name": "wechat",
      "provider": "wechat_pay",
      "enabled": true
    },
    {
      "name": "alipay",
      "provider": "alipay",
      "enabled": true
    },
    {
      "name": "stripe",
      "provider": "stripe",
      "enabled": true
    },
    {
      "name": "paypal",
      "provider": "paypal",
      "enabled": true
    },
    {
      "name": "google-pay",
      "provider": "google_pay",
      "enabled": true
    },
    {
      "name": "apple-iap",
      "provider": "apple_iap",
      "enabled": true
    },
    {
      "name": "unionpay",
      "provider": "unionpay",
      "enabled": true
    }
  ]
}
EOF
    run_privileged mkdir -p "$CONFIG_DIR"
    run_privileged mv "$tmp" "$CONFIG_FILE"
    run_privileged chmod 600 "$CONFIG_FILE"
    echo "Created config: $CONFIG_FILE"
}

install_systemd() {
    [ "$(detect_os)" = "linux" ] || return
    command -v systemctl >/dev/null 2>&1 || return

    unit="/etc/systemd/system/${SERVICE_NAME}.service"
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=pay233 unified payment server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/${BINARY_NAME} -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
WorkingDirectory=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
    run_privileged mv "$tmp" "$unit"
    run_privileged systemctl daemon-reload
    run_privileged systemctl enable --now "$SERVICE_NAME"
    echo "Installed systemd service: $SERVICE_NAME"
}

health_url() {
    case "$LISTEN_ADDR" in
        :*) echo "http://127.0.0.1${LISTEN_ADDR}/healthz" ;;
        *) echo "http://${LISTEN_ADDR}/healthz" ;;
    esac
}

need_cmd curl

OS="$(detect_os)"
ARCH="$(detect_arch)"
[ "$OS" = "unsupported" ] && echo "Unsupported OS" >&2 && exit 1

if [ "$VERSION" = "latest" ]; then
    VERSION="$(get_latest_version)"
fi
VERSION="$(normalize_version "$VERSION")"

ext=""
[ "$OS" = "windows" ] && ext=".exe"
asset="${BINARY_NAME}-${OS}-${ARCH}${ext}"
url="https://github.com/${REPO}/releases/download/v${VERSION}/${asset}"
target="${BINARY_NAME}${ext}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Downloading $url ..."
curl -fsSL "$url" -o "${tmpdir}/${target}"
chmod +x "${tmpdir}/${target}" 2>/dev/null || true

run_privileged mkdir -p "$INSTALL_DIR"
run_privileged mv "${tmpdir}/${target}" "${INSTALL_DIR}/${target}"
run_privileged chmod +x "${INSTALL_DIR}/${target}" 2>/dev/null || true
write_config
install_systemd

echo "Installed ${BINARY_NAME} v${VERSION} -> ${INSTALL_DIR}/${target}"
echo "Config: ${CONFIG_FILE}"
echo "Health: curl -fsS $(health_url)"
