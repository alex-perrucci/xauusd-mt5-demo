# XAUUSD MT5 Demo

Experimental demo-only automation for XAUUSD.

Flow:

1. ChatGPT Scheduler analyzes XAUUSD and updates `signal.json`.
2. The Linux VPS pulls the repository and validates the signal.
3. A Linux poller invokes a Windows Python process under Wine.
4. The Windows process talks to a running MetaTrader 5 terminal through the official `MetaTrader5` Python package.
5. Orders are accepted only when the connected MT5 account is a DEMO account.

## Safety defaults

- XAUUSD only.
- Demo accounts only.
- One managed position at a time.
- Stop-loss required for opening trades.
- Take-profit required for opening trades.
- Maximum configured risk per trade: 0.5% of account equity.
- Duplicate signal IDs are ignored.
- Expired signals are ignored.
- No credentials or broker passwords belong in this repository.

## Signal contract

`signal.json` is the interface between ChatGPT Scheduler and the VPS.

Supported actions:

- `NO_TRADE`
- `BUY`
- `SELL`
- `HOLD`
- `CLOSE`
- `MODIFY`

A BUY/SELL signal must include `sl`, `tp`, `risk_pct`, `created_at`, and `valid_until`.

Example:

```json
{
  "schema_version": 1,
  "id": "2026-09-17-morning",
  "symbol": "XAUUSD",
  "action": "BUY",
  "entry_type": "MARKET",
  "sl": 3651.4,
  "tp": 3698.2,
  "risk_pct": 0.5,
  "created_at": "2026-09-17T08:00:00+02:00",
  "valid_until": "2026-09-17T12:00:00+02:00",
  "reason": "Daily trend bullish; H4 pullback confirmed; macro context supportive."
}
```

## VPS overview

The Linux side runs `bridge/poller.py`. It performs a `git pull --ff-only`, validates the signal, checks that the signal has not already been processed, then invokes the configured Wine/Windows-Python command.

The Windows-side executor is `bridge/mt5_executor.py`. It connects to the already-running MT5 terminal and performs the requested demo action.

See `config.example.json` and `scripts/run.sh` for the expected configuration.

## Important

This project is deliberately limited to demo trading. It is an experiment for measuring whether the strategy has any edge; it is not a guarantee of profitability and should not be pointed at a live account without a separate review and explicit redesign of the safety model.
