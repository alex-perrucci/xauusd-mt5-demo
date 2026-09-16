#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/opt/xauusd-mt5-demo
PREFIX=/home/perrucci/.mt5
MT5_DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"
EA_DIR="$MT5_DIR/MQL5/Experts/XAUUSD"
EA_SRC="$EA_DIR/SignalBridge.mq5"
EA_EX5="$EA_DIR/SignalBridge.ex5"
COMPILE_LOG="$EA_DIR/SignalBridge.compile.log"
WINE=/opt/wine-devel/bin/wine
WINESERVER=/opt/wine-devel/bin/wineserver

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -d "$ROOT/.git" ]] || { echo "repo missing at $ROOT" >&2; exit 1; }
[[ -f "$MT5_DIR/terminal64.exe" ]] || { echo "MT5 terminal missing: $MT5_DIR/terminal64.exe" >&2; exit 1; }
[[ -x "$WINE" ]] || { echo "Wine missing: $WINE" >&2; exit 1; }

# MetaQuotes has shipped both MetaEditor64.exe and metaeditor64.exe spellings.
# Linux filesystems are case-sensitive even though Windows is not, so detect it.
METAEDITOR="$(find "$MT5_DIR" -maxdepth 2 -type f -iname 'metaeditor64.exe' -print -quit)"
if [[ -z "$METAEDITOR" ]]; then
  echo "MetaEditor64.exe was not found under: $MT5_DIR" >&2
  echo "Executables present:" >&2
  find "$MT5_DIR" -maxdepth 2 -type f -iname '*.exe' -printf '  %p\n' >&2 || true
  exit 1
fi
printf 'MetaEditor detected: %s\n' "$METAEDITOR"

printf 'Installing MQL5 Expert Advisor source...\n'
install -d -o perrucci -g perrucci -m 0755 "$EA_DIR"
install -m 0644 -o perrucci -g perrucci "$ROOT/ea/SignalBridge.mq5" "$EA_SRC"
rm -f "$EA_EX5" "$COMPILE_LOG"

printf 'Compiling SignalBridge with MetaEditor...\n'
EA_SRC_WIN='C:\\Program Files\\MetaTrader 5\\MQL5\\Experts\\XAUUSD\\SignalBridge.mq5'
COMPILE_LOG_WIN='C:\\Program Files\\MetaTrader 5\\MQL5\\Experts\\XAUUSD\\SignalBridge.compile.log'
set +e
timeout --signal=TERM --kill-after=10s 120s \
  sudo -u perrucci env \
    HOME=/home/perrucci \
    WINEPREFIX="$PREFIX" \
    WINEDEBUG=-all \
    PATH=/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    xvfb-run -a "$WINE" "$METAEDITOR" "/compile:$EA_SRC_WIN" "/log:$COMPILE_LOG_WIN"
compile_rc=$?
set -e

sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true
sleep 2

if [[ ! -f "$EA_EX5" ]]; then
  echo "EA compilation failed (rc=$compile_rc); no $EA_EX5 was produced" >&2
  if [[ -f "$COMPILE_LOG" ]]; then
    echo "----- MetaEditor compile log -----" >&2
    cat "$COMPILE_LOG" >&2 || true
    echo "----------------------------------" >&2
  fi
  exit 1
fi
printf 'EA compiled: %s\n' "$EA_EX5"
if [[ -f "$COMPILE_LOG" ]]; then
  tail -n 20 "$COMPILE_LOG" || true
fi

printf 'Preparing Linux bridge config...\n'
if [[ ! -f "$ROOT/config.json" ]]; then
  cp "$ROOT/config.example.json" "$ROOT/config.json"
fi
chown perrucci:perrucci "$ROOT/config.json"
chmod 0600 "$ROOT/config.json"
python3 -m py_compile "$ROOT/bridge/poller.py"

printf 'Installing systemd services without starting trading...\n'
bash "$ROOT/scripts/vps/install-services.sh"

install -d -m 0700 /etc/xauusd-mt5-demo
install -m 0600 "$ROOT/deploy/mt5.env.example" /etc/xauusd-mt5-demo/mt5.env.example

printf '\nEA/runtime setup complete. Nothing is trading yet.\n'
printf 'Wine: '; "$WINE" --version
printf 'MT5: %s\n' "$MT5_DIR/terminal64.exe"
printf 'EA:  %s\n' "$EA_EX5"
printf 'Disk:\n'; df -h /
printf '\nNext: copy /etc/xauusd-mt5-demo/mt5.env.example to mt5.env, fill DEMO credentials, then run:\n'
printf '  sudo bash %s/scripts/vps/configure-demo.sh\n' "$ROOT"
