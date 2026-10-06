# XAUUSD MT5 Demo Bridge V3

Demo-only H1 systematic intraday experiment:

`ChatGPT hourly task -> GitHub signal.json -> Linux poller -> MT5 Expert Advisor -> demo broker`

and back:

`MT5 multi-position state -> Linux poller -> GitHub runtime/state.json -> ChatGPT hourly task`

The MT5 account is expected to use hedging mode. MT5 remains the only Windows application under Wine; the Linux poller validates and transports commands/state.

## V3 model

- decision cadence: once per hour;
- H1 is the operating timeframe, with H4/D1 context;
- up to **3 managed XAUUSD exposures** at once (positions + pending orders);
- each position/order is tracked by ticket;
- opposite BUY/SELL positions are technically supported because the account is hedging;
- the task may add at most one new setup per hourly cycle;
- management commands can target an individual ticket;
- `CLOSE_ALL` and `CANCEL_ALL` exist for explicit portfolio-wide exits.

## Hard safety invariants

The EA enforces these locally, independently of ChatGPT and GitHub:

- account must be DEMO;
- expected login and server must match the local guard;
- new entries require a hedging account;
- logical instrument is XAUUSD only;
- hard aggregate managed risk cap: **0.5% of current equity**;
- maximum managed exposures: **3**;
- hard automated volume cap: **0.01 lot per entry**;
- mandatory SL and TP for every new entry;
- minimum entry reward/risk: **2.0**;
- spread cap;
- unmanaged XAUUSD exposure blocks new automated entries;
- signal-id deduplication;
- expired/future-invalid signals are blocked;
- `OrderCheck()` runs before `OrderSend()`;
- ticketed `CLOSE`, `MODIFY`, and `CANCEL` only act on the configured magic number;
- widening SL on an existing managed exposure is rejected if it would violate per-trade or aggregate risk caps;
- credentials, account login, server name, balance and equity are never written to `runtime/state.json`.

## Signal schema V3

Supported actions:

- `NO_TRADE`
- `HOLD`
- `STATUS`
- `BUY`
- `SELL`
- `BUY_STOP`
- `SELL_STOP`
- `CLOSE`
- `CANCEL`
- `MODIFY`
- `CLOSE_ALL`
- `CANCEL_ALL`

`CLOSE`, `CANCEL`, and `MODIFY` require `target_ticket`.

Example:

```json
{
  "schema_version": 3,
  "id": "h1-20261006-1400-buy-stop",
  "symbol": "XAUUSD",
  "action": "BUY_STOP",
  "target_ticket": null,
  "entry": 4165.0,
  "sl": 4155.0,
  "tp": 4185.0,
  "risk_pct": 0.15,
  "created_at": "2026-10-06T12:00:00+00:00",
  "valid_until": "2026-10-06T13:00:00+00:00",
  "reason": "Example only"
}
```

The hourly task is intended to request about **0.15% risk per new trade**, leaving room for up to three independent trades while the EA independently enforces the 0.5% aggregate ceiling.

## State schema

The EA exports all managed positions and pending orders. The poller publishes a sanitized JSON snapshot containing:

- connectivity, demo/trading/hedging flags;
- XAUUSD bid/ask;
- managed position and pending-order counts;
- unmanaged XAUUSD exposure count;
- aggregate managed risk percentage;
- `managed_positions[]`, each with ticket/type/volume/open/SL/TP/profit/risk;
- `managed_pending_orders[]`, each with ticket/type/volume/entry/SL/TP/risk/expiration;
- latest managed closed deal;
- latest signal/ACK.

Structural changes are pushed immediately; otherwise a heartbeat is pushed periodically.

## VPS layout

- repository: `/opt/xauusd-mt5-demo`
- Wine prefix: `/home/perrucci/.mt5`
- MT5 portable data: `/home/perrucci/.mt5/drive_c/Program Files/MetaTrader 5`
- local secrets: `/etc/xauusd-mt5-demo/mt5.env`
- EA: `MQL5/Experts/XAUUSD/SignalBridge.ex5`
- bridge files: `MQL5/Files/xauusd/`
- sanitized remote state: `runtime/state.json`

## Deploy V3

```bash
sudo systemctl stop xauusd-poller.service xauusd-mt5.service || true

sudo -iu perrucci git -C /opt/xauusd-mt5-demo pull --ff-only

sudo bash /opt/xauusd-mt5-demo/scripts/vps/install-ea-and-services.sh
sudo bash /opt/xauusd-mt5-demo/scripts/vps/configure-demo.sh

sleep 20
sudo bash /opt/xauusd-mt5-demo/scripts/vps/doctor.sh
```

The repository contains a safe V3 `NO_TRADE` bootstrap signal, so deploying V3 must not create an order by itself.

## Useful checks

```bash
sudo bash /opt/xauusd-mt5-demo/scripts/vps/doctor.sh
sudo journalctl -u xauusd-mt5 -u xauusd-poller -n 120 --no-pager
```

This repository is for a demo experiment only. It makes no profitability claim and is deliberately blocked from running on a live account.
