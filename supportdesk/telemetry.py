"""Per-interaction telemetry: one trace per /agent request.

Each trace records every model call and tool call (latency, ok, tokens) and
is stored in the interactions table. Cost is what the tokens would cost on a
hosted model (PRICE_IN_PER_MTOK / PRICE_OUT_PER_MTOK, default 3 and 15 USD
per million tokens), so the offline model still shows the bill you'd get.
"""
import json
import os
import statistics
import threading
import time
import uuid

from supportdesk.db import get_connection

PRICE_IN = float(os.environ.get("PRICE_IN_PER_MTOK", "3"))
PRICE_OUT = float(os.environ.get("PRICE_OUT_PER_MTOK", "15"))
_local = threading.local()


def start(session_id):
    _local.trace = {"trace_id": uuid.uuid4().hex[:16], "session_id": session_id, "t0": time.perf_counter(), "steps": []}
    return _local.trace


def current():
    return getattr(_local, "trace", None)


def step(kind, name, started, ok, **extra):
    t = current()
    if t is not None:
        t["steps"].append({"kind": kind, "name": name, "ms": round((time.perf_counter() - started) * 1000, 3), "ok": ok, **extra})


def finish(db_path, model_name, ok, retries):
    t = current()
    steps = t["steps"]
    tin = sum(s.get("tokens_in", 0) for s in steps)
    tout = sum(s.get("tokens_out", 0) for s in steps)
    row = {"trace_id": t["trace_id"], "session_id": t["session_id"], "model": model_name, "ok": int(ok),
           "latency_ms": round((time.perf_counter() - t["t0"]) * 1000, 3),
           "model_calls": sum(s["kind"] == "model" for s in steps),
           "tool_calls": sum(s["kind"] == "tool" for s in steps),
           "tool_errors": sum(s["kind"] == "tool" and not s["ok"] for s in steps),
           "retries": retries, "tokens_in": tin, "tokens_out": tout,
           "cost_usd": round(tin / 1e6 * PRICE_IN + tout / 1e6 * PRICE_OUT, 8), "steps": json.dumps(steps)}
    conn = get_connection(db_path)
    conn.execute(f"INSERT INTO interactions ({', '.join(row)}) VALUES ({', '.join('?' * len(row))})", list(row.values()))
    conn.commit()
    conn.close()
    _local.trace = None
    return row


def metrics(db_path=None):
    conn = get_connection(db_path)
    rows = conn.execute("SELECT latency_ms, ok, tool_calls, tool_errors, retries, tokens_in, tokens_out, cost_usd FROM interactions").fetchall()
    conn.close()
    if not rows:
        return {"interactions": 0}
    lat = sorted(r["latency_ms"] for r in rows)
    calls = sum(r["tool_calls"] for r in rows)
    n = len(rows)
    return {
        "interactions": n,
        "success_rate": round(sum(r["ok"] for r in rows) / n, 4),
        "latency_p50_ms": round(statistics.median(lat), 2),
        "latency_p99_ms": round(lat[min(n - 1, int(n * 0.99))], 2),
        "tool_calls": calls,
        "tool_success_rate": round(1 - sum(r["tool_errors"] for r in rows) / calls, 4) if calls else None,
        "retries": sum(r["retries"] for r in rows),
        "tokens_in": sum(r["tokens_in"] for r in rows),
        "tokens_out": sum(r["tokens_out"] for r in rows),
        "cost_usd": round(sum(r["cost_usd"] for r in rows), 6),
        "cost_per_1k_conversations_usd": round(sum(r["cost_usd"] for r in rows) / n * 1000, 4),
    }


def trace(db_path, trace_id):
    conn = get_connection(db_path)
    row = conn.execute("SELECT * FROM interactions WHERE trace_id = ?", (trace_id,)).fetchone()
    conn.close()
    if not row:
        return None
    out = dict(row)
    out["steps"] = json.loads(out["steps"])
    return out
