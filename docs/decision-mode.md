# DEMO-only decision executor

Decision mode separates market analysis from MT5 execution.

Flow:

```
decision.json (non-executable)
  -> VPS poller validates against local MT5 state
  -> runtime/executable_signal.json (local audit artifact)
  -> MT5 bridge signal.txt
  -> MT5 DEMO
```

## Required config.json keys

```json
{
  "decision_mode": true,
  "decision_path": "decision.json",
  "executor_signal_path": "runtime/executable_signal.json",
  "state_freshness_seconds": 600,
  "max_managed_exposures": 3,
  "min_trade_risk_pct": 0.05,
  "state_push_seconds": 120
}
```

Existing bridge/ack/state paths remain unchanged.

## Hard gates

The executor refuses a decision unless the local MT5 state has:

- schema_version = 2
- connected = true
- demo = true
- trade_allowed = true
- hedging = true
- unmanaged_symbol_exposure_count = 0
- managed positions + managed pending orders <= 3
- state file freshness <= state_freshness_seconds

New entries additionally require:

- fewer than 3 managed exposures
- remaining aggregate risk capacity
- requested risk capped at min(requested, 0.15, configured max risk, remaining 0.50% capacity)
- SL and TP
- valid directional price geometry
- reward/risk >= 2.0
- no nearby same-side managed exposure within 0.25% of the proposed entry

The executor is intentionally DEMO-only. A state with demo != true is rejected with LIVE_ACCOUNT_BLOCKED.

## Decision intents

Non-executable intents accepted in decision.json:

- NO_TRADE
- HOLD
- STATUS
- PROPOSE_BUY
- PROPOSE_SELL
- PROPOSE_BUY_STOP
- PROPOSE_SELL_STOP
- PROPOSE_CLOSE
- PROPOSE_CANCEL
- PROPOSE_MODIFY
- PROPOSE_CLOSE_ALL
- PROPOSE_CANCEL_ALL

The executor deterministically prefixes executable signal IDs with `exec-`.

## Deployment check

After pulling the branch and updating config.json:

```bash
python3 -m py_compile bridge/poller.py
sudo systemctl restart xauusd-poller
sudo journalctl -u xauusd-poller --since "2 minutes ago" --no-pager -n 100
```

The expired bootstrap decision should be logged as rejected and must not reach MT5.
