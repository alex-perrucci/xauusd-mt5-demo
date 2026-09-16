#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/opt/xauusd-mt5-demo
PREFIX=/home/perrucci/.mt5
MT5_DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"
EA_DIR="$MT5_DIR/MQL5/Experts/XAUUSD"
EA_SRC="$EA_DIR/SignalBridge.mq5"
EA_EX5="$EA_DIR/SignalBridge.ex5"
METAEDITOR="$MT5_DIR/metaeditor64.exe"
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

printf 'Installing MQL5 Expert Advisor source...\n'
install -d -o perrucci -g perrucci -m 0755 "$EA_DIR"
install -m 0644 -o perrucci -g perrucci "$ROOT/ea/SignalBridge.mq5" "$EA_SRC"
[[ -f "$METAEDITOR" ]] || { echo "MetaEditor missing: $METAEDITOR" >&2; exit 1; }

printf 'Compiling SignalBridge with MetaEditor...\n'
EA_SRC_WIN='C:\Program Files\MetaTrader 5\MQL5\Experts\XAUUSD\SignalBridge.mq5'
set +e
timeout --signal=TERM --kill-after=10s 120s \
  sudo -u perrucci env \
    HOME=/home/perrucci \
    WINEPREFIX="$PREFIX" \
    WINEDEBUG=-all \
    PATH=/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    xvfb-run -a "$WINE" "$METAEDITOR" "/compile:$EA_SRC_WIN"
compile_rc=$?
set -e
sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true
sleep 2

if [[ ! -f "$EA_EX5" ]]; then
  echo "EA compilation failed (rc=$compile_rc); no $EA_EX5 was produced" >&2
  exit 1
fi
printf 'EA compiled: %s\n' "$EA_EX5"

printf 'Preparing Linux bridge config...\n'
cp "$ROOT/config.example.json" "$ROOT/config.json"
chown perrucci:perrucci "$ROOT/config.json"
chmod 0600 "$ROOT/config.json"
python3 -m py_compile "$ROOT/bridge/poller.py"

printf 'Installing systemd services without starting trading...\n'
bash "$ROOT/scripts/vps/install-services.sh"

install -d -m 0700 /etc/xauusd-mt5-demo
install -m 0600 "$ROOT/deploy/mt5.env.example" /etc/xauusd-mt5-demo/mt5.env.example

printf '\nClean setup complete. Nothing is trading yet.\n'
printf 'Wine: '; "$WINE" --version
printf 'MT5: %s\n' "$MT5_DIR/terminal64.exe"
printf 'EA:  %s\n' "$EA_EX5"
printf 'Disk:\n'; df -h /
printf '\nNext: copy /etc/xauusd-mt5-demo/mt5.env.example to mt5.env, fill DEMO credentials, then run:\n'
printf '  sudo bash %s/scripts/vps/configure-demo.sh\n' "$ROOT"
