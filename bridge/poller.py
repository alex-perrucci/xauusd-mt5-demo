#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_ACTIONS = {
    "NO_TRADE", "HOLD", "STATUS",
    "BUY", "SELL", "BUY_STOP", "SELL_STOP",
    "CLOSE", "CANCEL", "MODIFY", "CLOSE_ALL", "CANCEL_ALL",
}
DECISION_TO_ACTION = {
    "NO_TRADE": "NO_TRADE",
    "HOLD": "HOLD",
    "STATUS": "STATUS",
    "PROPOSE_BUY": "BUY",
    "PROPOSE_SELL": "SELL",
    "PROPOSE_BUY_STOP": "BUY_STOP",
    "PROPOSE_SELL_STOP": "SELL_STOP",
    "PROPOSE_CLOSE": "CLOSE",
    "PROPOSE_CANCEL": "CANCEL",
    "PROPOSE_MODIFY": "MODIFY",
    "PROPOSE_CLOSE_ALL": "CLOSE_ALL",
    "PROPOSE_CANCEL_ALL": "CANCEL_ALL",
}
NEW_ENTRY_ACTIONS = {"BUY", "SELL", "BUY_STOP", "SELL_STOP"}


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def parse_dt(value: str, field: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError(f"{field} must be timezone-aware")
    return dt.astimezone(timezone.utc)


def validate_signal(signal: dict[str, Any], max_risk_pct: float) -> tuple[str, int, int]:
    if signal.get("schema_version") != 3:
        raise ValueError("schema_version must be 3")

    signal_id = str(signal.get("id", "")).strip()
    if not signal_id or any(ch in signal_id for ch in ("|", "\n", "\r")):
        raise ValueError("invalid signal id")

    if signal.get("symbol") != "XAUUSD":
        raise ValueError("logical symbol must be XAUUSD")

    action = str(signal.get("action", ""))
    if action not in ALLOWED_ACTIONS:
        raise ValueError(f"unsupported action {action!r}")

    created = parse_dt(str(signal.get("created_at", "")), "created_at")
    valid_until = parse_dt(str(signal.get("valid_until", "")), "valid_until")
    if valid_until <= created:
        raise ValueError("valid_until must be after created_at")
    if datetime.now(timezone.utc) > valid_until:
        raise ValueError("signal is expired")

    try:
        risk_pct = float(signal.get("risk_pct", 0.0))
    except (TypeError, ValueError) as exc:
        raise ValueError("risk_pct must be numeric") from exc
    if risk_pct < 0 or risk_pct > max_risk_pct or risk_pct > 0.5:
        raise ValueError(f"risk_pct must be between 0 and {min(max_risk_pct, 0.5)}")

    target_raw = signal.get("target_ticket")
    target_ticket: int | None
    if target_raw in (None, ""):
        target_ticket = None
    else:
        try:
            target_ticket = int(target_raw)
        except (TypeError, ValueError) as exc:
            raise ValueError("target_ticket must be an integer") from exc
        if target_ticket <= 0:
            raise ValueError("target_ticket must be > 0")

    if action in {"CLOSE", "CANCEL", "MODIFY"} and target_ticket is None:
        raise ValueError(f"{action} requires target_ticket")

    if action in {"BUY", "SELL", "BUY_STOP", "SELL_STOP"}:
        for field in ("sl", "tp"):
            try:
                value = float(signal[field])
            except (KeyError, TypeError, ValueError) as exc:
                raise ValueError(f"{field} must be numeric for {action}") from exc
            if value <= 0:
                raise ValueError(f"{field} must be > 0 for {action}")
        if risk_pct <= 0:
            raise ValueError(f"{action} requires positive risk_pct")

    if action in {"BUY_STOP", "SELL_STOP"}:
        try:
            entry = float(signal["entry"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"entry must be numeric for {action}") from exc
        if entry <= 0:
            raise ValueError("entry must be > 0 for pending orders")

    if action == "MODIFY":
        if signal.get("entry") is None and signal.get("sl") is None and signal.get("tp") is None:
            raise ValueError("MODIFY requires entry and/or sl and/or tp")
        for field in ("entry", "sl", "tp"):
            if signal.get(field) is not None and float(signal[field]) <= 0:
                raise ValueError(f"{field} must be > 0 when supplied")

    return action, int(created.timestamp()), int(valid_until.timestamp())



def _num(value: Any, field: str) -> float:
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be numeric") from exc


def _same_side(kind: str | None, side: str) -> bool:
    if not kind:
        return False
    return str(kind).upper().startswith(side)


def validate_decision(
    decision: dict[str, Any],
    state: dict[str, Any],
    max_risk_pct: float,
    freshness_seconds: int,
    max_exposures: int,
    min_trade_risk_pct: float,
) -> dict[str, Any]:
    """Validate a non-executable decision against authoritative local MT5 state.

    This path is intentionally DEMO-only. It converts PROPOSE_* intents into
    executable schema-v3 signals only after all runtime gates pass.
    """
    if decision.get("schema_version") != 1:
        raise ValueError("decision schema_version must be 1")

    decision_id = str(decision.get("id", "")).strip()
    if not decision_id or any(ch in decision_id for ch in ("|", "\n", "\r")):
        raise ValueError("invalid decision id")
    if decision.get("symbol") != "XAUUSD":
        raise ValueError("decision symbol must be XAUUSD")

    intent = str(decision.get("intent", "")).strip().upper()
    if intent not in DECISION_TO_ACTION:
        raise ValueError(f"unsupported decision intent {intent!r}")
    action = DECISION_TO_ACTION[intent]

    created = parse_dt(str(decision.get("created_at", "")), "created_at")
    valid_until = parse_dt(str(decision.get("valid_until", "")), "valid_until")
    now = datetime.now(timezone.utc)
    if valid_until <= created:
        raise ValueError("decision valid_until must be after created_at")
    if now > valid_until:
        raise ValueError("decision is expired")

    # Hard readiness gate. This executor is deliberately DEMO-only.
    if state.get("schema_version") != 2:
        raise ValueError("V3_NOT_READY: schema_version != 2")
    if state.get("connected") is not True:
        raise ValueError("V3_NOT_READY: connected != true")
    if state.get("demo") is not True:
        raise ValueError("LIVE_ACCOUNT_BLOCKED: demo != true")
    if state.get("trade_allowed") is not True:
        raise ValueError("V3_NOT_READY: trade_allowed != true")
    if state.get("hedging") is not True:
        raise ValueError("V3_NOT_READY: hedging != true")
    if int(state.get("unmanaged_symbol_exposure_count") or 0) != 0:
        raise ValueError("V3_NOT_READY: unmanaged XAUUSD exposure exists")

    captured = parse_dt(str(state.get("captured_at", "")), "state.captured_at")
    age = (now - captured).total_seconds()
    if age < -30:
        raise ValueError("STATE_CLOCK_INVALID: captured_at is in the future")
    if age > freshness_seconds:
        raise ValueError(f"STATE_STALE: age={age:.0f}s")

    positions = list(state.get("managed_positions") or [])
    orders = list(state.get("managed_pending_orders") or [])
    position_count = int(state.get("managed_position_count") or 0)
    order_count = int(state.get("managed_pending_order_count") or 0)
    total_exposures = position_count + order_count
    if total_exposures > max_exposures:
        raise ValueError("V3_NOT_READY: managed exposure count exceeds maximum")

    agg_risk = _num(state.get("aggregate_managed_risk_pct", 0.0), "aggregate_managed_risk_pct")
    if agg_risk < 0 or agg_risk > 0.5 + 1e-9:
        raise ValueError("invalid aggregate managed risk")

    signal: dict[str, Any] = {
        "schema_version": 3,
        "id": f"exec-{decision_id}",
        "symbol": "XAUUSD",
        "action": action,
        "target_ticket": None,
        "entry": None,
        "sl": None,
        "tp": None,
        "risk_pct": 0.0,
        "created_at": now.isoformat(),
        "valid_until": valid_until.isoformat(),
        "reason": f"Validated VPS decision {decision_id}: {str(decision.get('reason', '')).strip()}",
    }

    target_raw = decision.get("target_ticket")
    target_ticket = None if target_raw in (None, "") else int(target_raw)
    if target_ticket is not None and target_ticket <= 0:
        raise ValueError("target_ticket must be > 0")

    if action in NEW_ENTRY_ACTIONS:
        if total_exposures >= max_exposures:
            raise ValueError("MAX_EXPOSURES_REACHED")

        remaining = 0.50 - agg_risk
        requested = _num(decision.get("risk_pct", 0.15), "risk_pct")
        requested = min(requested, 0.15, max_risk_pct, remaining)
        if requested < min_trade_risk_pct:
            raise ValueError(
                f"INSUFFICIENT_RISK_CAPACITY: remaining={remaining:.4f}, usable={requested:.4f}"
            )

        sl = _num(decision.get("sl"), "sl")
        tp = _num(decision.get("tp"), "tp")
        if sl <= 0 or tp <= 0:
            raise ValueError("SL and TP must be > 0")

        if action in {"BUY_STOP", "SELL_STOP"}:
            entry = _num(decision.get("entry"), "entry")
            if entry <= 0:
                raise ValueError("pending entry must be > 0")
            signal["entry"] = entry
        else:
            market_field = "ask" if action == "BUY" else "bid"
            entry = _num(state.get(market_field), f"state.{market_field}")
            if entry <= 0:
                raise ValueError("invalid current market price")

        if action in {"BUY", "BUY_STOP"}:
            if not (sl < entry < tp):
                raise ValueError("BUY geometry requires SL < entry < TP")
            risk_distance = entry - sl
            reward_distance = tp - entry
            side = "BUY"
        else:
            if not (tp < entry < sl):
                raise ValueError("SELL geometry requires TP < entry < SL")
            risk_distance = sl - entry
            reward_distance = entry - tp
            side = "SELL"

        rr = reward_distance / risk_distance
        if rr < 2.0 - 1e-9:
            raise ValueError(f"RR_TOO_LOW: {rr:.3f}")

        # Conservative duplicate-thesis guard: same-side managed exposure with
        # an entry/open price within 0.25% of the proposed entry.
        for item in positions:
            existing = item.get("open_price")
            if _same_side(item.get("type"), side) and existing not in (None, ""):
                existing_f = float(existing)
                if existing_f > 0 and abs(entry - existing_f) / entry <= 0.0025:
                    raise ValueError("DUPLICATE_THESIS: nearby same-side managed position")
        for item in orders:
            existing = item.get("price")
            if _same_side(item.get("type"), side) and existing not in (None, ""):
                existing_f = float(existing)
                if existing_f > 0 and abs(entry - existing_f) / entry <= 0.0025:
                    raise ValueError("DUPLICATE_THESIS: nearby same-side pending order")

        signal["sl"] = sl
        signal["tp"] = tp
        signal["risk_pct"] = requested

    elif action == "CLOSE":
        if target_ticket is None:
            raise ValueError("CLOSE requires target_ticket")
        if not any(int(p.get("ticket") or 0) == target_ticket for p in positions):
            raise ValueError("TARGET_NOT_MANAGED_POSITION")
        signal["target_ticket"] = target_ticket

    elif action == "CANCEL":
        if target_ticket is None:
            raise ValueError("CANCEL requires target_ticket")
        if not any(int(o.get("ticket") or 0) == target_ticket for o in orders):
            raise ValueError("TARGET_NOT_MANAGED_PENDING_ORDER")
        signal["target_ticket"] = target_ticket

    elif action == "MODIFY":
        if target_ticket is None:
            raise ValueError("MODIFY requires target_ticket")
        pos = next((p for p in positions if int(p.get("ticket") or 0) == target_ticket), None)
        order = next((o for o in orders if int(o.get("ticket") or 0) == target_ticket), None)
        if pos is None and order is None:
            raise ValueError("TARGET_NOT_MANAGED")

        supplied = False
        for field in ("entry", "sl", "tp"):
            if decision.get(field) is not None:
                value = _num(decision.get(field), field)
                if value <= 0:
                    raise ValueError(f"{field} must be > 0")
                signal[field] = value
                supplied = True
        if not supplied:
            raise ValueError("MODIFY requires entry and/or sl and/or tp")

        # Never allow the automated validator to widen an existing stop.
        item = pos if pos is not None else order
        current_sl = item.get("sl") if item else None
        new_sl = signal.get("sl")
        kind = str(item.get("type") or "").upper() if item else ""
        if new_sl is not None and current_sl not in (None, ""):
            current_sl_f = float(current_sl)
            if kind.startswith("BUY") and new_sl < current_sl_f - 1e-9:
                raise ValueError("RISK_WIDENING_BLOCKED")
            if kind.startswith("SELL") and new_sl > current_sl_f + 1e-9:
                raise ValueError("RISK_WIDENING_BLOCKED")

        signal["target_ticket"] = target_ticket

    elif action == "CLOSE_ALL":
        if not positions:
            raise ValueError("NO_MANAGED_POSITIONS_TO_CLOSE")

    elif action == "CANCEL_ALL":
        if not orders:
            raise ValueError("NO_MANAGED_ORDERS_TO_CANCEL")

    return signal


def to_bridge_line(signal: dict[str, Any], created_epoch: int, valid_epoch: int) -> str:
    def optional_number(name: str) -> str:
        value = signal.get(name)
        return "" if value is None else format(float(value), ".10g")

    target = signal.get("target_ticket")
    fields = [
        "3", str(signal["id"]), str(signal["action"]), "XAUUSD",
        optional_number("entry"), optional_number("sl"), optional_number("tp"),
        format(float(signal.get("risk_pct", 0.0)), ".10g"),
        "" if target in (None, "") else str(int(target)),
        str(created_epoch), str(valid_epoch),
    ]
    return "|".join(fields) + "\n"


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent), text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def run_git(
    *args: str,
    timeout: int = 45,
    check: bool = True,
    input_text: str | None = None,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["git", "-C", str(ROOT), *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        input=input_text,
        env=env,
        timeout=timeout,
    )


def current_branch() -> str:
    branch = run_git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if not branch or branch == "HEAD":
        raise RuntimeError("bridge requires a named Git branch")
    return branch


def fetch_branch(branch: str) -> None:
    run_git("fetch", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}", timeout=60)


def load_remote_json(path: Path, branch: str) -> dict[str, Any]:
    fetch_branch(branch)
    rel = path.relative_to(ROOT).as_posix()
    result = run_git("show", f"origin/{branch}:{rel}")
    return json.loads(result.stdout)


def load_remote_signal(signal_path: Path, branch: str) -> dict[str, Any]:
    return load_remote_json(signal_path, branch)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        return ""


def newest_text(paths: list[Path]) -> str:
    existing: list[tuple[int, Path]] = []
    for path in paths:
        try:
            existing.append((path.stat().st_mtime_ns, path))
        except FileNotFoundError:
            continue
    if not existing:
        return ""
    existing.sort(reverse=True)
    return read_text(existing[0][1])


def nullable_number(value: str) -> float | None:
    return None if value == "" else float(value)


def nullable_int(value: str) -> int | None:
    return None if value == "" else int(value)


def iso_epoch(value: str) -> str | None:
    if not value:
        return None
    epoch = int(value)
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat() if epoch > 0 else None


def parse_state_v1(raw: str) -> dict[str, Any]:
    fields = raw.strip().split("|")
    if len(fields) != 30 or fields[0] != "1":
        raise ValueError(f"invalid legacy MT5 state format: expected 30 fields, got {len(fields)}")
    pos = []
    if int(fields[8] or 0) > 0 and fields[10]:
        pos.append({
            "ticket": nullable_int(fields[10]), "type": fields[9] or None,
            "volume": nullable_number(fields[11]), "open_price": nullable_number(fields[12]),
            "sl": nullable_number(fields[13]), "tp": nullable_number(fields[14]),
            "profit": nullable_number(fields[15]), "risk_pct": None, "comment": None,
        })
    orders = []
    if int(fields[16] or 0) > 0 and fields[18]:
        orders.append({
            "ticket": nullable_int(fields[18]), "type": fields[17] or None,
            "volume": None, "price": nullable_number(fields[19]),
            "sl": nullable_number(fields[20]), "tp": nullable_number(fields[21]),
            "risk_pct": None, "expiration": None, "comment": None,
        })
    return {
        "schema_version": 1,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "server_time": iso_epoch(fields[1]),
        "connected": fields[2] == "1",
        "demo": fields[3] == "1",
        "trade_allowed": fields[4] == "1",
        "hedging": None,
        "symbol": fields[5],
        "bid": nullable_number(fields[6]),
        "ask": nullable_number(fields[7]),
        "managed_position_count": int(fields[8] or 0),
        "managed_pending_order_count": int(fields[16] or 0),
        "unmanaged_symbol_exposure_count": None,
        "aggregate_managed_risk_pct": None,
        "managed_positions": pos,
        "managed_pending_orders": orders,
        "last_closed_deal": {
            "ticket": nullable_int(fields[22]), "position_id": nullable_int(fields[23]),
            "type": fields[24] or None, "reason": fields[25] or None,
            "price": nullable_number(fields[26]), "profit": nullable_number(fields[27]),
            "server_time": iso_epoch(fields[28]),
        },
        "last_signal_id": fields[29] or None,
    }


def parse_state(raw: str) -> dict[str, Any]:
    lines = [line.strip() for line in raw.splitlines() if line.strip()]
    if not lines:
        raise ValueError("empty MT5 state")
    if lines[0].startswith("1|"):
        return parse_state_v1(lines[0])

    h = lines[0].split("|")
    if len(h) != 14 or h[0] != "2":
        raise ValueError(f"invalid MT5 V3 state header: expected 14 fields, got {len(h)}")

    positions: list[dict[str, Any]] = []
    orders: list[dict[str, Any]] = []
    last_deal: dict[str, Any] | None = None

    for line in lines[1:]:
        f = line.split("|")
        if f[0] == "P":
            if len(f) != 10:
                raise ValueError(f"invalid position state record: {line!r}")
            positions.append({
                "ticket": int(f[1]), "type": f[2], "volume": nullable_number(f[3]),
                "open_price": nullable_number(f[4]), "sl": nullable_number(f[5]),
                "tp": nullable_number(f[6]), "profit": nullable_number(f[7]),
                "risk_pct": nullable_number(f[8]), "comment": f[9] or None,
            })
        elif f[0] == "O":
            if len(f) != 10:
                raise ValueError(f"invalid pending state record: {line!r}")
            orders.append({
                "ticket": int(f[1]), "type": f[2], "volume": nullable_number(f[3]),
                "price": nullable_number(f[4]), "sl": nullable_number(f[5]),
                "tp": nullable_number(f[6]), "risk_pct": nullable_number(f[7]),
                "expiration": iso_epoch(f[8]), "comment": f[9] or None,
            })
        elif f[0] == "D":
            if len(f) != 8:
                raise ValueError(f"invalid deal state record: {line!r}")
            last_deal = {
                "ticket": nullable_int(f[1]), "position_id": nullable_int(f[2]),
                "type": f[3] or None, "reason": f[4] or None,
                "price": nullable_number(f[5]), "profit": nullable_number(f[6]),
                "server_time": iso_epoch(f[7]),
            }

    return {
        "schema_version": 2,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "server_time": iso_epoch(h[1]),
        "connected": h[2] == "1",
        "demo": h[3] == "1",
        "trade_allowed": h[4] == "1",
        "hedging": h[5] == "1",
        "symbol": h[6],
        "bid": nullable_number(h[7]),
        "ask": nullable_number(h[8]),
        "managed_position_count": int(h[9] or 0),
        "managed_pending_order_count": int(h[10] or 0),
        "unmanaged_symbol_exposure_count": int(h[11] or 0),
        "aggregate_managed_risk_pct": nullable_number(h[12]),
        "managed_positions": positions,
        "managed_pending_orders": orders,
        "last_closed_deal": last_deal,
        "last_signal_id": h[13] or None,
    }


def parse_ack(raw: str) -> dict[str, Any] | None:
    if not raw:
        return None
    fields = raw.split("|", 3)
    if len(fields) != 4:
        return {"raw": raw}
    epoch = int(fields[2]) if fields[2].isdigit() else 0
    return {
        "signal_id": fields[0],
        "status": fields[1],
        "server_time": datetime.fromtimestamp(epoch, timezone.utc).isoformat() if epoch > 0 else None,
        "message": fields[3],
    }


def structural_fingerprint(state: dict[str, Any]) -> str:
    def compact_position(p: dict[str, Any]) -> dict[str, Any]:
        return {k: p.get(k) for k in ("ticket", "type", "volume", "open_price", "sl", "tp", "risk_pct", "comment")}

    def compact_order(o: dict[str, Any]) -> dict[str, Any]:
        return {k: o.get(k) for k in ("ticket", "type", "volume", "price", "sl", "tp", "risk_pct", "expiration", "comment")}

    compact = {
        "connected": state.get("connected"),
        "demo": state.get("demo"),
        "trade_allowed": state.get("trade_allowed"),
        "hedging": state.get("hedging"),
        "symbol": state.get("symbol"),
        "managed_position_count": state.get("managed_position_count"),
        "managed_pending_order_count": state.get("managed_pending_order_count"),
        "unmanaged_symbol_exposure_count": state.get("unmanaged_symbol_exposure_count"),
        "managed_positions": [compact_position(p) for p in state.get("managed_positions", [])],
        "managed_pending_orders": [compact_order(o) for o in state.get("managed_pending_orders", [])],
        "last_closed_deal": state.get("last_closed_deal"),
        "last_signal_id": state.get("last_signal_id"),
        "last_ack": state.get("last_ack"),
    }
    return hashlib.sha256(
        json.dumps(compact, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def publish_repo_state(repo_path: Path, payload: dict[str, Any], branch: str) -> None:
    rel = repo_path.relative_to(ROOT).as_posix()
    content = json.dumps(payload, indent=2, sort_keys=True) + "\n"

    for attempt in range(2):
        fetch_branch(branch)
        remote_ref = f"origin/{branch}"
        parent = run_git("rev-parse", remote_ref).stdout.strip()
        blob = run_git("hash-object", "-w", "--stdin", input_text=content).stdout.strip()

        fd, index_path = tempfile.mkstemp(prefix="xauusd-git-index.")
        os.close(fd)
        try:
            os.unlink(index_path)
            env = {"GIT_INDEX_FILE": index_path}
            run_git("read-tree", remote_ref, extra_env=env)
            run_git("update-index", "--add", "--cacheinfo", "100644", blob, rel, extra_env=env)
            tree = run_git("write-tree", extra_env=env).stdout.strip()
        finally:
            try:
                os.unlink(index_path)
            except FileNotFoundError:
                pass

        commit_env = {
            "GIT_AUTHOR_NAME": "xauusd-vps",
            "GIT_AUTHOR_EMAIL": "xauusd-vps@users.noreply.github.com",
            "GIT_COMMITTER_NAME": "xauusd-vps",
            "GIT_COMMITTER_EMAIL": "xauusd-vps@users.noreply.github.com",
        }
        commit = run_git(
            "commit-tree", tree, "-p", parent, "-m", "runtime: update MT5 demo state",
            extra_env=commit_env,
        ).stdout.strip()

        pushed = run_git("push", "origin", f"{commit}:refs/heads/{branch}", timeout=60, check=False)
        if pushed.returncode == 0:
            return
        if attempt == 1:
            raise RuntimeError(pushed.stdout.strip() or "git push failed")


def main() -> int:
    parser = argparse.ArgumentParser(description="Bidirectional GitHub <-> MT5 bridge for XAUUSD demo.")
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    config = load_json(Path(args.config))
    signal_path = ROOT / str(config.get("signal_path", "signal.json"))
    decision_path = ROOT / str(config.get("decision_path", "decision.json"))
    executor_signal_path = ROOT / str(
        config.get("executor_signal_path", "runtime/executable_signal.json")
    )
    bridge_path = Path(os.path.expanduser(str(config["bridge_file"])))
    ack_path = Path(os.path.expanduser(str(config["ack_file"])))
    state_file = Path(os.path.expanduser(str(config.get("state_file", bridge_path.with_name("state.txt")))))
    alternate_bridge_path = Path(os.path.expanduser(str(config["alternate_bridge_file"]))) if config.get("alternate_bridge_file") else None
    alternate_ack_path = Path(os.path.expanduser(str(config["alternate_ack_file"]))) if config.get("alternate_ack_file") else None
    alternate_state_file = Path(os.path.expanduser(str(config["alternate_state_file"]))) if config.get("alternate_state_file") else None

    bridge_paths = [bridge_path] + ([alternate_bridge_path] if alternate_bridge_path else [])
    ack_paths = [ack_path] + ([alternate_ack_path] if alternate_ack_path else [])
    state_paths = [state_file] + ([alternate_state_file] if alternate_state_file else [])
    state_repo_path = ROOT / str(config.get("state_repo_path", "runtime/state.json"))
    poll_seconds = max(5, int(config.get("poll_seconds", 30)))
    state_push_seconds = max(60, int(config.get("state_push_seconds", 3600)))
    max_risk_pct = min(0.5, float(config.get("max_risk_pct", 0.5)))
    auto_git_pull = bool(config.get("auto_git_pull", True))
    auto_state_push = bool(config.get("auto_state_push", False))
    decision_mode = bool(config.get("decision_mode", False))
    state_freshness_seconds = max(60, int(config.get("state_freshness_seconds", 600)))
    max_managed_exposures = min(3, max(1, int(config.get("max_managed_exposures", 3))))
    min_trade_risk_pct = max(0.0, float(config.get("min_trade_risk_pct", 0.05)))
    branch = current_branch()

    last_published = ""
    last_rejected_signal = ""
    last_ack = ""
    last_state_fingerprint = ""
    last_state_push = 0.0
    print(
        f"bridge ready: mode={'decision' if decision_mode else 'signal'}; "
        f"source={decision_path if decision_mode else signal_path} -> {', '.join(str(x) for x in bridge_paths)}; "
        f"state={', '.join(str(x) for x in state_paths)} -> {state_repo_path}",
        flush=True,
    )

    while True:
        try:
            ack_raw = newest_text(ack_paths)
            if ack_raw and ack_raw != last_ack:
                last_ack = ack_raw
                print(f"mt5 ack: {ack_raw}", flush=True)

            state: dict[str, Any] | None = None
            state_raw = newest_text(state_paths)
            if state_raw:
                state = parse_state(state_raw)
                state_mtimes = []
                for state_path in state_paths:
                    try:
                        state_mtimes.append(state_path.stat().st_mtime)
                    except FileNotFoundError:
                        pass
                if state_mtimes:
                    state["captured_at"] = datetime.fromtimestamp(
                        max(state_mtimes), timezone.utc
                    ).isoformat()
                state["last_ack"] = parse_ack(ack_raw)

                if auto_state_push:
                    fp = structural_fingerprint(state)
                    now_monotonic = time.monotonic()
                    changed = fp != last_state_fingerprint
                    heartbeat_due = now_monotonic - last_state_push >= state_push_seconds
                    if changed or heartbeat_due:
                        publish_repo_state(state_repo_path, state, branch)
                        last_state_fingerprint = fp
                        last_state_push = now_monotonic
                        print("published MT5 state " + ("(change)" if changed else "(heartbeat)"), flush=True)

            signal: dict[str, Any] | None = None
            source_id = ""

            if decision_mode:
                try:
                    if auto_git_pull:
                        decision = load_remote_json(decision_path, branch)
                    else:
                        decision = load_json(decision_path)
                    source_id = str(decision.get("id", "")).strip()
                    if state is None:
                        raise ValueError("STATE_UNAVAILABLE")
                    signal = validate_decision(
                        decision,
                        state,
                        max_risk_pct=max_risk_pct,
                        freshness_seconds=state_freshness_seconds,
                        max_exposures=max_managed_exposures,
                        min_trade_risk_pct=min_trade_risk_pct,
                    )
                except (ValueError, KeyError, TypeError) as exc:
                    rejected_key = source_id or "<missing>"
                    if rejected_key != last_rejected_signal:
                        print(f"rejected decision id={rejected_key}: {exc}", flush=True)
                        last_rejected_signal = rejected_key
                except Exception as exc:
                    print(f"WARN remote decision unavailable: {exc}", flush=True)
            else:
                try:
                    if auto_git_pull:
                        try:
                            signal = load_remote_signal(signal_path, branch)
                        except Exception as exc:
                            print(f"WARN remote signal fetch failed, using local copy: {exc}", flush=True)
                            signal = load_json(signal_path)
                    else:
                        signal = load_json(signal_path)
                    source_id = str(signal.get("id", "")).strip()
                    validate_signal(signal, max_risk_pct)
                except ValueError as exc:
                    rejected_key = source_id or "<missing>"
                    if rejected_key != last_rejected_signal:
                        print(f"rejected signal id={rejected_key}: {exc}", flush=True)
                        last_rejected_signal = rejected_key
                    signal = None

            if signal is not None:
                signal_id = str(signal.get("id", "")).strip()
                try:
                    action, created_epoch, valid_epoch = validate_signal(signal, max_risk_pct)
                except ValueError as exc:
                    if signal_id != last_rejected_signal:
                        print(f"rejected executable signal id={signal_id or '<missing>'}: {exc}", flush=True)
                        last_rejected_signal = signal_id
                else:
                    already_seen = state is not None and state.get("last_signal_id") == signal_id
                    if signal_id != last_published and not already_seen:
                        if decision_mode:
                            atomic_write(
                                executor_signal_path,
                                json.dumps(signal, indent=2, sort_keys=True) + "\n",
                            )
                        bridge_line = to_bridge_line(signal, created_epoch, valid_epoch)
                        for target in bridge_paths:
                            atomic_write(target, bridge_line)
                        last_published = signal_id
                        last_rejected_signal = ""
                        print(
                            f"published executable signal id={signal_id} action={action}"
                            + (" from decision" if decision_mode else ""),
                            flush=True,
                        )

        except subprocess.TimeoutExpired:
            print("ERROR git operation timed out", flush=True)
        except subprocess.CalledProcessError as exc:
            output = exc.stdout.strip() if exc.stdout else str(exc)
            print(f"ERROR git operation failed: {output}", flush=True)
        except Exception as exc:
            print(f"ERROR {type(exc).__name__}: {exc}", flush=True)

        time.sleep(poll_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
