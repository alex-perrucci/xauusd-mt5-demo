#!/usr/bin/env bash
set -u

REPO_ROOT="/opt/xauusd-mt5-demo"
MT5_EXE="/home/perrucci/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe"
PY_EXE="C:\\Python311\\python.exe"
FAILED=0

ok() { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; FAILED=1; }

for cmd in git python3 wine winepath Xvfb; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd found"; else fail "$cmd missing"; fi
done

if [[ -d "$REPO_ROOT/.git" ]]; then ok "repo present at $REPO_ROOT"; else fail "repo missing at $REPO_ROOT"; fi
if [[ -f "$REPO_ROOT/config.json" ]]; then ok "config.json present"; else warn "config.json not created yet"; fi
if [[ -f "$MT5_EXE" ]]; then ok "MT5 terminal found"; else fail "MT5 terminal not found at $MT5_EXE"; fi

if id perrucci >/dev/null 2>&1; then
  if sudo -u perrucci env HOME=/home/perrucci WINEPREFIX=/home/perrucci/.mt5 wine "$PY_EXE" --version >/tmp/xauusd-python-version.txt 2>&1; then
    ok "Windows Python: $(tail -n 1 /tmp/xauusd-python-version.txt)"
  else
    fail "Windows Python C:\\Python311\\python.exe not working under Wine"
  fi

  if sudo -u perrucci env HOME=/home/perrucci WINEPREFIX=/home/perrucci/.mt5 wine "$PY_EXE" -c "import MetaTrader5 as mt5; print(mt5.__version__)" >/tmp/xauusd-mt5py-version.txt 2>&1; then
    ok "MetaTrader5 Python package: $(tail -n 1 /tmp/xauusd-mt5py-version.txt)"
  else
    fail "MetaTrader5 Python package not importable"
  fi
else
  fail "user perrucci missing"
fi

for svc in xauusd-xvfb xauusd-mt5 xauusd-poller; do
  if systemctl cat "$svc.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "$svc.service"; then ok "$svc active"; else warn "$svc installed but not active"; fi
  else
    warn "$svc service not installed yet"
  fi
done

rm -f /tmp/xauusd-python-version.txt /tmp/xauusd-mt5py-version.txt
exit "$FAILED"
