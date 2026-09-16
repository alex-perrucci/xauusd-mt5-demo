#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/opt/xauusd-mt5-demo
ENV_FILE=/etc/xauusd-mt5-demo/mt5.env
PREFIX=/home/perrucci/.mt5
MT5_DIR="$PREFIX/drive_c/Program Files/MetaTrader 5"
TERMINAL_CFG="$PREFIX/drive_c/xauusd/terminal.ini"
BRIDGE_DIR="$MT5_DIR/MQL5/Files/xauusd"
GUARD_FILE="$BRIDGE_DIR/guard.txt"

[[ ${EUID} -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || {
  echo "missing $ENV_FILE" >&2
  echo "copy $ROOT/deploy/mt5.env.example there, edit it, then chmod 600" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${MT5_LOGIN:?MT5_LOGIN missing}"
: "${MT5_PASSWORD:?MT5_PASSWORD missing}"
: "${MT5_SERVER:?MT5_SERVER missing}"
: "${BROKER_SYMBOL:?BROKER_SYMBOL missing}"
STARTUP_SYMBOL=${STARTUP_SYMBOL:-$BROKER_SYMBOL}
MAX_SPREAD_POINTS=${MAX_SPREAD_POINTS:-100}
MAX_RISK_PCT=${MAX_RISK_PCT:-0.5}
MIN_RR=${MIN_RR:-2.0}
MAGIC=${MAGIC:-560017}
DEVIATION_POINTS=${DEVIATION_POINTS:-30}

python3 - "$MT5_LOGIN" "$MAX_SPREAD_POINTS" "$MAX_RISK_PCT" "$MIN_RR" "$MAGIC" "$DEVIATION_POINTS" <<'PY'
import sys
login, spread, risk, rr, magic, deviation = sys.argv[1:]
assert login.isdigit() and int(login) > 0, "MT5_LOGIN must be a positive integer"
assert float(spread) > 0, "MAX_SPREAD_POINTS must be > 0"
assert 0 < float(risk) <= 0.5, "MAX_RISK_PCT must be > 0 and <= 0.5"
assert float(rr) >= 2.0, "MIN_RR must be >= 2.0"
assert int(magic) > 0, "MAGIC must be > 0"
assert int(deviation) >= 0, "DEVIATION_POINTS must be >= 0"
PY

for value in "$MT5_SERVER" "$BROKER_SYMBOL" "$STARTUP_SYMBOL"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *'|'* ]] || {
    echo "server/symbol values cannot contain newline or |" >&2
    exit 1
  }
done

install -d -o perrucci -g perrucci -m 0700 "$(dirname "$TERMINAL_CFG")"
install -d -o perrucci -g perrucci -m 0700 "$BRIDGE_DIR"

umask 077
cat > "$TERMINAL_CFG" <<EOF
[Common]
Login=$MT5_LOGIN
Server=$MT5_SERVER
Password=$MT5_PASSWORD
KeepPrivate=0
NewsEnable=0

[Charts]
MaxBars=5000

[Experts]
AllowLiveTrading=1
AllowDllImport=0
Enabled=1
Account=0
Profile=0

[StartUp]
Expert=XAUUSD\\SignalBridge
Symbol=$STARTUP_SYMBOL
Period=M1
EOF

printf '1|%s|%s|%s|%s|%s|%s|%s|%s\n' \
  "$MT5_LOGIN" "$MT5_SERVER" "$BROKER_SYMBOL" "$MAX_SPREAD_POINTS" \
  "$MAX_RISK_PCT" "$MIN_RR" "$MAGIC" "$DEVIATION_POINTS" > "$GUARD_FILE"

chown perrucci:perrucci "$TERMINAL_CFG" "$GUARD_FILE"
chmod 0600 "$TERMINAL_CFG" "$GUARD_FILE" "$ENV_FILE"

systemctl restart xauusd-xvfb.service
systemctl restart xauusd-mt5.service
systemctl restart xauusd-poller.service
sleep 5

printf '\nServices:\n'
systemctl --no-pager --full status xauusd-xvfb.service xauusd-mt5.service xauusd-poller.service || true
printf '\nNo credentials were written to Git. MT5 config: %s\n' "$TERMINAL_CFG"
