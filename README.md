# XAUUSD MT5 Demo Bridge

Demo-only autonomous experiment:

`ChatGPT Scheduler -> GitHub signal.json -> Linux poller -> MQL5 file sandbox -> MT5 Expert Advisor -> demo broker`

There is **no Windows Python** and no `MetaTrader5` Python package. MT5 is the only Windows application running under Wine. Trade execution lives natively inside the MQL5 Expert Advisor.

## Safety invariants

The EA enforces these locally, independently of the model and GitHub:

- account must be `DEMO`;
- expected login and server must match the local guard;
- logical instrument is XAUUSD only;
- hard absolute risk cap: 0.5% equity per new trade;
- mandatory SL and TP for BUY/SELL;
- live reward/risk must be at least 2.0;
- spread cap;
- no position stacking on the broker symbol;
- persistent signal-id deduplication;
- expired signals are blocked;
- `OrderCheck()` before `OrderSend()`;
- CLOSE/MODIFY affect only positions created with the configured magic number;
- no credentials are stored in Git.

## VPS layout

- repository: `/opt/xauusd-mt5-demo`
- Wine prefix: `/home/perrucci/.mt5`
- MT5 portable data: `/home/perrucci/.mt5/drive_c/Program Files/MetaTrader 5`
- local secrets: `/etc/xauusd-mt5-demo/mt5.env`
- EA: `MQL5/Experts/XAUUSD/SignalBridge.ex5`
- file bridge: `MQL5/Files/xauusd/`

## Clean installation

From the VPS:

```bash
sudo -iu perrucci git -C /opt/xauusd-mt5-demo pull --ff-only
sudo bash /opt/xauusd-mt5-demo/scripts/vps/reset-setup.sh
```

`reset-setup.sh` intentionally removes only the previous `/home/perrucci/.mt5` runtime and `/etc/xauusd-mt5-demo`, pins the supported Wine build, installs MT5, compiles the MQL5 EA, and installs systemd units. It does **not** start trading.

Then configure the demo account locally:

```bash
sudo cp /etc/xauusd-mt5-demo/mt5.env.example /etc/xauusd-mt5-demo/mt5.env
sudo chmod 600 /etc/xauusd-mt5-demo/mt5.env
sudoedit /etc/xauusd-mt5-demo/mt5.env
sudo bash /opt/xauusd-mt5-demo/scripts/vps/configure-demo.sh
```

Use the exact demo login, demo server and broker symbol shown by the broker. Never put the password in GitHub.

## Runtime services

- `xauusd-xvfb.service` — private virtual X display;
- `xauusd-mt5.service` — MT5 in `/portable` mode, with the EA loaded via startup config;
- `xauusd-poller.service` — Linux-only Git poller that converts `signal.json` into the EA bridge file.

Useful checks:

```bash
sudo bash /opt/xauusd-mt5-demo/scripts/vps/doctor.sh
sudo journalctl -u xauusd-mt5 -u xauusd-poller -n 100 --no-pager
```

## Signal contract

GitHub `signal.json` supports:

- `NO_TRADE`
- `BUY`
- `SELL`
- `HOLD`
- `CLOSE`
- `MODIFY`

BUY/SELL are market-only and require positive `risk_pct`, `sl`, `tp`, timezone-aware `created_at`, and `valid_until`.

This repository is for a demo experiment. It makes no profitability claim and should not be pointed at a live account without a separate design and review.
