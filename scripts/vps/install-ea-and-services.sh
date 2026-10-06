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

# MetaEditor under Wine is much more reliable in portable mode when launched
# from the MT5 installation directory and given an MQL5-relative source path.
REL_SRC='MQL5\\Experts\\XAUUSD\\SignalBridge.mq5'
rm -f "$EA_EX5" "$COMPILE_LOG"

set +e
(
  cd "$MT5_DIR"
  timeout --signal=TERM --kill-after=10s 120s \
    sudo -u perrucci env \
      HOME=/home/perrucci \
      WINEPREFIX="$PREFIX" \
      WINEDEBUG=-all \
      PATH=/opt/wine-devel/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      xvfb-run -a "$WINE" "$(basename "$METAEDITOR")" \
        /portable \
        "/compile:$REL_SRC" \
        /log
)
compile_rc=$?
set -e

# MetaEditor may return before Wine has flushed the compiler output.
for _ in $(seq 1 30); do
  [[ -f "$COMPILE_LOG" || -f "$EA_EX5" ]] && break
  sleep 1
done

print_compile_log() {
  [[ -f "$COMPILE_LOG" ]] || return 0
  echo "----- MetaEditor compile log -----"
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-16LE -t UTF-8 "$COMPILE_LOG" 2>/dev/null | tr -d '\r' || cat "$COMPILE_LOG"
  else
    cat "$COMPILE_LOG"
  fi
  echo "----------------------------------"
}

if [[ ! -f "$EA_EX5" ]]; then
  echo "EA compilation failed (rc=$compile_rc); no $EA_EX5 was produced" >&2
  if [[ -f "$COMPILE_LOG" ]]; then
    print_compile_log >&2
  else
    echo "MetaEditor produced no compile log either." >&2
  fi
  echo "SignalBridge outputs found:" >&2
  find "$MT5_DIR/MQL5" -maxdepth 6 -type f -iname 'SignalBridge*' -printf '  %p\n' 2>/dev/null >&2 || true
  sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true
  exit 1
fi

sudo -u perrucci env HOME=/home/perrucci WINEPREFIX="$PREFIX" "$WINESERVER" -k >/dev/null 2>&1 || true
sleep 2

printf 'EA compiled: %s\n' "$EA_EX5"
print_compile_log || true

DATA_DIR="$(bash "$ROOT/scripts/vps/resolve-data-dir.sh")"
RUNTIME_EA_DIR="$DATA_DIR/MQL5/Experts/XAUUSD"
RUNTIME_BRIDGE_DIR="$DATA_DIR/MQL5/Files/xauusd"

printf 'MT5 data directory: %s\n' "$DATA_DIR"
printf 'Installing EA into the actual MT5 data directory...\n'
install -d -o perrucci -g perrucci -m 0755 "$RUNTIME_EA_DIR"
install -d -o perrucci -g perrucci -m 0700 "$RUNTIME_BRIDGE_DIR"
install -m 0644 -o perrucci -g perrucci "$ROOT/ea/SignalBridge.mq5" "$RUNTIME_EA_DIR/SignalBridge.mq5"
install -m 0644 -o perrucci -g perrucci "$EA_EX5" "$RUNTIME_EA_DIR/SignalBridge.ex5"

printf 'Preparing Linux bridge config...\n'
python3 - "$ROOT/config.example.json" "$ROOT/config.json" "$DATA_DIR" <<'PY'
import json
import sys
from pathlib import Path

example_path = Path(sys.argv[1])
config_path = Path(sys.argv[2])
data_dir = Path(sys.argv[3])
defaults = json.loads(example_path.read_text(encoding="utf-8"))
current = {}
if config_path.exists():
    current = json.loads(config_path.read_text(encoding="utf-8"))
merged = {**defaults, **current}
bridge_dir = data_dir / "MQL5" / "Files" / "xauusd"
merged["bridge_file"] = str(bridge_dir / "signal.txt")
merged["ack_file"] = str(bridge_dir / "ack.txt")
merged["state_file"] = str(bridge_dir / "state.txt")
portable_bridge_dir = Path("/home/perrucci/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/xauusd")
merged["alternate_bridge_file"] = str(portable_bridge_dir / "signal.txt")
merged["alternate_ack_file"] = str(portable_bridge_dir / "ack.txt")
merged["alternate_state_file"] = str(portable_bridge_dir / "state.txt")
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
printf 'EA compile output: %s\n' "$EA_EX5"
printf 'EA runtime copy:   %s\n' "$RUNTIME_EA_DIR/SignalBridge.ex5"
printf 'Disk:\n'; df -h /
printf '\nNext: copy /etc/xauusd-mt5-demo/mt5.env.example to mt5.env, fill DEMO credentials, then run:\n'
printf '  sudo bash %s/scripts/vps/configure-demo.sh\n' "$ROOT"
