# XAUUSD MT5 Demo Bridge V2

Demo-only autonomous experiment:

`ChatGPT Scheduler -> GitHub signal.json -> Linux poller -> MQL5 file sandbox -> MT5 Expert Advisor -> demo broker`

and back:

`MT5 state.txt -> Linux poller -> GitHub runtime/state.json -> ChatGPT Scheduler`

There is no Windows Python and no MetaTrader5 Python package. MT5 is the only Windows application under Wine. The Linux poller only moves validated commands and sanitized state.

## Safety invariants

The EA enforces these locally, independently of ChatGPT and GitHub:

- account must be DEMO;
- expected login and server must match the local guard;
- logical instrument is XAUUSD only;
- hard risk cap: 0.5% equity;
- hard automated volume cap: 0.01 lot;
- mandatory SL and TP for entries;
- minimum live reward/risk: 2.0;
- spread cap;
- only one XAUUSD exposure at a time, including pending orders;
- signal-id deduplication;
- expired signals are blocked;
- pending orders are cancelled at expiry when the broker cannot enforce the expiry server-side;
- OrderCheck() runs before OrderSend();
- CLOSE/MODIFY/CANCEL only act on the configured magic number;
- credentials, account login, server name and balance are never written to runtime/state.json.

## Supported actions

Schema V2 supports:

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

BUY/SELL are market orders. BUY_STOP/SELL_STOP require `entry`, `sl`, `tp`, positive `risk_pct`, timezone-aware `created_at`, and `valid_until`.

## VPS layout

- repository: `/opt/xauusd-mt5-demo`
- Wine prefix: `/home/perrucci/.mt5`
- MT5 portable data: `/home/perrucci/.mt5/drive_c/Program Files/MetaTrader 5`
- local secrets: `/etc/xauusd-mt5-demo/mt5.env`
- EA: `MQL5/Experts/XAUUSD/SignalBridge.ex5`
- file bridge: `MQL5/Files/xauusd/`
- sanitized remote state: `runtime/state.json`

## Deploy V2 on the existing VPS

The VPS already uses a dedicated deploy key. For bidirectional state sync, that key must be able to push to this repository. GitHub deploy keys support an **Allow write access** option. Do not put a PAT or MT5 password in the repository.

After the key has write access:

```bash
sudo -iu perrucci git -C /opt/xauusd-mt5-demo fetch origin
sudo -iu perrucci git -C /opt/xauusd-mt5-demo checkout codex/autonomous-bridge-v2
sudo -iu perrucci git -C /opt/xauusd-mt5-demo pull --ff-only
sudo bash /opt/xauusd-mt5-demo/scripts/vps/install-ea-and-services.sh
sudo bash /opt/xauusd-mt5-demo/scripts/vps/configure-demo.sh
sudo bash /opt/xauusd-mt5-demo/scripts/vps/doctor.sh
```

The install script preserves the existing local `config.json` values while adding new V2 defaults.

## State synchronization

The EA writes a local state snapshot every second. The poller pushes a sanitized state to `runtime/state.json`:

- immediately when position/pending/ack state changes;
- otherwise at most once per hour as a heartbeat.

Price changes alone do not cause continuous Git commits.

## Useful checks

```bash
sudo bash /opt/xauusd-mt5-demo/scripts/vps/doctor.sh
sudo journalctl -u xauusd-mt5 -u xauusd-poller -n 100 --no-pager
```

This repository is for a demo experiment only. It makes no profitability claim and is deliberately blocked from running on a live account.
