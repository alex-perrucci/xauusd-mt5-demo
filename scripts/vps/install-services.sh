#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="/opt/xauusd-mt5-demo"
SERVICE_DIR="/etc/systemd/system"
WINE_BIN="/opt/wine-devel/bin/wine"
WINEPATH_BIN="/opt/wine-devel/bin/winepath"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/vps/install-services.sh" >&2
  exit 1
fi

if [[ ! -d "${REPO_ROOT}/.git" ]]; then
  echo "Expected repository at ${REPO_ROOT}" >&2
  exit 1
fi

if ! id perrucci >/dev/null 2>&1; then
  echo "Expected VPS user 'perrucci' does not exist" >&2
  exit 1
fi

for cmd in Xvfb python3 git; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

[[ -x "${WINE_BIN}" ]] || { echo "Missing WineHQ devel binary: ${WINE_BIN}" >&2; exit 1; }
[[ -x "${WINEPATH_BIN}" ]] || { echo "Missing WineHQ winepath binary: ${WINEPATH_BIN}" >&2; exit 1; }

install -m 0644 "${REPO_ROOT}/deploy/vps/xauusd-xvfb.service" "${SERVICE_DIR}/xauusd-xvfb.service"
install -m 0644 "${REPO_ROOT}/deploy/vps/xauusd-mt5.service" "${SERVICE_DIR}/xauusd-mt5.service"
install -m 0644 "${REPO_ROOT}/deploy/vps/xauusd-poller.service" "${SERVICE_DIR}/xauusd-poller.service"

if [[ ! -f "${REPO_ROOT}/config.json" ]]; then
  cp "${REPO_ROOT}/config.example.json" "${REPO_ROOT}/config.json"
fi

chown -R perrucci:perrucci "${REPO_ROOT}"
chmod 600 "${REPO_ROOT}/config.json"

systemctl daemon-reload
systemctl enable xauusd-xvfb.service xauusd-mt5.service xauusd-poller.service

echo "Services installed and enabled."
echo "Do not start xauusd-mt5/xauusd-poller until MT5, Windows Python and the demo login are configured."
