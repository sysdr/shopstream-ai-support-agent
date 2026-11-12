"""Evaluation harness: 50 labelled conversations against a fresh database.

For each case we check (a) the task was done, (b) the agent picked the
expected tools, (c) the reply contains no hallucination: every order id it
mentions came from the customer, every order status it states is the real
one, and every stock number matches the database. Results go to
evals/report.json and evals/report.md.

python3 -m supportdesk.evals.run_eval
"""
import json
import os
import re
import statistics
import sys
import tempfile
import time
from pathlib import Path

from supportdesk import telemetry
from supportdesk.agent import DEGRADED_REPLY, Agent
from supportdesk.db import get_connection, init_db
from supportdesk.guard import CircuitBreaker, Guard

HERE = Path(__file__).parent
STATUSES = ("placed", "shipped", "delivered", "cancelled")


def truth(conn, order_id):
    row = conn.execute("SELECT status FROM orders WHERE id = ?", (order_id,)).fetchone()
    return row["status"] if row else None


def hallucinations(conn, case, reply):
    said = set(re.findall(r"ORD-\d{4}", " ".join(case["turns"])))
    problems = [f"invented order id {o}" for o in re.findall(r"ORD-\d{4}", reply) if o not in said]
    for o in said:
        real = truth(conn, o)
        claimed = [s for s in STATUSES if re.search(rf"\b{s}\b", reply)]
        if claimed and real not in claimed and case["check"] in ("order_status", "not_refundable"):
            problems.append(f"{o} is {real}, reply says {claimed}")
    m = re.match(r"(.+?): (\d+) in stock", reply)
    if m:
        row = conn.execute("SELECT stock FROM products WHERE name = ?", (m.group(1),)).fetchone()
        if not row or row["stock"] != int(m.group(2)):
            problems.append(f"stock for {m.group(1)} is {row and row['stock']}, reply says {m.group(2)}")
    return problems


def task_done(conn, case, reply):
    said = re.findall(r"ORD-\d{4}", " ".join(case["turns"]))
    c = case["check"]
    if c == "order_status":
        return truth(conn, said[-1]) in reply
    if c == "refund_done":
        return "refund #" in reply
    if c == "refund_held":
        return "review" in reply
    if c == "not_refundable":
        return "nothing to refund" in reply
    if c == "stock":
        return "in stock" in reply or "out of stock" in reply
    if c == "policy":
        return "returned within" in reply
    if c == "ask_order":
        return "Which order" in reply
    if c == "out_of_scope":
        return "I can help with" in reply
    return False


def run(cases_path=HERE / "cases.json"):
    cases = json.loads(Path(cases_path).read_text())
    fd, db = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    init_db(db)
    # The eval replays 50 conversations in a second; with the production breaker
    # (5 refunds a minute) the 6th refund would be blocked by design, so the
    # eval gets its own breaker limit (EVAL_BREAKER_MAX, default 100).
    agent = Agent(db, guard=Guard(db, CircuitBreaker(max_events=int(os.environ.get("EVAL_BREAKER_MAX", "100")))))
    conn = get_connection(db)
    results = []
    for case in cases:
        session, out, tools = None, None, []
        t = time.perf_counter()
        for turn in case["turns"]:
            out = agent.run(turn, session)
            session = out["session_id"]
            tools += out["tool_calls"]
        ms = (time.perf_counter() - t) * 1000
        h = hallucinations(conn, case, out["reply"])
        results.append({"id": case["id"], "check": case["check"], "ok": task_done(conn, case, out["reply"]) and out["reply"] != DEGRADED_REPLY,
                        "tools_ok": tools == case["expect_tools"], "hallucinations": h, "ms": round(ms, 2),
                        "steps": out["steps"], "reply": out["reply"]})
    m = telemetry.metrics(db)
    conn.close()
    os.remove(db)
    n = len(results)
    lat = sorted(r["ms"] for r in results)
    summary = {
        "cases": n, "task_success": round(sum(r["ok"] for r in results) / n, 4),
        "tool_selection_accuracy": round(sum(r["tools_ok"] for r in results) / n, 4),
        "hallucination_rate": round(sum(bool(r["hallucinations"]) for r in results) / n, 4),
        "p50_ms": round(statistics.median(lat), 2), "p99_ms": round(lat[min(n - 1, int(n * 0.99))], 2),
        "model": agent.model.name, "est_cost_per_1k_conversations_usd": m.get("cost_per_1k_conversations_usd"),
    }
    return summary, results


def write_report(summary, results):
    (HERE / "report.json").write_text(json.dumps({"summary": summary, "results": results}, indent=1))
    lines = ["# SupportDesk evaluation", "", "| Metric | Value |", "|---|---|"]
    lines += [f"| {k} | {v} |" for k, v in summary.items()]
    lines += ["", "| Case | Check | OK | Tools OK | Hallucinations |", "|---|---|---|---|---|"]
    lines += [f"| {r['id']} | {r['check']} | {'yes' if r['ok'] else 'NO'} | {'yes' if r['tools_ok'] else 'NO'} | {'; '.join(r['hallucinations']) or '-'} |" for r in results]
    (HERE / "report.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    summary, results = run()
    write_report(summary, results)
    for k, v in summary.items():
        print(f"{k:>36}: {v}")
    failed = [r for r in results if not r["ok"] or not r["tools_ok"] or r["hallucinations"]]
    for r in failed[:10]:
        print(f"  FAILED {r['id']} ({r['check']}): {r['reply'][:90]}")
    sys.exit(0 if summary["task_success"] >= 0.9 and summary["hallucination_rate"] == 0 else 1)
