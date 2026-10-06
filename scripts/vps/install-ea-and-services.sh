#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/opt/xauusd-mt5-demo
PREFIX=/home/perrucci/.mt5
MT5_DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"
EA_DIR="$MT5_DIR/MQL5/Experts/XAUUSD"
EA_SRC="$EA_DIR/SignalBridge.mq5"
EA_EX5="$EA_DIR/SignalBridge.ex5"
COMPILE_LOG="$EA_DIR/SignalBridge.log"
WINE=/opt/wine-devel/bin/wine
WINEPATH=/opt/wine-devel/bin/winepath
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
EA_SRC_WIN="$(sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINEPATH" -w "$EA_SRC")"
MQL5_WIN="$(sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINEPATH" -w "$MT5_DIR/MQL5")"

printf '  source: %s\n' "$EA_SRC_WIN"
printf '  include: %s\n' "$MQL5_WIN"

# MetaEditor command-line parsing is strict. Keep the quotes inside the actual
# Windows-style argument, matching /compile:"path" /include:"path" /log.
set +e
timeout --signal=TERM --kill-after=10s 120s \
  sudo -u perrucci env \
    HOME=/home/perrucci \
    WINEPREFIX="$PREFIX" \
    WINEDEBUG=-all \
    PATH=/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    xvfb-run -a "$WINE" "$METAEDITOR" \
      "/compile:\"$EA_SRC_WIN\"" \
      "/include:\"$MQL5_WIN\"" \
      /log
compile_rc=$?
set -e

# Give MetaEditor/Wine a moment to flush the .ex5 and .log before stopping its wineserver.
sleep 3

if [[ ! -f "$EA_EX5" ]]; then
  # Some MetaEditor builds can place command-line output elsewhere. Locate it
  # before declaring failure and copy only an exact SignalBridge.ex5 match.
  FOUND_EX5="$(find "$MT5_DIR/MQL5" -type f -name 'SignalBridge.ex5' -print -quit 2>/dev/null || true)"
  if [[ -n "$FOUND_EX5" && "$FOUND_EX5" != "$EA_EX5" ]]; then
    echo "MetaEditor produced EX5 at unexpected path: $FOUND_EX5"
    install -m 0644 -o perrucci -g perrucci "$FOUND_EX5" "$EA_EX5"
  fi
fi

if [[ ! -f "$EA_EX5" ]]; then
  echo "EA compilation failed (rc=$compile_rc); no $EA_EX5 was produced" >&2
  echo "MetaEditor logs found:" >&2
  find "$MT5_DIR/MQL5" -maxdepth 6 -type f \( -iname 'SignalBridge*.log' -o -iname '*.log' \) -printf '  %p\n' 2>/dev/null | tail -n 30 >&2 || true
  if [[ -f "$COMPILE_LOG" ]]; then
    echo "----- MetaEditor compile log -----" >&2
    cat "$COMPILE_LOG" >&2 || true
    echo "----------------------------------" >&2
  fi
  echo "SignalBridge outputs found:" >&2
  find "$MT5_DIR/MQL5" -maxdepth 6 -type f -iname 'SignalBridge*' -printf '  %p\n' 2>/dev/null >&2 || true
  sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true
  exit 1
fi

sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true
sleep 2

printf 'EA compiled: %s\n' "$EA_EX5"
if [[ -f "$COMPILE_LOG" ]]; then
  tail -n 30 "$COMPILE_LOG" || true
fi

printf 'Preparing Linux bridge config...\n'
python3 - "$ROOT/config.example.json" "$ROOT/config.json" <<'PY'
import json
import sys
from pathlib import Path

example_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])
defaults = json.loads(example_path.read_text(encoding="utf-8"))
current = {}
if config_path.exists():
    current = json.loads(config_path.read_text(encoding="utf-8"))
merged = {**defaults, **current}
# V2 state sync must be explicitly enabled after the VPS deploy key has write access.
merged["auto_state_push"] = bool(current.get("auto_state_push", defaults.get("auto_state_push", False)))
config_path.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
PY
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
