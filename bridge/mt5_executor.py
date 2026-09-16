#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any

try:
    import MetaTrader5 as mt5
except ImportError as exc:
    print(f"MetaTrader5 package is not installed in this Windows Python environment: {exc}", file=sys.stderr)
    raise SystemExit(2)

SUCCESS_RETCODES = {
    getattr(mt5, "TRADE_RETCODE_DONE", 10009),
    getattr(mt5, "TRADE_RETCODE_PLACED", 10008),
    getattr(mt5, "TRADE_RETCODE_DONE_PARTIAL", 10010),
}


def load_signal(path: str) -> dict[str, Any]:
    with Path(path).open("r", encoding="utf-8") as fh:
        return json.load(fh)


def fail(message: str, code: int = 1) -> int:
    print(message, file=sys.stderr)
    return code


def block(message: str) -> int:
    # A safety/business-rule block is considered handled so the Linux poller
    # does not retry the same signal forever.
    print(f"BLOCKED: {message}")
    return 0


def ensure_demo_account() -> tuple[Any, int | None]:
    account = mt5.account_info()
    if account is None:
        return None, fail(f"account_info failed: {mt5.last_error()}")

    demo_mode = getattr(mt5, "ACCOUNT_TRADE_MODE_DEMO", 0)
    trade_mode = getattr(account, "trade_mode", None)
    if trade_mode != demo_mode:
        return None, block(f"connected account is not DEMO (trade_mode={trade_mode})")

    trade_allowed = getattr(account, "trade_allowed", True)
    if trade_allowed is False:
        return None, block("trading is not allowed on the connected account")

    return account, None


def ensure_symbol(symbol: str) -> tuple[Any, int | None]:
    info = mt5.symbol_info(symbol)
    if info is None:
        return None, block(f"broker symbol {symbol!r} does not exist")
    if not info.visible and not mt5.symbol_select(symbol, True):
        return None, fail(f"symbol_select({symbol}) failed: {mt5.last_error()}")
    info = mt5.symbol_info(symbol)
    if info is None:
        return None, fail(f"symbol_info({symbol}) unavailable after selection")
    return info, None


def managed_positions(symbol: str, magic: int) -> list[Any]:
    positions = mt5.positions_get(symbol=symbol)
    if positions is None:
        return []
    return [p for p in positions if int(getattr(p, "magic", -1)) == magic]


def all_symbol_positions(symbol: str) -> list[Any]:
    positions = mt5.positions_get(symbol=symbol)
    return list(positions or [])


def current_tick(symbol: str) -> Any | None:
    return mt5.symbol_info_tick(symbol)


def spread_points(info: Any, tick: Any) -> float:
    point = float(getattr(info, "point", 0.0) or 0.0)
    if point <= 0:
        return math.inf
    return (float(tick.ask) - float(tick.bid)) / point


def normalize_volume(raw_volume: float, info: Any) -> float:
    vmin = float(info.volume_min)
    vmax = float(info.volume_max)
    step = float(info.volume_step)
    if raw_volume < vmin:
        return 0.0
    capped = min(raw_volume, vmax)
    steps = math.floor((capped + 1e-12) / step)
    volume = steps * step
    digits = max(0, int(round(-math.log10(step)))) if step < 1 else 0
    return round(volume, digits + 1)


def calculate_volume(
    account: Any,
    info: Any,
    symbol: str,
    order_type: int,
    entry: float,
    sl: float,
    risk_pct: float,
) -> tuple[float, str | None]:
    equity = float(account.equity)
    risk_amount = equity * (risk_pct / 100.0)
    if risk_amount <= 0:
        return 0.0, "account equity/risk amount is not positive"

    one_lot_profit = mt5.order_calc_profit(order_type, symbol, 1.0, entry, sl)
    if one_lot_profit is None:
        return 0.0, f"order_calc_profit failed: {mt5.last_error()}"

    one_lot_loss = abs(float(one_lot_profit))
    if one_lot_loss <= 0:
        return 0.0, "calculated one-lot loss at SL is zero"

    raw_volume = risk_amount / one_lot_loss
    volume = normalize_volume(raw_volume, info)
    if volume <= 0:
        return 0.0, (
            f"required volume {raw_volume:.8f} is below broker minimum {info.volume_min}; "
            "trade skipped rather than exceeding the risk cap"
        )

    actual_loss = mt5.order_calc_profit(order_type, symbol, volume, entry, sl)
    if actual_loss is None:
        return 0.0, f"risk verification failed: {mt5.last_error()}"
    if abs(float(actual_loss)) > risk_amount * 1.01:
        return 0.0, "normalized volume would exceed configured risk cap"

    return volume, None


