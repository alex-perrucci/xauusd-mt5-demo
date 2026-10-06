#!/usr/bin/env bash
set -u

ROOT=/opt/xauusd-mt5-demo
PREFIX=/home/perrucci/.mt5
MT5_DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"
DATA_DIR="$(bash "$ROOT/scripts/vps/resolve-data-dir.sh" 2>/dev/null || true)"
EA_EX5="$DATA_DIR/MQL5/Experts/XAUUSD/SignalBridge.ex5"
BRIDGE_DIR="$DATA_DIR/MQL5/Files/xauusd"
FAILED=0

ok(){ printf 'OK   %s\n' "$*"; }
warn(){ printf 'WARN %s\n' "$*"; }
fail(){ printf 'FAIL %s\n' "$*"; FAILED=1; }

[[ -d "$ROOT/.git" ]] && ok "repo present" || fail "repo missing"
[[ -f "$ROOT/config.json" ]] && ok "Linux bridge config present" || warn "config.json missing"
[[ -x /opt/wine-devel/bin/wine ]] || fail "Wine missing"
if [[ -x /opt/wine-devel/bin/wine ]]; then
  version=$(/opt/wine-devel/bin/wine --version 2>/dev/null || true)
  [[ $version == wine-11.16* ]] && ok "$version" || fail "expected wine-11.16, got ${version:-unknown}"
fi
command -v Xvfb >/dev/null 2>&1 && ok "Xvfb present" || fail "Xvfb missing"
[[ -f "$MT5_DIR/terminal64.exe" ]] && ok "MT5 terminal present" || fail "MT5 terminal missing"
[[ -n "$DATA_DIR" && -d "$DATA_DIR" ]] && ok "MT5 data directory: $DATA_DIR" || fail "MT5 data directory unresolved"
METAEDITOR="$(find "$MT5_DIR" -maxdepth 2 -type f -iname 'metaeditor64.exe' -print -quit)"
[[ -n "$METAEDITOR" ]] && ok "MetaEditor present: $METAEDITOR" || fail "MetaEditor missing"
[[ -f "$EA_EX5" ]] && ok "SignalBridge.ex5 installed in MT5 data directory" || fail "runtime SignalBridge.ex5 missing"
[[ -f /etc/xauusd-mt5-demo/mt5.env ]] && ok "demo credential file present" || warn "demo credential file not configured yet"
[[ -f "$PREFIX/drive_c/xauusd/terminal.ini" ]] && ok "MT5 startup config rendered" || warn "terminal.ini not rendered yet"
[[ -f "$BRIDGE_DIR/guard.txt" ]] && ok "EA local guard present" || warn "guard.txt not rendered yet"

for svc in xauusd-xvfb xauusd-mt5 xauusd-poller; do
  if systemctl cat "$svc.service" >/dev/null 2>&1; then
    systemctl is-active --quiet "$svc.service" && ok "$svc active" || warn "$svc installed but inactive"
  else
    warn "$svc not installed"
  fi
done

if [[ -f "$BRIDGE_DIR/ack.txt" ]]; then
  ok "latest MT5 ack: $(tail -n 1 "$BRIDGE_DIR/ack.txt" 2>/dev/null)"
else
  warn "no MT5 ack yet"
fi

if [[ -f "$BRIDGE_DIR/state.txt" ]]; then
  ok "MT5 state export present"
  tail -n 1 "$BRIDGE_DIR/state.txt" 2>/dev/null | sed 's/^/     /'
else
  warn "no MT5 state export yet"
fi

if [[ -f "$ROOT/runtime/state.json" ]]; then
  ok "GitHub runtime state file present"
else
  warn "runtime/state.json missing"
fi

printf '\nMT5 runtime diagnostics:\n'
TERMINAL_LOG="$(find "$MT5_DIR/logs" -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"
MQL_LOG="$(find "$MT5_DIR/MQL5/Logs" "$DATA_DIR/MQL5/Logs" -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)"

if [[ -n "$TERMINAL_LOG" ]]; then
  ok "latest terminal log: $TERMINAL_LOG"
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-16LE -t UTF-8 "$TERMINAL_LOG" 2>/dev/null \
      | tr -d '\r' \
      | grep -Ei 'SignalBridge|expert|XAUUSD|login|authorization|server|error|failed|cannot|invalid' \
      | tail -n 80 \
      | sed 's/^/     /' || true
  fi
else
  warn "no terminal log found"
fi

if [[ -n "$MQL_LOG" ]]; then
  ok "latest MQL5 log: $MQL_LOG"
  if command -v iconv >/dev/null 2>&1; then
    iconv -f UTF-16LE -t UTF-8 "$MQL_LOG" 2>/dev/null \
      | tr -d '\r' \
      | grep -Ei 'SignalBridge|expert|XAUUSD|error|failed|cannot|invalid' \
      | tail -n 80 \
      | sed 's/^/     /' || true
  fi
else
  warn "no MQL5 expert log found"
fi

df -h / | tail -n 1
exit "$FAILED"
