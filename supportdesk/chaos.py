"""Run the same customer conversations with and without retries under injected failures.

python3 -m supportdesk.chaos --rate 0.3 --conversations 60
"""
import argparse
import json
import os
import statistics
import tempfile
import time

from supportdesk.agent import DEGRADED_REPLY, Agent
from supportdesk.db import get_connection, init_db
from supportdesk.guard import CircuitBreaker, Guard
from supportdesk.resilience import FaultInjector


def conversations(db_path, n):
    conn = get_connection(db_path)
    refundable = [r[0] for r in conn.execute("SELECT id FROM orders WHERE status IN ('shipped','delivered') ORDER BY id")]
    any_orders = [r[0] for r in conn.execute("SELECT id FROM orders ORDER BY id")]
    conn.close()
    out = []
    for i in range(n):
        if i % 2:
            out.append(("refund", f"Please refund $5 on {refundable[i % len(refundable)]}, it arrived damaged"))
        else:
            out.append(("status", f"Where is {any_orders[(i * 7) % len(any_orders)]}?"))
    return out


def run(rate, attempts, n):
    fd, db = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    init_db(db)
    agent = Agent(db, guard=Guard(db, CircuitBreaker(max_events=10_000), auto_limit=1_000),
                  faults=FaultInjector(rate, seed=7), attempts=attempts)
    ok, lat, refunds_asked = 0, [], 0
    for kind, msg in conversations(db, n):
        t = time.perf_counter()
        res = agent.run(msg)
        lat.append((time.perf_counter() - t) * 1000)
        ok += res["reply"] != DEGRADED_REPLY
        refunds_asked += kind == "refund"
    conn = get_connection(db)
    rows = conn.execute("SELECT COUNT(*), COUNT(DISTINCT idempotency_key) FROM refunds").fetchone()
    conn.close()
    os.remove(db)
    lat.sort()
    return {"attempts": attempts, "success_rate": ok / n, "p50_ms": statistics.median(lat),
            "p99_ms": lat[min(len(lat) - 1, int(len(lat) * 0.99))], "retries": agent.stats["retries"],
            "injected": agent.faults.injected, "refund_rows": rows[0], "duplicate_refunds": rows[0] - rows[1]}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--rate", type=float, default=0.3)
    ap.add_argument("--conversations", type=int, default=60)
    ap.add_argument("--attempts", type=int, default=5)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    results = [run(a.rate, 1, a.conversations), run(a.rate, a.attempts, a.conversations)]
    if a.json:
        print(json.dumps(results))
    else:
        print(f"{a.conversations} conversations, FAULT_RATE={a.rate}")
        print(f"{'retries':>8} {'success':>8} {'p50 ms':>7} {'p99 ms':>7} {'faults':>7} {'retried':>8} {'dup refunds':>12}")
        for r in results:
            label = "off" if r["attempts"] == 1 else f"{r['attempts']} tries"
            print(f"{label:>8} {r['success_rate']:>8.1%} {r['p50_ms']:>7.1f} {r['p99_ms']:>7.1f} {r['injected']:>7} {r['retries']:>8} {r['duplicate_refunds']:>12}")