def filling_candidates(info: Any) -> list[int]:
    values: list[int] = []
    for value in (
        getattr(info, "filling_mode", None),
        getattr(mt5, "ORDER_FILLING_IOC", None),
        getattr(mt5, "ORDER_FILLING_FOK", None),
        getattr(mt5, "ORDER_FILLING_RETURN", None),
    ):
        if isinstance(value, int) and value not in values:
            values.append(value)
    return values


def send_with_fill_fallback(request: dict[str, Any], info: Any) -> Any | None:
    last_result = None
    for filling in filling_candidates(info):
        req = dict(request)
        req["type_filling"] = filling
        result = mt5.order_send(req)
        last_result = result
        if result is not None and int(result.retcode) in SUCCESS_RETCODES:
            return result
    return last_result


def open_trade(
    signal: dict[str, Any],
    account: Any,
    info: Any,
    broker_symbol: str,
    magic: int,
    max_risk_pct: float,
    max_spread_points: float,
    deviation_points: int,
) -> int:
    if all_symbol_positions(broker_symbol):
        return block(f"there is already an open {broker_symbol} position; refusing to stack another one")

    tick = current_tick(broker_symbol)
    if tick is None:
        return fail(f"symbol_info_tick failed: {mt5.last_error()}")

    spread = spread_points(info, tick)
    if spread > max_spread_points:
        return block(f"spread {spread:.1f} points exceeds limit {max_spread_points:.1f}")

    action = str(signal["action"])
    risk_pct = float(signal["risk_pct"])
    if risk_pct > max_risk_pct:
        return block(f"signal risk {risk_pct}% exceeds local limit {max_risk_pct}%")

    sl = float(signal["sl"])
    tp = float(signal["tp"])
    if action == "BUY":
        order_type = mt5.ORDER_TYPE_BUY
        entry = float(tick.ask)
        if not (sl < entry < tp):
            return block(f"invalid BUY geometry: expected SL < entry < TP, got {sl} < {entry} < {tp}")
    else:
        order_type = mt5.ORDER_TYPE_SELL
        entry = float(tick.bid)
        if not (tp < entry < sl):
            return block(f"invalid SELL geometry: expected TP < entry < SL, got {tp} < {entry} < {sl}")

    volume, error = calculate_volume(account, info, broker_symbol, order_type, entry, sl, risk_pct)
    if error:
        return block(error)

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": broker_symbol,
        "volume": volume,
        "type": order_type,
        "price": entry,
        "sl": sl,
        "tp": tp,
        "deviation": deviation_points,
        "magic": magic,
        "comment": f"chatgpt-demo:{str(signal['id'])[:18]}",
        "type_time": mt5.ORDER_TIME_GTC,
    }

    check = mt5.order_check(request)
    if check is None:
        return fail(f"order_check failed: {mt5.last_error()}")
    check_retcode = int(getattr(check, "retcode", -1))
    if check_retcode not in {0, getattr(mt5, "TRADE_RETCODE_DONE", 10009)}:
        return block(f"order_check rejected trade: retcode={check_retcode}, comment={getattr(check, 'comment', '')}")

    result = send_with_fill_fallback(request, info)
    if result is None:
        return fail(f"order_send failed: {mt5.last_error()}")
    if int(result.retcode) not in SUCCESS_RETCODES:
        return fail(f"order_send rejected: retcode={result.retcode}, comment={result.comment}")

    print(
        json.dumps(
            {
                "status": "OPENED",
                "signal_id": signal["id"],
                "symbol": broker_symbol,
                "side": action,
                "volume": volume,
                "entry": entry,
                "sl": sl,
                "tp": tp,
                "spread_points": spread,
                "order": getattr(result, "order", None),
                "deal": getattr(result, "deal", None),
            }
        )
    )
    return 0


