#!/usr/bin/env bash
set -u

ROOT=/opt/xauusd-mt5-demo
PREFIX=/home/perrucci/.mt5
MT5_DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"
EA_EX5="$MT5_DIR/MQL5/Experts/XAUUSD/SignalBridge.ex5"
BRIDGE_DIR="$MT5_DIR/MQL5/Files/xauusd"
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
[[ -f "$MT5_DIR/metaeditor64.exe" ]] && ok "MetaEditor present" || fail "MetaEditor missing"
[[ -f "$EA_EX5" ]] && ok "SignalBridge.ex5 compiled" || fail "SignalBridge.ex5 missing"
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

df -h / | tail -n 1
exit "$FAILED"
