#!/usr/bin/env bash
set -Eeuo pipefail

export HOME=/home/perrucci
export DISPLAY=:99
export WINEPREFIX=/home/perrucci/.mt5
export WINEDEBUG=-all
export PATH=/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WINE=/opt/wine-devel/bin/wine
WINEPATH=/opt/wine-devel/bin/winepath
TERMINAL='/home/perrucci/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe'
CONFIG='/home/perrucci/.mt5/drive_c/xauusd/terminal.ini'

[[ -x "$WINE" ]] || { echo "wine missing" >&2; exit 1; }
[[ -f "$TERMINAL" ]] || { echo "terminal64.exe missing" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "terminal config missing: $CONFIG" >&2; exit 1; }

CONFIG_WIN="$($WINEPATH -w "$CONFIG")"
# This Wine installation uses MetaTrader's standard AppData data directory.
# Do not force /portable from Program Files; the EA and bridge are installed
# into the resolved AppData/MetaQuotes/Terminal/<id> directory instead.
exec "$WINE" "$TERMINAL" "/config:$CONFIG_WIN"
