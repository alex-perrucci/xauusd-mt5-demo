#!/usr/bin/env bash
set -Eeuo pipefail

export HOME=/home/perrucci
export DISPLAY=:99
export WINEPREFIX=/home/perrucci/.mt5
export WINEDEBUG=-all
export PATH=/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WINE=/opt/wine-devel/bin/wine
WINEPATH=/opt/wine-devel/bin/winepath
WINESERVER=/opt/wine-devel/bin/wineserver
TERMINAL='/home/perrucci/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe'
CONFIG='/home/perrucci/.mt5/drive_c/xauusd/terminal.ini'

[[ -x "$WINE" ]] || { echo "wine missing" >&2; exit 1; }
[[ -x "$WINESERVER" ]] || { echo "wineserver missing" >&2; exit 1; }
[[ -f "$TERMINAL" ]] || { echo "terminal64.exe missing" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "terminal config missing: $CONFIG" >&2; exit 1; }

CONFIG_WIN="$($WINEPATH -w "$CONFIG")"

cleanup() {
  trap - TERM INT EXIT
  "$WINESERVER" -k >/dev/null 2>&1 || true
}
trap cleanup TERM INT EXIT

# A stale wineserver/terminal can make a fresh terminal64.exe invocation hand
# off to the old instance and exit 0 immediately. This prefix is dedicated to
# this demo, so clear stale Wine processes before every supervised start.
"$WINESERVER" -k >/dev/null 2>&1 || true
sleep 2

echo "starting supervised MT5: $TERMINAL /portable /config:$CONFIG_WIN"

"$WINE" "$TERMINAL" /portable "/config:$CONFIG_WIN" &
launcher_pid=$!

# Give MetaTrader time to initialize/re-parent. The Wine launcher PID is not
# authoritative; the actual terminal64.exe process is.
deadline=$((SECONDS + 20))
while (( SECONDS < deadline )); do
  if pgrep -u "$(id -u)" -f '[/]MetaTrader 5/terminal64\.exe|terminal64\.exe' >/dev/null 2>&1; then
    echo "MT5 terminal process detected"
    break
  fi
  if ! kill -0 "$launcher_pid" >/dev/null 2>&1; then
    wait "$launcher_pid" || true
  fi
  sleep 1
done

if ! pgrep -u "$(id -u)" -f '[/]MetaTrader 5/terminal64\.exe|terminal64\.exe' >/dev/null 2>&1; then
  echo "MT5 terminal process not present after startup grace period" >&2
  wait "$launcher_pid" 2>/dev/null || true
  exit 1
fi

# Keep systemd tied to the real Windows process lifecycle rather than the Wine
# launcher lifecycle. If MT5 disappears, fail so Restart=always can recover.
while true; do
  if ! pgrep -u "$(id -u)" -f '[/]MetaTrader 5/terminal64\.exe|terminal64\.exe' >/dev/null 2>&1; then
    echo "MT5 terminal process disappeared" >&2
    wait "$launcher_pid" 2>/dev/null || true
    exit 1
  fi
  sleep 5
done