def close_positions(
    signal: dict[str, Any],
    info: Any,
    broker_symbol: str,
    magic: int,
    deviation_points: int,
) -> int:
    positions = managed_positions(broker_symbol, magic)
    if not positions:
        print("CLOSE: no managed position is open")
        return 0

    for position in positions:
        tick = current_tick(broker_symbol)
        if tick is None:
            return fail(f"symbol_info_tick failed while closing: {mt5.last_error()}")

        is_buy = int(position.type) == int(mt5.POSITION_TYPE_BUY)
        order_type = mt5.ORDER_TYPE_SELL if is_buy else mt5.ORDER_TYPE_BUY
        price = float(tick.bid if is_buy else tick.ask)
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "position": int(position.ticket),
            "symbol": broker_symbol,
            "volume": float(position.volume),
            "type": order_type,
            "price": price,
            "deviation": deviation_points,
            "magic": magic,
            "comment": f"chatgpt-close:{str(signal['id'])[:17]}",
            "type_time": mt5.ORDER_TIME_GTC,
        }
        result = send_with_fill_fallback(request, info)
        if result is None or int(result.retcode) not in SUCCESS_RETCODES:
            if result is None:
                return fail(f"close order_send failed: {mt5.last_error()}")
            return fail(f"close rejected: retcode={result.retcode}, comment={result.comment}")
        print(f"CLOSED position={position.ticket} volume={position.volume}")
    return 0


def modify_positions(signal: dict[str, Any], broker_symbol: str, magic: int) -> int:
    positions = managed_positions(broker_symbol, magic)
    if not positions:
        return block("MODIFY requested but there is no managed position")

    new_sl = signal.get("sl")
    new_tp = signal.get("tp")

    for position in positions:
        tick = current_tick(broker_symbol)
        if tick is None:
            return fail(f"symbol_info_tick failed while modifying: {mt5.last_error()}")

        sl = float(new_sl) if new_sl is not None else float(position.sl)
        tp = float(new_tp) if new_tp is not None else float(position.tp)
        is_buy = int(position.type) == int(mt5.POSITION_TYPE_BUY)
        market = float(tick.bid if is_buy else tick.ask)

        if is_buy:
            if sl > 0 and sl >= market:
                return block(f"BUY SL {sl} must remain below current bid {market}")
            if tp > 0 and tp <= market:
                return block(f"BUY TP {tp} must remain above current bid {market}")
        else:
            if sl > 0 and sl <= market:
                return block(f"SELL SL {sl} must remain above current ask {market}")
            if tp > 0 and tp >= market:
                return block(f"SELL TP {tp} must remain below current ask {market}")

        result = mt5.order_send(
            {
                "action": mt5.TRADE_ACTION_SLTP,
                "position": int(position.ticket),
                "symbol": broker_symbol,
                "sl": sl,
                "tp": tp,
                "magic": magic,
                "comment": f"chatgpt-modify:{str(signal['id'])[:16]}",
            }
        )
        if result is None:
            return fail(f"SLTP modification failed: {mt5.last_error()}")
        if int(result.retcode) not in SUCCESS_RETCODES:
            return fail(f"SLTP modification rejected: retcode={result.retcode}, comment={result.comment}")
        print(f"MODIFIED position={position.ticket} sl={sl} tp={tp}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Execute a validated XAUUSD signal on a MetaTrader 5 DEMO account.")
    parser.add_argument("--signal", required=True)
    parser.add_argument("--broker-symbol", default="XAUUSD")
    parser.add_argument("--magic", type=int, default=560017)
    parser.add_argument("--max-risk-pct", type=float, default=0.5)
    parser.add_argument("--max-spread-points", type=float, default=100.0)
    parser.add_argument("--deviation-points", type=int, default=30)
    parser.add_argument("--terminal-path", default="")
    args = parser.parse_args()

    if args.max_risk_pct <= 0 or args.max_risk_pct > 0.5:
        return fail("local max-risk-pct must be > 0 and <= 0.5", 2)

    signal = load_signal(args.signal)
    if signal.get("symbol") != "XAUUSD":
        return block("executor accepts logical symbol XAUUSD only")

    init_ok = mt5.initialize(path=args.terminal_path) if args.terminal_path else mt5.initialize()
    if not init_ok:
        return fail(f"mt5.initialize failed: {mt5.last_error()}")

    try:
        account, rc = ensure_demo_account()
        if rc is not None:
            return rc

        info, rc = ensure_symbol(args.broker_symbol)
        if rc is not None:
            return rc

        action = str(signal.get("action", ""))
        if action in {"NO_TRADE", "HOLD"}:
            print(f"{action}: no MT5 action required")
            return 0
        if action in {"BUY", "SELL"}:
            return open_trade(
                signal,
                account,
                info,
                args.broker_symbol,
                args.magic,
                args.max_risk_pct,
                args.max_spread_points,
                args.deviation_points,
            )
        if action == "CLOSE":
            return close_positions(signal, info, args.broker_symbol, args.magic, args.deviation_points)
        if action == "MODIFY":
            return modify_positions(signal, args.broker_symbol, args.magic)
        return block(f"unsupported action {action!r}")
    finally:
        mt5.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
