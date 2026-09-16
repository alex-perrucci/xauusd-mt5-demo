#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/opt/xauusd-mt5-demo
SYSTEMD=/etc/systemd/system
EA_EX5='/home/perrucci/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/XAUUSD/SignalBridge.ex5'

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -d "$ROOT/.git" ]] || { echo "repo missing at $ROOT" >&2; exit 1; }
id perrucci >/dev/null 2>&1 || { echo "user perrucci missing" >&2; exit 1; }
command -v Xvfb >/dev/null || { echo "Xvfb missing" >&2; exit 1; }
[[ -x /opt/wine-devel/bin/wine ]] || { echo "Wine missing" >&2; exit 1; }
[[ -f "$EA_EX5" ]] || { echo "compiled EA missing: $EA_EX5" >&2; exit 1; }

install -m 0644 "$ROOT/deploy/vps/xauusd-xvfb.service" "$SYSTEMD/xauusd-xvfb.service"
install -m 0644 "$ROOT/deploy/vps/xauusd-mt5.service" "$SYSTEMD/xauusd-mt5.service"
install -m 0644 "$ROOT/deploy/vps/xauusd-poller.service" "$SYSTEMD/xauusd-poller.service"

if [[ ! -f "$ROOT/config.json" ]]; then
  cp "$ROOT/config.example.json" "$ROOT/config.json"
fi
chown perrucci:perrucci "$ROOT/config.json"
chmod 0600 "$ROOT/config.json"

systemctl daemon-reload
systemctl enable xauusd-xvfb.service xauusd-mt5.service xauusd-poller.service >/dev/null

echo "services installed and enabled; they are intentionally not started yet"
