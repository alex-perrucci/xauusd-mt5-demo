#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/opt/xauusd-mt5-demo
PREFIX=/home/perrucci/.mt5
WINE=/opt/wine-devel/bin/wine
WINESERVER=/opt/wine-devel/bin/wineserver

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -d "$ROOT/.git" ]] || { echo "repo missing at $ROOT" >&2; exit 1; }

printf 'Stopping old experiment services...\n'
for svc in xauusd-poller xauusd-mt5 xauusd-xvfb; do
  systemctl stop "$svc.service" >/dev/null 2>&1 || true
done
if [[ -x "$WINESERVER" ]]; then
  sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true
fi
sleep 2

printf 'Removing only the old XAUUSD MT5 runtime...\n'
rm -rf "$PREFIX" /etc/xauusd-mt5-demo
apt-get clean

printf 'Installing deterministic Wine/Xvfb runtime...\n'
bash "$ROOT/scripts/vps/bootstrap-wine.sh"

printf 'Installing a fresh MetaTrader 5 prefix under Wine 11.16...\n'
bash "$ROOT/scripts/vps/install-mt5.sh"

printf 'Installing/compiling EA and services...\n'
bash "$ROOT/scripts/vps/install-ea-and-services.sh"
