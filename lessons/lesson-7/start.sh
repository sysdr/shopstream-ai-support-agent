#!/usr/bin/env bash
# ShopStream SupportDesk — Day 7: Run the Evaluation Harness
# Writes the complete project into ./supportdesk, runs the unit tests, starts the
# server, writes verify.sh, verifies, then runs the demo. Stop with stop.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT/supportdesk"
cd "$ROOT"
PORT="${SUPPORTDESK_PORT:-8090}"
export SUPPORTDESK_PORT="$PORT"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

if ! command -v python3 >/dev/null; then echo "[ERROR] python3 not found. Install Python 3.10+."; exit 1; fi
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
  echo "[ERROR] Python 3.10+ is required, found $(python3 -V). Install a newer python3."; exit 1
fi

# Stop a previous run (idempotent) and start from fresh demo data.
if [ -f "$PROJECT_DIR/.run/app.pid" ]; then kill "$(cat "$PROJECT_DIR/.run/app.pid")" 2>/dev/null || true; rm -f "$PROJECT_DIR/.run/app.pid"; sleep 0.5; fi
rm -f "$PROJECT_DIR/shop.db" "$PROJECT_DIR"/shop.db-*

# ---- the code (26 files) ----
mkdir -p "$PROJECT_DIR/supportdesk"
mkdir -p "$PROJECT_DIR/supportdesk/evals"
mkdir -p "$PROJECT_DIR/tests"
cat > "$PROJECT_DIR/supportdesk/__init__.py" <<'SUPPORTDESK_EOF'
"""ShopStream SupportDesk Core Package"""
__version__ = "0.1.0"
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/agent.py" <<'SUPPORTDESK_EOF'
"""The agent loop: model decides, tools act, results go back to the model.

Each conversation is a session; its messages live in SQLite, so a second
message ("it's ORD-1020") continues the first ("I want a refund").
"""
import json
import os
import random
import time
import uuid

from supportdesk.db import get_connection
from supportdesk import telemetry
from supportdesk.guard import Guard
from supportdesk.model import get_model
from supportdesk.resilience import FaultInjector, RetryBudgetExceeded, retry
from supportdesk.tools import ToolExecutionError, ToolValidationError, build_registry

MAX_STEPS = 5
DEGRADED_REPLY = ("I'm having trouble reaching our order system right now. Please try again in a minute; "
                  "nothing will be refunded twice.")


class Agent:
    def __init__(self, db_path=None, model=None, guard=None, faults=None, attempts=None):
        self.db_path = db_path
        self.tools = build_registry(db_path)
        self.model = model or get_model(db_path)
        self.guard = guard or Guard(db_path)
        self.faults = faults or FaultInjector()  # Day 5: FAULT_RATE=0.3 makes 30% of calls fail
        self.attempts = int(os.environ.get("RETRY_ATTEMPTS", "5")) if attempts is None else attempts
        self.rng = random.Random(1)
        self.stats = {"retries": 0, "degraded": 0}

    def load(self, session_id):
        conn = get_connection(self.db_path)
        rows = conn.execute("SELECT content FROM messages WHERE session_id = ? ORDER BY id", (session_id,)).fetchall()
        conn.close()
        return [json.loads(r["content"]) for r in rows]

    def save(self, session_id, new_messages):
        conn = get_connection(self.db_path)
        conn.executemany("INSERT INTO messages (session_id, role, content) VALUES (?, ?, ?)",
                         [(session_id, m["role"], json.dumps(m)) for m in new_messages])
        conn.commit()
        conn.close()

    def run_tool(self, name, args):
        verdict, result = self.guard.check(name, args)  # Day 4: risky actions may be held or blocked
        if verdict != "allow":
            return result

        def attempt():
            fault = self.faults.roll()
            if fault == "before":
                raise TimeoutError(f"{name} timed out")
            out = self.tools.call(name, args)
            if fault == "after":  # the refund ran, the answer got lost: the retry must not refund again
                raise ConnectionError(f"{name} response lost")
            return out

        started = time.perf_counter()
        try:
            result = self._retry(attempt)
        except (ToolValidationError, ToolExecutionError) as e:
            telemetry.step("tool", name, started, False, error=str(e))
            return {"error": str(e)}
        except Exception:
            telemetry.step("tool", name, started, False, error="unavailable")
            raise
        telemetry.step("tool", name, started, True)
        self.guard.after(name, result)
        return result

    def _retry(self, fn):
        def count(_):
            self.stats["retries"] += 1
        return retry(fn, attempts=self.attempts, rng=self.rng, on_retry=count)

    def decide(self, history):
        def attempt():
            self.faults.maybe("model")
            return self.model.decide(history, self.tools.specs())
        started = time.perf_counter()
        try:
            d = self._retry(attempt)
        except Exception:
            telemetry.step("model", self.model.name, started, False)
            raise
        u = d.get("usage", {})
        telemetry.step("model", self.model.name, started, True, decision=d["type"],
                       tokens_in=u.get("input_tokens", 0), tokens_out=u.get("output_tokens", 0))
        return d

    def run(self, message, session_id=None):
        start = time.perf_counter()
        session_id = session_id or uuid.uuid4().hex[:12]
        trace = telemetry.start(session_id)  # Day 6: one trace per request
        retries_before = self.stats["retries"]
        history = self.load(session_id)
        new = [{"role": "user", "content": message, "session_id": session_id}]
        history += new
        steps, tool_calls, reply = 0, [], None
        degraded = False
        while steps < MAX_STEPS:
            steps += 1
            try:
                d = self.decide(history)
                if d["type"] == "tool":
                    result = self.run_tool(d["name"], d["args"])
            except RetryBudgetExceeded:
                degraded = True
                self.stats["degraded"] += 1
                reply = {"role": "assistant", "content": DEGRADED_REPLY}
                break
            if d["type"] == "reply":
                reply = {"role": "assistant", "content": d["text"], "pending": d.get("pending")}
                break
            tool_calls.append(d["name"])
            msg = {"role": "tool", "name": d["name"], "args": d["args"], "result": result, "id": d.get("id", f"t{steps}")}
            history.append(msg)
            new.append(msg)
        if reply is None:
            reply = {"role": "assistant", "content": "Sorry, I couldn't finish that. A human agent will follow up."}
        new.append(reply)
        self.save(session_id, new)
        telemetry.finish(self.db_path, self.model.name, not degraded, self.stats["retries"] - retries_before)
        return {"session_id": session_id, "reply": reply["content"], "steps": steps, "tool_calls": tool_calls,
                "model": self.model.name, "degraded": degraded, "trace_id": trace["trace_id"], "latency_ms": round((time.perf_counter() - start) * 1000, 2)}
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/app.py" <<'SUPPORTDESK_EOF'
"""SupportDesk HTTP API (standard library only).

GET  /health
POST /chat   {"message": "..."} -> {"intent", "slots", "reply", "latency_ms"}
GET  /tools                 tool names and argument schemas
POST /tools/NAME            run a tool with JSON arguments (400 bad arguments, 422 refused)
POST /agent  {"message": "...", "session_id": optional} -> agent reply, steps, tool calls
GET  /approvals             held refunds waiting for a person
POST /approvals/ID/approve  run the held refund (once); /reject to decline
GET  /guard                 circuit breaker state and counters
GET  /metrics               success rate, p50/p99, tool success, tokens, cost (all interactions)
GET  /traces/TRACE_ID       every model and tool step of one /agent request
"""
import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from supportdesk.agent import Agent
from supportdesk.db import get_connection, init_db
from supportdesk import telemetry
from supportdesk.guard import decide
from supportdesk.dispatcher import IntentDispatcher
from supportdesk.tools import ToolExecutionError, ToolValidationError

PORT = int(os.environ.get("SUPPORTDESK_PORT", 8090))
dispatcher = None
agent = None


class SupportHandler(BaseHTTPRequestHandler):
    def send_json(self, code, payload, headers=None):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length).decode("utf-8") or "{}")

    def do_GET(self):
        if self.path == "/health":
            return self.send_json(200, {"status": "ok"})
        if self.path.startswith("/approvals"):
            conn = get_connection()
            rows = [dict(r) for r in conn.execute("SELECT * FROM approvals WHERE status = 'pending' ORDER BY id")]
            conn.close()
            return self.send_json(200, {"pending": rows})
        if self.path == "/guard":
            return self.send_json(200, {"breaker": agent.guard.breaker.state, **agent.guard.stats})
        if self.path == "/metrics":
            return self.send_json(200, telemetry.metrics())
        if self.path.startswith("/traces/"):
            t = telemetry.trace(None, self.path[len("/traces/"):])
            return self.send_json(200 if t else 404, t or {"error": "no such trace"})
        if self.path == "/tools":
            return self.send_json(200, {"tools": dispatcher.tools.specs()})
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        try:
            data = self.read_json()
        except ValueError:
            return self.send_json(400, {"error": "body must be JSON"})
        if self.path == "/chat":
            return self.send_json(200, dispatcher.dispatch(str(data.get("message", ""))))
        if self.path == "/agent":
            if not str(data.get("message", "")).strip():
                return self.send_json(400, {"error": "message is required"})
            out = agent.run(str(data["message"]), data.get("session_id"))
            return self.send_json(200, out, {"X-Trace-Id": out["trace_id"]})
        m = re.fullmatch(r"/approvals/(\d+)/(approve|reject)", self.path)
        if m:
            code, payload = decide(None, agent.tools, int(m.group(1)), m.group(2) == "approve")
            return self.send_json(code, payload)
        if self.path.startswith("/tools/"):
            try:
                result = dispatcher.tools.call(self.path[len("/tools/"):], data)
            except ToolValidationError as e:
                return self.send_json(400, {"error": str(e), "field": e.field})
            except ToolExecutionError as e:
                return self.send_json(422, {"error": str(e)})
            return self.send_json(200, {"result": result})
        self.send_json(404, {"error": "not found"})

    def log_message(self, format, *args):
        return


def run_server():
    global dispatcher, agent
    init_db()
    dispatcher = IntentDispatcher()
    agent = Agent()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), SupportHandler)
    server.daemon_threads = True
    print(f"[INFO] Server starting on port {PORT}...", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    run_server()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/chaos.py" <<'SUPPORTDESK_EOF'
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
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/checks.py" <<'SUPPORTDESK_EOF'
"""Day 7 checks used by verify.sh."""
import sys

from supportdesk.client import get
from supportdesk.evals.run_eval import run


def fail(msg):
    print(f"[FAIL] {msg}")
    sys.exit(1)


if get("/health")[0] != 200:
    fail("server is not running: run start.sh first")
summary, _ = run()
print(f"[VERIFY] {summary['cases']} cases: task success {summary['task_success']:.0%}, tool selection "
      f"{summary['tool_selection_accuracy']:.0%}, hallucinations {summary['hallucination_rate']:.0%}")
if summary["task_success"] < 0.9 or summary["hallucination_rate"] > 0:
    fail("quality bar: task success >= 90% and no hallucinations")
if get("/metrics")[0] != 200:
    fail("/metrics is not answering")
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/client.py" <<'SUPPORTDESK_EOF'
"""Tiny HTTP client for demos and checks (standard library)."""
import json
import os
import urllib.error
import urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('SUPPORTDESK_PORT', '8090')}"


def call(method, path, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(BASE + path, data=body, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}"), dict(e.headers)


def get(path):
    return call("GET", path)


def post(path, data):
    return call("POST", path, data)


def pct(values, p):
    v = sorted(values)
    return v[min(len(v) - 1, int(len(v) * p))] if v else 0.0
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/db.py" <<'SUPPORTDESK_EOF'
import random
import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).parent.parent / "shop.db"


def get_connection(db_path=None):
    conn = sqlite3.connect(db_path or DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


SCHEMA = """
CREATE TABLE IF NOT EXISTS customers (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS products (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, stock INTEGER NOT NULL, price REAL NOT NULL);
CREATE TABLE IF NOT EXISTS orders (
    id TEXT PRIMARY KEY, customer_id INTEGER NOT NULL, status TEXT NOT NULL, item_name TEXT NOT NULL,
    created_at TEXT NOT NULL, shipped_at TEXT, FOREIGN KEY(customer_id) REFERENCES customers(id));
CREATE TABLE IF NOT EXISTS refund_policy (
    id INTEGER PRIMARY KEY AUTOINCREMENT, condition TEXT NOT NULL, max_days INTEGER NOT NULL, policy_text TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS refunds (
    id INTEGER PRIMARY KEY AUTOINCREMENT, order_id TEXT NOT NULL, amount REAL NOT NULL, reason TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS tool_calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT, tool TEXT NOT NULL, args TEXT NOT NULL, ok INTEGER NOT NULL,
    error TEXT, latency_ms REAL NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE INDEX IF NOT EXISTS messages_session ON messages(session_id, id);
CREATE TABLE IF NOT EXISTS approvals (
    id INTEGER PRIMARY KEY AUTOINCREMENT, order_id TEXT NOT NULL, amount REAL NOT NULL, reason TEXT NOT NULL,
    idempotency_key TEXT NOT NULL UNIQUE, status TEXT NOT NULL DEFAULT 'pending', refund_id INTEGER,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP, decided_at TEXT);
CREATE TABLE IF NOT EXISTS interactions (
    trace_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, model TEXT NOT NULL, ok INTEGER NOT NULL,
    latency_ms REAL NOT NULL, model_calls INTEGER NOT NULL, tool_calls INTEGER NOT NULL, tool_errors INTEGER NOT NULL,
    retries INTEGER NOT NULL, tokens_in INTEGER NOT NULL, tokens_out INTEGER NOT NULL, cost_usd REAL NOT NULL,
    steps TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP);
"""


def init_db(db_path=None):
    conn = get_connection(db_path)
    conn.executescript(SCHEMA)
    if conn.execute("SELECT COUNT(*) FROM customers").fetchone()[0] == 0:
        seed_db(conn)
    conn.close()


PRODUCTS = [
    "Wireless Headphones", "Ergonomic Desk Chair", "Mechanical Keyboard", "USB-C Fast Charger",
    "Noise Canceling Earbuds", "Gaming Mouse", "4K Monitor", "Laptop Stand", "Smart Watch",
    "Bluetooth Speaker", "HD Webcam", "Portable SSD 1TB", "Desk Pad", "Microphone Arm",
    "LED Desk Lamp", "Vertical Mouse", "Wireless Charger", "USB Hub", "Cable Management Kit",
    "Screen Cleaner Kit",
]


def seed_db(conn):
    rng = random.Random(42)
    first = ["Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Sam", "Dakota", "Reese", "Quinn"]
    last = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez"]
    customers = []
    for i in range(1, 51):
        fn, ln = rng.choice(first), rng.choice(last)
        customers.append((f"{fn} {ln}", f"{fn.lower()}.{ln.lower()}{i}@example.com"))
    conn.executemany("INSERT INTO customers (name, email) VALUES (?, ?)", customers)
    conn.executemany(
        "INSERT INTO products (name, stock, price) VALUES (?, ?, ?)",
        [(name, rng.randint(0, 150), round(rng.uniform(15.0, 299.0), 2)) for name in PRODUCTS],
    )
    orders = []
    for n in range(1001, 1301):
        status = rng.choice(["placed", "shipped", "delivered", "cancelled"])
        day = rng.randint(1, 28)
        shipped = f"2024-01-{day + 2:02d}" if status in ("shipped", "delivered") else None
        orders.append((f"ORD-{n}", rng.randint(1, 50), status, rng.choice(PRODUCTS), f"2024-01-{day:02d}", shipped))
    conn.executemany(
        "INSERT INTO orders (id, customer_id, status, item_name, created_at, shipped_at) VALUES (?, ?, ?, ?, ?, ?)", orders
    )
    conn.executemany(
        "INSERT INTO refund_policy (condition, max_days, policy_text) VALUES (?, ?, ?)",
        [
            ("unopened", 30, "Unopened items in original packaging can be returned within 30 days for a full refund."),
            ("opened", 14, "Opened items in working condition can be returned within 14 days subject to a 15% restocking fee."),
            ("defective", 90, "Defective products are covered under full warranty and eligible for free replacement or full refund within 90 days."),
        ],
    )
    conn.commit()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/demo.py" <<'SUPPORTDESK_EOF'
"""Day 7 demo: the full evaluation, and what the production breaker does to it."""
import os
import runpy
import subprocess
import sys

r = subprocess.run([sys.executable, "-m", "supportdesk.evals.run_eval"], capture_output=True, text=True)
print(r.stdout)
env = {**os.environ, "EVAL_BREAKER_MAX": "5"}
r2 = subprocess.run([sys.executable, "-m", "supportdesk.evals.run_eval"], capture_output=True, text=True, env=env)
print("Same eval with the production breaker (5 refunds per minute):")
print("\n".join(l for l in r2.stdout.splitlines() if "task_success" in l or "FAILED" in l))
print("Report written to supportdesk/supportdesk/evals/report.md")
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/dispatcher.py" <<'SUPPORTDESK_EOF'
import re
import time

from supportdesk.db import get_connection
from supportdesk.tools import ToolExecutionError, build_registry

ORDER_ID_PATTERN = re.compile(r"\b(ORD-\d{4})\b", re.IGNORECASE)
REFUND_KEYWORDS = re.compile(r"\b(refund|return|money back|cancel)\b", re.IGNORECASE)
STOCK_KEYWORDS = re.compile(r"\b(stock|inventory|available|in stock|have)\b", re.IGNORECASE)
POLICY_KEYWORDS = re.compile(r"\b(policy|rule|rules|returns|refunds)\b", re.IGNORECASE)
UNKNOWN_REPLY = ("I am sorry, I could not understand your request. Could you please provide your "
                 "order ID (e.g., ORD-1042) or product name?")


def classify(message):
    """Intent + slots from rules only (no database)."""
    order_match = ORDER_ID_PATTERN.search(message)
    if order_match:
        slots = {"order_id": order_match.group(1).upper()}
        return ("refund_request" if REFUND_KEYWORDS.search(message) else "order_status"), slots
    if STOCK_KEYWORDS.search(message):
        return "stock_check", {}
    if POLICY_KEYWORDS.search(message):
        return "refund_policy", {}
    return "unknown", {}


class IntentDispatcher:
    def __init__(self, db_path=None):
        self.db_path = db_path
        self.tools = build_registry(db_path)  # Day 2: lookups go through validated tools

    def dispatch(self, message: str) -> dict:
        start = time.perf_counter()
        text = message.strip()
        intent, slots = classify(text)
        reply = UNKNOWN_REPLY
        if intent == "order_status":
            reply = self._handle_order_status(slots["order_id"])
        elif intent == "refund_request":
            reply = self._handle_refund_request(slots["order_id"])
        elif intent == "stock_check":
            product = self._extract_product_name(text)
            if product:
                slots["product"] = product
                reply = self._handle_stock_check(product)
            else:
                reply = "Please specify a valid product name to check inventory."
        elif intent == "refund_policy":
            reply = self._handle_refund_policy()
        return {"intent": intent, "slots": slots, "reply": reply,
                "latency_ms": round((time.perf_counter() - start) * 1000, 2)}

    def _one(self, sql, args=()):
        conn = get_connection(self.db_path)
        row = conn.execute(sql, args).fetchone()
        conn.close()
        return row

    def _handle_order_status(self, order_id: str) -> str:
        try:
            o = self.tools.call("get_order_status", {"order_id": order_id})
        except ToolExecutionError:
            return f"Order {order_id} was not found in our system."
        return f"Order {o['order_id']} containing '{o['item_name']}' is currently {o['status']} (placed on {o['created_at']})."

    def _handle_refund_request(self, order_id: str) -> str:
        row = self._one("SELECT id, status, item_name FROM orders WHERE id = ?", (order_id,))
        if not row:
            return f"Order {order_id} was not found. Refund request cannot be processed."
        if row["status"] in ("delivered", "shipped"):
            return f"Refund request initialized for order {row['id']} ('{row['item_name']}'). Please return the item within 30 days of delivery."
        if row["status"] == "placed":
            return f"Order {row['id']} has not shipped yet. You can cancel it directly for a full refund."
        return f"Order {row['id']} is currently '{row['status']}' and is not eligible for return."

    def _extract_product_name(self, text: str):
        conn = get_connection(self.db_path)
        names = [r["name"] for r in conn.execute("SELECT name FROM products")]
        conn.close()
        for name in names:
            if name.lower() in text.lower():
                return name
        return None

    def _handle_stock_check(self, product_name: str) -> str:
        try:
            s = self.tools.call("check_stock", {"product": product_name})
        except ToolExecutionError:
            return f"Product '{product_name}' was not found in our catalog."
        if s["stock"] > 0:
            return f"Product '{s['product']}' is in stock ({s['stock']} units available)."
        return f"Product '{s['product']}' is currently out of stock."

    def _handle_refund_policy(self) -> str:
        row = self._one("SELECT policy_text FROM refund_policy WHERE condition = 'unopened'")
        return row["policy_text"] if row else "Standard policy: Returns accepted within 30 days of purchase with receipt."
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/evals/__init__.py" <<'SUPPORTDESK_EOF'

SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/evals/cases.json" <<'SUPPORTDESK_EOF'
[
 {
  "id": "c01",
  "turns": [
   "Where is ORD-1004?"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c02",
  "turns": [
   "What's the status of order ORD-1027?"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c03",
  "turns": [
   "Has ORD-1050 shipped yet?"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c04",
  "turns": [
   "Track ORD-1073 for me please"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c05",
  "turns": [
   "Any update on ORD-1096?"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c06",
  "turns": [
   "Can you check order ORD-1119"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c07",
  "turns": [
   "I'm waiting on ORD-1142, where is it?"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c08",
  "turns": [
   "status ORD-1165"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c09",
  "turns": [
   "When will ORD-1188 arrive?"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c10",
  "turns": [
   "Is ORD-1211 on its way?"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c11",
  "turns": [
   "Where is my order?",
   "It's ORD-1006"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c12",
  "turns": [
   "Where is my order?",
   "It's ORD-1037"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c13",
  "turns": [
   "Where is my order?",
   "It's ORD-1068"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c14",
  "turns": [
   "Where is my order?",
   "It's ORD-1099"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c15",
  "turns": [
   "Where is my order?",
   "It's ORD-1130"
  ],
  "check": "order_status",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c16",
  "turns": [
   "Please refund $10 on ORD-1001, it arrived damaged"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c17",
  "turns": [
   "Refund $15 for ORD-1002, it came late"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c18",
  "turns": [
   "Please refund $10 on ORD-1005, it arrived damaged"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c19",
  "turns": [
   "Refund $15 for ORD-1008, it came late"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c20",
  "turns": [
   "Please refund $10 on ORD-1009, it arrived damaged"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c21",
  "turns": [
   "Refund $15 for ORD-1011, it came late"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c22",
  "turns": [
   "I want a full refund for ORD-1021, it is broken"
  ],
  "check": "refund_held",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c23",
  "turns": [
   "I want a full refund for ORD-1026, it is broken"
  ],
  "check": "refund_held",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c24",
  "turns": [
   "I want a full refund for ORD-1033, it is broken"
  ],
  "check": "refund_held",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c25",
  "turns": [
   "I want a full refund for ORD-1035, it is broken"
  ],
  "check": "refund_held",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c26",
  "turns": [
   "Refund ORD-1003 please"
  ],
  "check": "not_refundable",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c27",
  "turns": [
   "Refund ORD-1004 please"
  ],
  "check": "not_refundable",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c28",
  "turns": [
   "Refund ORD-1006 please"
  ],
  "check": "not_refundable",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c29",
  "turns": [
   "I need my money back for ORD-1010"
  ],
  "check": "not_refundable",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c30",
  "turns": [
   "I need my money back for ORD-1012"
  ],
  "check": "not_refundable",
  "expect_tools": [
   "get_order_status"
  ]
 },
 {
  "id": "c31",
  "turns": [
   "I want a refund",
   "ORD-1045, it was the wrong colour, refund $8"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c32",
  "turns": [
   "I want a refund",
   "ORD-1048, it was the wrong colour, refund $8"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c33",
  "turns": [
   "I want a refund",
   "ORD-1049, it was the wrong colour, refund $8"
  ],
  "check": "refund_done",
  "expect_tools": [
   "get_order_status",
   "process_refund"
  ]
 },
 {
  "id": "c34",
  "turns": [
   "Do you have Gaming Mouse in stock?"
  ],
  "check": "stock",
  "expect_tools": [
   "check_stock"
  ]
 },
 {
  "id": "c35",
  "turns": [
   "Do you have 4K Monitor in stock?"
  ],
  "check": "stock",
  "expect_tools": [
   "check_stock"
  ]
 },
 {
  "id": "c36",
  "turns": [
   "Do you have Wireless Headphones in stock?"
  ],
  "check": "stock",
  "expect_tools": [
   "check_stock"
  ]
 },
 {
  "id": "c37",
  "turns": [
   "Do you have USB Hub in stock?"
  ],
  "check": "stock",
  "expect_tools": [
   "check_stock"
  ]
 },
 {
  "id": "c38",
  "turns": [
   "Do you have Laptop Stand in stock?"
  ],
  "check": "stock",
  "expect_tools": [
   "check_stock"
  ]
 },
 {
  "id": "c39",
  "turns": [
   "Do you have Smart Watch in stock?"
  ],
  "check": "stock",
  "expect_tools": [
   "check_stock"
  ]
 },
 {
  "id": "c40",
  "turns": [
   "Do you have Desk Pad in stock?"
  ],
  "check": "stock",
  "expect_tools": [
   "check_stock"
  ]
 },
 {
  "id": "c41",
  "turns": [
   "What is your refund policy?"
  ],
  "check": "policy",
  "expect_tools": []
 },
 {
  "id": "c42",
  "turns": [
   "What are the return rules?"
  ],
  "check": "policy",
  "expect_tools": []
 },
 {
  "id": "c43",
  "turns": [
   "Tell me about the return policy"
  ],
  "check": "policy",
  "expect_tools": []
 },
 {
  "id": "c44",
  "turns": [
   "Where is my order?"
  ],
  "check": "ask_order",
  "expect_tools": []
 },
 {
  "id": "c45",
  "turns": [
   "I want a refund"
  ],
  "check": "ask_order",
  "expect_tools": []
 },
 {
  "id": "c46",
  "turns": [
   "Tell me a joke"
  ],
  "check": "out_of_scope",
  "expect_tools": []
 },
 {
  "id": "c47",
  "turns": [
   "Who won the World Cup?"
  ],
  "check": "out_of_scope",
  "expect_tools": []
 },
 {
  "id": "c48",
  "turns": [
   "Write a poem about cats"
  ],
  "check": "out_of_scope",
  "expect_tools": []
 },
 {
  "id": "c49",
  "turns": [
   "What's the weather in Seattle?"
  ],
  "check": "out_of_scope",
  "expect_tools": []
 },
 {
  "id": "c50",
  "turns": [
   "Can you help me with my homework?"
  ],
  "check": "out_of_scope",
  "expect_tools": []
 }
]
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/evals/run_eval.py" <<'SUPPORTDESK_EOF'
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
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/guard.py" <<'SUPPORTDESK_EOF'
"""Human-in-the-loop guard for risky tool calls.

- Refunds up to REFUND_AUTO_LIMIT run automatically.
- Larger refunds are HELD: an approvals row is created and a person decides.
- A circuit breaker counts automatic refunds; if more than BREAKER_MAX_REFUNDS
  happen within BREAKER_WINDOW_S, it OPENS and blocks refunds for
  BREAKER_COOLDOWN_S, then lets one trial through (HALF_OPEN).
"""
import os
import threading
import time

from supportdesk.db import get_connection

REFUND_AUTO_LIMIT = float(os.environ.get("REFUND_AUTO_LIMIT", "50"))


class CircuitBreaker:
    CLOSED, OPEN, HALF_OPEN = "closed", "open", "half_open"

    def __init__(self, max_events=None, window_s=None, cooldown_s=None, clock=time.monotonic):
        self.max_events = int(max_events or os.environ.get("BREAKER_MAX_REFUNDS", "5"))
        self.window_s = float(window_s or os.environ.get("BREAKER_WINDOW_S", "60"))
        self.cooldown_s = float(cooldown_s or os.environ.get("BREAKER_COOLDOWN_S", "30"))
        self.clock = clock
        self.events, self.opened_at, self.trial = [], None, False
        self.lock = threading.Lock()

    @property
    def state(self):
        if self.opened_at is None:
            return self.CLOSED
        return self.HALF_OPEN if self.clock() - self.opened_at >= self.cooldown_s else self.OPEN

    def allow(self):
        with self.lock:
            state = self.state
            if state == self.CLOSED:
                return True
            if state == self.HALF_OPEN and not self.trial:
                self.trial = True  # exactly one trial request
                return True
            return False

    def record(self):
        """Call after an automatic refund succeeded."""
        with self.lock:
            now = self.clock()
            if self.state == self.HALF_OPEN:  # the trial went through: close again
                self.opened_at, self.trial, self.events = None, False, []
            self.events = [t for t in self.events if now - t < self.window_s] + [now]
            if len(self.events) > self.max_events:
                self.opened_at, self.trial = now, False


class Guard:
    def __init__(self, db_path=None, breaker=None, auto_limit=None):
        self.db_path = db_path
        self.auto_limit = REFUND_AUTO_LIMIT if auto_limit is None else auto_limit
        self.breaker = breaker or CircuitBreaker()
        self.stats = {"auto": 0, "held": 0, "blocked": 0}

    def check(self, name, args):
        """Returns ("allow", None), ("hold", result) or ("block", result)."""
        if name != "process_refund":
            return "allow", None
        if args.get("amount", 0) > self.auto_limit:
            conn = get_connection(self.db_path)
            row = conn.execute("SELECT id FROM approvals WHERE idempotency_key = ?", (args["idempotency_key"],)).fetchone()
            approval_id = row["id"] if row else conn.execute(
                "INSERT INTO approvals (order_id, amount, reason, idempotency_key) VALUES (?, ?, ?, ?)",
                (args["order_id"], args["amount"], args["reason"], args["idempotency_key"])).lastrowid
            conn.commit()
            conn.close()
            self.stats["held"] += 1
            return "hold", {"status": "pending_approval", "approval_id": approval_id}
        if not self.breaker.allow():
            self.stats["blocked"] += 1
            return "block", {"error": f"refunds are paused (circuit {self.breaker.state}): too many automatic refunds in {self.breaker.window_s:.0f}s"}
        return "allow", None

    def after(self, name, result):
        if name == "process_refund" and "error" not in result and not result.get("duplicate"):
            self.stats["auto"] += 1
            self.breaker.record()


def decide(db_path, tools, approval_id, approve):
    """A person approves or rejects a held refund. Approving twice never refunds twice."""
    conn = get_connection(db_path)
    row = conn.execute("SELECT * FROM approvals WHERE id = ?", (approval_id,)).fetchone()
    if not row:
        conn.close()
        return 404, {"error": "no such approval"}
    if row["status"] != "pending":
        conn.close()
        return 409, {"error": f"already {row['status']}", "refund_id": row["refund_id"]}
    refund_id = None
    if approve:
        result = tools.call("process_refund", {"order_id": row["order_id"], "amount": row["amount"],
                                               "reason": row["reason"], "idempotency_key": row["idempotency_key"]})
        refund_id = result["refund_id"]
    status = "approved" if approve else "rejected"
    conn.execute("UPDATE approvals SET status = ?, refund_id = ?, decided_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 'pending'",
                 (status, refund_id, approval_id))
    conn.commit()
    conn.close()
    return 200, {"approval_id": approval_id, "status": status, "refund_id": refund_id}
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/model.py" <<'SUPPORTDESK_EOF'
"""The model behind the agent, behind one small interface.

decide(history, tools) returns either
    {"type": "tool", "name": ..., "args": {...}}      call a tool next, or
    {"type": "reply", "text": ..., "pending": ...}    answer the customer.
plus "usage": estimated input/output tokens.

OfflineModel is deterministic (rules + the conversation so far): it is the
default, and it is what the tests and verify.sh use. ClaudeModel calls the
Anthropic Messages API with urllib when ANTHROPIC_API_KEY is set.
"""
import json
import os
import re
import urllib.request

from supportdesk.db import get_connection
from supportdesk.dispatcher import ORDER_ID_PATTERN, POLICY_KEYWORDS, REFUND_KEYWORDS, STOCK_KEYWORDS

REASONS = [("damaged", r"broken|damaged|cracked|defective|faulty"), ("late", r"late|delayed|took too long"),
           ("not_as_described", r"wrong|not as described|different"), ("changed_mind", r"changed my mind|don't want|do not want")]


def estimate_tokens(obj):
    return max(1, len(json.dumps(obj, default=str)) // 4)


class OfflineModel:
    name = "offline-rules-v1"

    def __init__(self, db_path=None):
        self.db_path = db_path
        conn = get_connection(db_path)
        self.products = [r["name"] for r in conn.execute("SELECT name FROM products")]
        self.policy = conn.execute("SELECT policy_text FROM refund_policy WHERE condition = 'unopened'").fetchone()["policy_text"]
        conn.close()

    def _turn(self, history):
        """The latest user message, the tool results since then, and remembered context."""
        last_user = max(i for i, m in enumerate(history) if m["role"] == "user")
        text = history[last_user]["content"]
        results = [m for m in history[last_user + 1:] if m["role"] == "tool"]
        pending, known_order = None, None
        for m in history[:last_user]:
            if m["role"] == "assistant":
                pending = m.get("pending")
            if m["role"] == "user":
                hit = ORDER_ID_PATTERN.search(m["content"])
                known_order = hit.group(1).upper() if hit else known_order
        return text, results, pending, known_order

    def decide(self, history, tools=None):
        text, results, pending, known_order = self._turn(history)
        decision = self._decide(text, results, pending, known_order, history)
        decision["usage"] = {"input_tokens": estimate_tokens(history), "output_tokens": estimate_tokens(decision)}
        return decision

    def _decide(self, text, results, pending, known_order, history):
        hit = ORDER_ID_PATTERN.search(text)
        order_id = hit.group(1).upper() if hit else None
        if REFUND_KEYWORDS.search(text) and (order_id or known_order or not POLICY_KEYWORDS.search(text)):
            intent = "refund_request"
        elif order_id or re.search(r"\b(where|status|track|shipped|arrive)\b", text, re.I):
            intent = "order_status"
        elif STOCK_KEYWORDS.search(text):
            intent = "stock_check"
        elif POLICY_KEYWORDS.search(text):
            intent = "refund_policy"
        else:
            intent = pending if (pending and order_id) else "unknown"
        if pending and order_id and intent == "order_status" and not REFUND_KEYWORDS.search(text):
            intent = pending  # "ORD-1020" answering "which order?" continues the earlier request
        order_id = order_id or (known_order if intent in ("order_status", "refund_request") else None)

        if intent in ("order_status", "refund_request") and not order_id:
            return {"type": "reply", "pending": intent,
                    "text": "Sure, I can help with that. Which order is it? Please share the order id (it starts with ORD-)."}
        if intent == "order_status":
            if not results:
                return {"type": "tool", "name": "get_order_status", "args": {"order_id": order_id}}
            r = results[-1]["result"]
            if "error" in r:
                return {"type": "reply", "text": f"I couldn't find order {order_id}. Please check the id."}
            when = f", shipped on {r['shipped_at']}" if r.get("shipped_at") else ""
            return {"type": "reply", "text": f"Order {r['order_id']} ({r['item_name']}) is {r['status']}{when}."}
        if intent == "refund_request":
            reason = next((name for name, pat in REASONS if re.search(pat, text, re.I)), "other")
            if not results:
                return {"type": "tool", "name": "get_order_status", "args": {"order_id": order_id}}
            last = results[-1]
            if last["name"] == "get_order_status":
                o = last["result"]
                if "error" in o:
                    return {"type": "reply", "text": f"I couldn't find order {order_id}. Please check the id."}
                if o["status"] not in ("shipped", "delivered"):
                    return {"type": "reply", "text": f"Order {order_id} is {o['status']}, so there is nothing to refund yet."}
                session = history[0].get("session_id", "s")
                asked = re.search(r"\$\s?(\d+(?:\.\d{1,2})?)", text)  # "refund $20 of ORD-1020" = partial refund
                amount = min(float(asked.group(1)), o["price"]) if asked else o["price"]
                return {"type": "tool", "name": "process_refund",
                        "args": {"order_id": order_id, "amount": round(amount, 2), "reason": reason,
                                 "idempotency_key": f"{session}-{order_id}"}}
            r = last["result"]
            if r.get("status") == "pending_approval":
                return {"type": "reply", "text": f"Your refund for {order_id} needs a quick review by our team (request #{r['approval_id']}). You'll hear from us within one business day."}
            if "error" in r:
                return {"type": "reply", "text": f"I couldn't refund order {order_id}: {r['error']}"}
            return {"type": "reply", "text": f"Done: refund #{r['refund_id']} of ${r['amount']:.2f} for order {order_id} is on its way."}
        if intent == "stock_check":
            product = next((p for p in self.products if p.lower() in text.lower()), None)
            if not product:
                return {"type": "reply", "text": "Which product would you like me to check?"}
            if not results:
                return {"type": "tool", "name": "check_stock", "args": {"product": product}}
            r = results[-1]["result"]
            if "error" in r:
                return {"type": "reply", "text": f"I couldn't check {product} right now."}
            return {"type": "reply", "text": f"{r['product']}: {r['stock']} in stock." if r["stock"] else f"{r['product']} is out of stock right now."}
        if intent == "refund_policy":
            return {"type": "reply", "text": self.policy}
        return {"type": "reply", "text": "I can help with order status, refunds, stock and our return policy. What do you need?"}


class ClaudeModel:
    """Anthropic Messages API with tool use (standard library HTTPS)."""

    def __init__(self, api_key, model=None):
        self.api_key = api_key
        self.name = model or os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-5")

    def decide(self, history, tools):
        messages, system = [], ("You are ShopStream's support agent. Use the tools for every fact about orders, "
                                "stock and refunds; never guess an order status. Be brief.")
        for m in history:
            if m["role"] == "user":
                messages.append({"role": "user", "content": m["content"]})
            elif m["role"] == "assistant":
                messages.append({"role": "assistant", "content": m["content"]})
            elif m["role"] == "tool":
                tid = m.get("id", "t")
                messages.append({"role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": m["name"], "input": m["args"]}]})
                messages.append({"role": "user", "content": [{"type": "tool_result", "tool_use_id": tid, "content": json.dumps(m["result"])}]})
        body = json.dumps({"model": self.name, "max_tokens": 512, "system": system, "tools": tools, "messages": messages}).encode()
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, headers={
            "x-api-key": self.api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=float(os.environ.get("MODEL_TIMEOUT", "30"))) as resp:
            out = json.loads(resp.read())
        usage = {"input_tokens": out["usage"]["input_tokens"], "output_tokens": out["usage"]["output_tokens"]}
        for block in out["content"]:
            if block["type"] == "tool_use":
                return {"type": "tool", "name": block["name"], "args": block["input"], "id": block["id"], "usage": usage}
        text = " ".join(b.get("text", "") for b in out["content"] if b["type"] == "text").strip()
        return {"type": "reply", "text": text, "usage": usage}


def get_model(db_path=None):
    key = os.environ.get("ANTHROPIC_API_KEY")
    return ClaudeModel(key) if key else OfflineModel(db_path)
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/resilience.py" <<'SUPPORTDESK_EOF'
"""Failure injection and retries.

FaultInjector makes the model call or a tool call fail with probability
FAULT_RATE: a timeout or a dropped connection before the call, or a lost
response AFTER the tool already ran (the nasty one: the refund happened but
we don't know). retry() retries transient errors with exponential backoff and
full jitter inside a total time budget.
"""
import os
import random
import time

TRANSIENT = (TimeoutError, ConnectionError)


class RetryBudgetExceeded(Exception):
    def __init__(self, last_error, attempts):
        super().__init__(f"gave up after {attempts} attempts: {last_error}")
        self.last_error, self.attempts = last_error, attempts


class FaultInjector:
    def __init__(self, rate=None, seed=None):
        self.rate = float(os.environ.get("FAULT_RATE", "0") if rate is None else rate)
        self.rng = random.Random(seed if seed is not None else int(os.environ.get("FAULT_SEED", "7")))
        self.injected = 0

    def roll(self):
        """None (no fault), "before" (timeout or refused) or "after" (response lost)."""
        if not self.rate or self.rng.random() >= self.rate:
            return None
        self.injected += 1
        return self.rng.choice(["before", "before", "after"])

    def maybe(self, where):
        """For the model call: fail before it with probability rate."""
        if self.roll():
            raise (TimeoutError if self.rng.random() < 0.5 else ConnectionError)(f"injected failure at {where}")


def retry(fn, attempts=4, base=0.02, cap=0.25, budget_s=2.0, rng=None, sleep=time.sleep, on_retry=None):
    """Call fn(); on a transient error wait random(0, min(cap, base * 2**n)) and try again."""
    rng = rng or random.Random()
    deadline = time.monotonic() + budget_s
    last = None
    for n in range(attempts):
        try:
            return fn()
        except TRANSIENT as e:
            last = e
            if n == attempts - 1:
                break
            delay = rng.uniform(0, min(cap, base * 2 ** n))
            if time.monotonic() + delay > deadline:
                break
            if on_retry:
                on_retry(e)
            sleep(delay)
    raise RetryBudgetExceeded(last, n + 1)
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/telemetry.py" <<'SUPPORTDESK_EOF'
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
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/tools.py" <<'SUPPORTDESK_EOF'
"""Tool registry: every tool declares the shape of its arguments and its result.

Arguments are validated BEFORE the tool runs, results AFTER, and every call
is written to the tool_calls audit table. Nothing a model (or a user) sends
reaches the database without passing the schema first.
"""
import json
import re
import time

from supportdesk.db import get_connection

TYPES = {"string": str, "number": (int, float), "integer": int, "boolean": bool, "object": dict}


class ToolValidationError(ValueError):
    """Bad arguments or a bad result. `field` names the offending field."""

    def __init__(self, field, message):
        super().__init__(f"{field}: {message}")
        self.field = field


class ToolExecutionError(RuntimeError):
    """The arguments were valid but the business rule said no."""


def validate(schema, data, where="args"):
    """A small subset of JSON Schema: type, required, enum, minimum, maximum, pattern, maxLength."""
    if not isinstance(data, dict):
        raise ToolValidationError(where, "must be an object")
    props = schema.get("properties", {})
    for name in schema.get("required", []):
        if name not in data or data[name] is None:
            raise ToolValidationError(name, "is required")
    if not schema.get("additional", False):
        extra = set(data) - set(props)
        if extra:
            raise ToolValidationError(sorted(extra)[0], "is not an allowed field")
    for name, rule in props.items():
        if name not in data or data[name] is None:
            continue
        value = data[name]
        expected = TYPES[rule["type"]]
        if isinstance(value, bool) and rule["type"] in ("number", "integer"):
            raise ToolValidationError(name, f"must be {rule['type']}")
        if not isinstance(value, expected):
            raise ToolValidationError(name, f"must be {rule['type']}")
        if "enum" in rule and value not in rule["enum"]:
            raise ToolValidationError(name, f"must be one of {rule['enum']}")
        if "minimum" in rule and value < rule["minimum"]:
            raise ToolValidationError(name, f"must be >= {rule['minimum']}")
        if "maximum" in rule and value > rule["maximum"]:
            raise ToolValidationError(name, f"must be <= {rule['maximum']}")
        if "pattern" in rule and not re.fullmatch(rule["pattern"], value):
            raise ToolValidationError(name, f"must match {rule['pattern']}")
        if "maxLength" in rule and len(value) > rule["maxLength"]:
            raise ToolValidationError(name, f"must be at most {rule['maxLength']} characters")
    return data


class Tool:
    def __init__(self, name, description, params, returns, fn):
        self.name, self.description, self.params, self.returns, self.fn = name, description, params, returns, fn

    def spec(self):
        return {"name": self.name, "description": self.description, "input_schema": self.params}


class ToolRegistry:
    def __init__(self, db_path=None):
        self.db_path = db_path
        self.tools = {}

    def register(self, tool):
        self.tools[tool.name] = tool

    def specs(self):
        return [t.spec() for t in self.tools.values()]

    def call(self, name, args):
        start = time.perf_counter()
        ok, error = False, None
        try:
            if name not in self.tools:
                raise ToolValidationError("tool", f"unknown tool '{name}'")
            tool = self.tools[name]
            validate(tool.params, args)
            result = tool.fn(self.db_path, **args)
            validate(tool.returns, result, where="result")
            ok = True
            return result
        except (ToolValidationError, ToolExecutionError) as e:
            error = str(e)
            raise
        finally:
            conn = get_connection(self.db_path)
            conn.execute(
                "INSERT INTO tool_calls (tool, args, ok, error, latency_ms) VALUES (?, ?, ?, ?, ?)",
                (name, json.dumps(args, default=str)[:2000], int(ok), error, round((time.perf_counter() - start) * 1000, 3)),
            )
            conn.commit()
            conn.close()


# ── the tools ──────────────────────────────────────────────────────────────

ORDER_ID = {"type": "string", "pattern": r"ORD-\d{4}"}


def get_order_status(db_path, order_id):
    conn = get_connection(db_path)
    row = conn.execute(
        """SELECT o.id, o.status, o.item_name, o.created_at, o.shipped_at, p.price
           FROM orders o JOIN products p ON p.name = o.item_name WHERE o.id = ?""",
        (order_id,),
    ).fetchone()
    conn.close()
    if not row:
        raise ToolExecutionError(f"order {order_id} not found")
    return {"order_id": row["id"], "status": row["status"], "item_name": row["item_name"],
            "created_at": row["created_at"], "shipped_at": row["shipped_at"], "price": row["price"]}


def check_stock(db_path, product):
    conn = get_connection(db_path)
    row = conn.execute("SELECT name, stock, price FROM products WHERE lower(name) = lower(?)", (product,)).fetchone()
    conn.close()
    if not row:
        raise ToolExecutionError(f"product '{product}' not found")
    return {"product": row["name"], "stock": row["stock"], "price": row["price"]}


def process_refund(db_path, order_id, amount, reason, idempotency_key):
    conn = get_connection(db_path)
    try:
        done = conn.execute("SELECT id, order_id, amount FROM refunds WHERE idempotency_key = ?", (idempotency_key,)).fetchone()
        if done:  # the same request again (a retry): return the first result, change nothing
            return {"refund_id": done["id"], "order_id": done["order_id"], "amount": done["amount"], "duplicate": True}
        order = conn.execute(
            "SELECT o.status, p.price FROM orders o JOIN products p ON p.name = o.item_name WHERE o.id = ?", (order_id,)
        ).fetchone()
        if not order:
            raise ToolExecutionError(f"order {order_id} not found")
        if order["status"] not in ("shipped", "delivered"):
            raise ToolExecutionError(f"order {order_id} is {order['status']}; only shipped or delivered orders can be refunded")
        already = conn.execute("SELECT COALESCE(SUM(amount), 0) FROM refunds WHERE order_id = ?", (order_id,)).fetchone()[0]
        if amount + already > order["price"] + 1e-9:
            raise ToolExecutionError(f"order {order_id} has ${already:.2f} refunded already; "
                                     f"${amount:.2f} more would exceed the item price ${order['price']:.2f}")
        cur = conn.execute(
            "INSERT INTO refunds (order_id, amount, reason, idempotency_key) VALUES (?, ?, ?, ?)",
            (order_id, amount, reason, idempotency_key),
        )
        conn.commit()
        return {"refund_id": cur.lastrowid, "order_id": order_id, "amount": amount, "duplicate": False}
    finally:
        conn.close()


def build_registry(db_path=None):
    reg = ToolRegistry(db_path)
    reg.register(Tool(
        "get_order_status", "Look up an order's status, item, dates and price.",
        {"type": "object", "properties": {"order_id": ORDER_ID}, "required": ["order_id"]},
        {"type": "object", "additional": True,
         "properties": {"order_id": ORDER_ID, "status": {"type": "string", "enum": ["placed", "shipped", "delivered", "cancelled"]},
                        "item_name": {"type": "string"}, "price": {"type": "number", "minimum": 0}},
         "required": ["order_id", "status", "item_name", "price"]},
        get_order_status))
    reg.register(Tool(
        "check_stock", "How many units of a product are in stock.",
        {"type": "object", "properties": {"product": {"type": "string", "maxLength": 80}}, "required": ["product"]},
        {"type": "object", "properties": {"product": {"type": "string"}, "stock": {"type": "integer", "minimum": 0},
                                          "price": {"type": "number", "minimum": 0}},
         "required": ["product", "stock"]},
        check_stock))
    reg.register(Tool(
        "process_refund", "Refund an order. Safe to retry: the same idempotency_key never refunds twice.",
        {"type": "object", "properties": {
            "order_id": ORDER_ID, "amount": {"type": "number", "minimum": 0.01, "maximum": 10000},
            "reason": {"type": "string", "enum": ["damaged", "not_as_described", "late", "changed_mind", "other"]},
            "idempotency_key": {"type": "string", "pattern": r"[A-Za-z0-9_.:-]{6,64}"}},
         "required": ["order_id", "amount", "reason", "idempotency_key"]},
        {"type": "object", "properties": {"refund_id": {"type": "integer"}, "order_id": ORDER_ID,
                                          "amount": {"type": "number"}, "duplicate": {"type": "boolean"}},
         "required": ["refund_id", "order_id", "amount", "duplicate"]},
        process_refund))
    return reg
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/__init__.py" <<'SUPPORTDESK_EOF'

SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/cases.json" <<'SUPPORTDESK_EOF'
[
 {
  "message": "Where is my order ORD-1005?",
  "expected_intent": "order_status"
 },
 {
  "message": "Can you tell me the status of order ORD-1012?",
  "expected_intent": "order_status"
 },
 {
  "message": "Track order ORD-1045 please",
  "expected_intent": "order_status"
 },
 {
  "message": "I need an update on ORD-1100",
  "expected_intent": "order_status"
 },
 {
  "message": "What is going on with order ORD-1200?",
  "expected_intent": "order_status"
 },
 {
  "message": "Has ORD-1050 shipped yet?",
  "expected_intent": "order_status"
 },
 {
  "message": "Check status for ORD-1080",
  "expected_intent": "order_status"
 },
 {
  "message": "Where is ORD-1001?",
  "expected_intent": "order_status"
 },
 {
  "message": "Status of ORD-1299",
  "expected_intent": "order_status"
 },
 {
  "message": "Please locate ORD-1150",
  "expected_intent": "order_status"
 },
 {
  "message": "I want to request a refund for order ORD-1020",
  "expected_intent": "refund_request"
 },
 {
  "message": "How do I return item from ORD-1033?",
  "expected_intent": "refund_request"
 },
 {
  "message": "Can I get my money back for ORD-1077?",
  "expected_intent": "refund_request"
 },
 {
  "message": "I need a refund on ORD-1120",
  "expected_intent": "refund_request"
 },
 {
  "message": "Process return for ORD-1210",
  "expected_intent": "refund_request"
 },
 {
  "message": "What is your refund policy?",
  "expected_intent": "refund_policy"
 },
 {
  "message": "What are the return rules?",
  "expected_intent": "refund_policy"
 },
 {
  "message": "Tell me about the return policy",
  "expected_intent": "refund_policy"
 },
 {
  "message": "Do you have Wireless Headphones in stock?",
  "expected_intent": "stock_check"
 },
 {
  "message": "Is Mechanical Keyboard available?",
  "expected_intent": "stock_check"
 },
 {
  "message": "Check inventory for USB-C Fast Charger",
  "expected_intent": "stock_check"
 },
 {
  "message": "Do you have Noise Canceling Earbuds in stock?",
  "expected_intent": "stock_check"
 },
 {
  "message": "Is Ergonomic Desk Chair available?",
  "expected_intent": "stock_check"
 },
 {
  "message": "How many Wireless Headphones do you have left?",
  "expected_intent": "stock_check"
 },
 {
  "message": "Stock status for Mechanical Keyboard",
  "expected_intent": "stock_check"
 },
 {
  "message": "Do you have stock for Gaming Mouse?",
  "expected_intent": "stock_check"
 },
 {
  "message": "What is the weather in Seattle?",
  "expected_intent": "unknown"
 },
 {
  "message": "Who won the World Cup?",
  "expected_intent": "unknown"
 },
 {
  "message": "Tell me a funny joke",
  "expected_intent": "unknown"
 },
 {
  "message": "Can you write a poem about cats?",
  "expected_intent": "unknown"
 }
]
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/test_agent.py" <<'SUPPORTDESK_EOF'
import os
import tempfile
import unittest

from supportdesk.agent import Agent
from supportdesk.db import get_connection, init_db


class TestAgent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fd, cls.db = tempfile.mkstemp(suffix=".db")
        init_db(cls.db)
        cls.agent = Agent(cls.db)
        conn = get_connection(cls.db)
        cls.delivered = conn.execute(
            "SELECT o.id FROM orders o JOIN products p ON p.name = o.item_name "
            "WHERE o.status = 'delivered' AND p.price <= 50 LIMIT 2").fetchall()
        cls.delivered, cls.delivered2 = cls.delivered[0][0], cls.delivered[1][0]
        cls.o1005 = conn.execute("SELECT status FROM orders WHERE id = 'ORD-1005'").fetchone()[0]
        conn.close()

    @classmethod
    def tearDownClass(cls):
        os.close(cls.fd)
        os.remove(cls.db)

    def test_two_turn_order_status(self):
        first = self.agent.run("Where is my order?")
        self.assertIn("Which order", first["reply"])
        second = self.agent.run("It's ORD-1005", first["session_id"])
        self.assertIn(self.o1005, second["reply"])
        self.assertEqual(second["tool_calls"], ["get_order_status"])

    def test_refund_takes_two_tool_steps(self):
        res = self.agent.run(f"My {self.delivered} arrived broken, I want a refund")
        self.assertEqual(res["tool_calls"], ["get_order_status", "process_refund"])
        self.assertIn("refund #", res["reply"])

    def test_refund_continues_across_turns(self):
        a = self.agent.run("I want a refund please")
        b = self.agent.run(self.delivered2, a["session_id"])
        self.assertIn("process_refund", b["tool_calls"])

    def test_unknown_question(self):
        res = self.agent.run("Tell me a joke")
        self.assertEqual(res["tool_calls"], [])


if __name__ == "__main__":
    unittest.main()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/test_dispatcher.py" <<'SUPPORTDESK_EOF'
import json
import os
import tempfile
import unittest
from pathlib import Path

from supportdesk.db import init_db
from supportdesk.dispatcher import IntentDispatcher


class TestIntentDispatcher(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db_fd, cls.db_path = tempfile.mkstemp(suffix=".db")
        init_db(cls.db_path)
        cls.dispatcher = IntentDispatcher(cls.db_path)

    @classmethod
    def tearDownClass(cls):
        os.close(cls.db_fd)
        os.remove(cls.db_path)

    def test_order_status_dispatch(self):
        res = self.dispatcher.dispatch("Where is order ORD-1005?")
        self.assertEqual(res["intent"], "order_status")
        self.assertEqual(res["slots"]["order_id"], "ORD-1005")
        self.assertIn("ORD-1005", res["reply"])

    def test_refund_request_dispatch(self):
        res = self.dispatcher.dispatch("I want a refund for ORD-1010")
        self.assertEqual(res["intent"], "refund_request")

    def test_stock_check_dispatch(self):
        res = self.dispatcher.dispatch("Do you have Wireless Headphones in stock?")
        self.assertEqual(res["slots"].get("product"), "Wireless Headphones")

    def test_refund_policy_dispatch(self):
        res = self.dispatcher.dispatch("What is your refund policy?")
        self.assertIn("Unopened items", res["reply"])

    def test_unknown_fallback(self):
        self.assertEqual(self.dispatcher.dispatch("What is the capital of France?")["intent"], "unknown")

    def test_labelled_cases_accuracy(self):
        cases = json.loads((Path(__file__).parent / "cases.json").read_text())
        ok = sum(self.dispatcher.dispatch(c["message"])["intent"] == c["expected_intent"] for c in cases)
        self.assertGreaterEqual(ok / len(cases), 0.9)


if __name__ == "__main__":
    unittest.main()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/test_eval.py" <<'SUPPORTDESK_EOF'
import unittest

from supportdesk.evals.run_eval import run


class TestEval(unittest.TestCase):
    def test_quality_bar(self):
        summary, results = run()
        self.assertEqual(summary["cases"], 50)
        self.assertGreaterEqual(summary["task_success"], 0.9)
        self.assertEqual(summary["hallucination_rate"], 0)


if __name__ == "__main__":
    unittest.main()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/test_guard.py" <<'SUPPORTDESK_EOF'
import os
import tempfile
import unittest

from supportdesk.agent import Agent
from supportdesk.db import get_connection, init_db
from supportdesk.guard import CircuitBreaker, Guard, decide


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class TestGuard(unittest.TestCase):
    def setUp(self):
        self.fd, self.db = tempfile.mkstemp(suffix=".db")
        init_db(self.db)
        conn = get_connection(self.db)
        q = "SELECT o.id FROM orders o JOIN products p ON p.name = o.item_name WHERE o.status = 'delivered' AND p.price {} 50 ORDER BY o.id"
        self.cheap = [r[0] for r in conn.execute(q.format("<="))]
        self.dear = [r[0] for r in conn.execute(q.format(">"))]
        conn.close()
        self.agent = Agent(self.db, guard=Guard(self.db, CircuitBreaker(max_events=3, window_s=60, cooldown_s=30)))

    def tearDown(self):
        os.close(self.fd)
        os.remove(self.db)

    def refunds(self):
        conn = get_connection(self.db)
        n = conn.execute("SELECT COUNT(*) FROM refunds").fetchone()[0]
        conn.close()
        return n

    def test_small_refund_is_automatic(self):
        res = self.agent.run(f"refund {self.cheap[0]} it arrived damaged")
        self.assertIn("refund #", res["reply"])

    def test_large_refund_is_held_then_approved_once(self):
        res = self.agent.run(f"refund {self.dear[0]} it arrived damaged")
        self.assertIn("review", res["reply"])
        self.assertEqual(self.refunds(), 0)
        conn = get_connection(self.db)
        approval_id = conn.execute("SELECT id FROM approvals").fetchone()[0]
        conn.close()
        self.assertEqual(decide(self.db, self.agent.tools, approval_id, True)[0], 200)
        self.assertEqual(decide(self.db, self.agent.tools, approval_id, True)[0], 409)
        self.assertEqual(self.refunds(), 1)

    def test_partial_refund_amount(self):
        res = self.agent.run(f"please refund $20 on {self.dear[1]}, it was late")
        self.assertIn("$20.00", res["reply"])

    def test_breaker_blocks_a_refund_storm(self):
        replies = [self.agent.run(f"refund $5 on {oid} damaged")["reply"] for oid in self.dear[2:8]]
        self.assertEqual(sum("refund #" in r for r in replies), 4)  # max_events=3: the 4th trips the breaker
        self.assertIn("paused", replies[-1])

    def test_breaker_opens_and_recovers(self):
        clock = FakeClock()
        b = CircuitBreaker(max_events=2, window_s=60, cooldown_s=30, clock=clock)
        for _ in range(3):
            self.assertTrue(b.allow())
            b.record()
        self.assertEqual(b.state, "open")
        self.assertFalse(b.allow())
        clock.t = 31
        self.assertEqual(b.state, "half_open")
        self.assertTrue(b.allow())
        self.assertFalse(b.allow())  # only one trial
        b.record()
        self.assertEqual(b.state, "closed")


if __name__ == "__main__":
    unittest.main()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/test_resilience.py" <<'SUPPORTDESK_EOF'
import random
import unittest

from supportdesk.chaos import run
from supportdesk.resilience import RetryBudgetExceeded, retry


class TestRetry(unittest.TestCase):
    def test_recovers_from_transient_errors(self):
        calls = []

        def flaky():
            calls.append(1)
            if len(calls) < 3:
                raise ConnectionError("boom")
            return "ok"
        self.assertEqual(retry(flaky, attempts=4, sleep=lambda s: None, rng=random.Random(1)), "ok")
        self.assertEqual(len(calls), 3)

    def test_gives_up(self):
        def down():
            raise TimeoutError("down")
        with self.assertRaises(RetryBudgetExceeded) as ctx:
            retry(down, attempts=3, sleep=lambda s: None)
        self.assertEqual(ctx.exception.attempts, 3)

    def test_other_errors_are_not_retried(self):
        calls = []

        def bug():
            calls.append(1)
            raise ValueError("bug")
        with self.assertRaises(ValueError):
            retry(bug, sleep=lambda s: None)
        self.assertEqual(len(calls), 1)

    def test_chaos_no_duplicate_refunds(self):
        off, on = run(0.3, 1, 30), run(0.3, 5, 30)
        self.assertGreater(on["success_rate"], off["success_rate"])
        self.assertGreaterEqual(on["success_rate"], 0.9)
        self.assertEqual(on["duplicate_refunds"], 0)


if __name__ == "__main__":
    unittest.main()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/test_telemetry.py" <<'SUPPORTDESK_EOF'
import os
import tempfile
import unittest

from supportdesk import telemetry
from supportdesk.agent import Agent
from supportdesk.db import init_db


class TestTelemetry(unittest.TestCase):
    def setUp(self):
        self.fd, self.db = tempfile.mkstemp(suffix=".db")
        init_db(self.db)
        self.agent = Agent(self.db)

    def tearDown(self):
        os.close(self.fd)
        os.remove(self.db)

    def test_every_request_is_one_trace(self):
        outs = [self.agent.run(m) for m in ["Where is ORD-1005?", "Do you have Gaming Mouse in stock?", "hello"]]
        m = telemetry.metrics(self.db)
        self.assertEqual(m["interactions"], 3)
        self.assertEqual(m["tool_calls"], 2)
        t = telemetry.trace(self.db, outs[0]["trace_id"])
        self.assertEqual([s["kind"] for s in t["steps"]], ["model", "tool", "model"])
        self.assertGreater(t["tokens_in"], 0)
        self.assertGreater(m["cost_usd"], 0)


if __name__ == "__main__":
    unittest.main()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/tests/test_tools.py" <<'SUPPORTDESK_EOF'
import os
import tempfile
import unittest

from supportdesk.db import get_connection, init_db
from supportdesk.tools import ToolExecutionError, ToolValidationError, build_registry


class TestTools(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fd, cls.db = tempfile.mkstemp(suffix=".db")
        init_db(cls.db)
        cls.reg = build_registry(cls.db)
        conn = get_connection(cls.db)
        cls.shipped = conn.execute("SELECT id FROM orders WHERE status = 'delivered' LIMIT 1").fetchone()[0]
        cls.placed = conn.execute("SELECT id FROM orders WHERE status = 'placed' LIMIT 1").fetchone()[0]
        conn.close()

    @classmethod
    def tearDownClass(cls):
        os.close(cls.fd)
        os.remove(cls.db)

    def test_bad_arguments_name_the_field(self):
        cases = [({}, "order_id"), ({"order_id": 1005}, "order_id"), ({"order_id": "ORD-1"}, "order_id"),
                 ({"order_id": "ORD-1005", "extra": 1}, "extra")]
        for args, field in cases:
            with self.assertRaises(ToolValidationError) as ctx:
                self.reg.call("get_order_status", args)
            self.assertEqual(ctx.exception.field, field)

    def test_refund_rules(self):
        with self.assertRaises(ToolValidationError):
            self.reg.call("process_refund", {"order_id": self.shipped, "amount": -5, "reason": "late", "idempotency_key": "k-neg-1"})
        with self.assertRaises(ToolValidationError):
            self.reg.call("process_refund", {"order_id": self.shipped, "amount": 5, "reason": "bored", "idempotency_key": "k-enum-1"})
        with self.assertRaises(ToolExecutionError):
            self.reg.call("process_refund", {"order_id": self.placed, "amount": 5, "reason": "late", "idempotency_key": "k-placed"})

    def test_idempotent_refund(self):
        args = {"order_id": self.shipped, "amount": 10.0, "reason": "damaged", "idempotency_key": "test-idem-1"}
        first = self.reg.call("process_refund", args)
        again = self.reg.call("process_refund", args)
        self.assertFalse(first["duplicate"])
        self.assertTrue(again["duplicate"])
        self.assertEqual(first["refund_id"], again["refund_id"])
        conn = get_connection(self.db)
        n = conn.execute("SELECT COUNT(*) FROM refunds WHERE idempotency_key = 'test-idem-1'").fetchone()[0]
        conn.close()
        self.assertEqual(n, 1)

    def test_cannot_refund_more_than_the_price(self):
        conn = get_connection(self.db)
        oid, price = conn.execute("SELECT o.id, p.price FROM orders o JOIN products p ON p.name = o.item_name "
                                  "WHERE o.status = 'shipped' ORDER BY o.id DESC LIMIT 1").fetchone()
        conn.close()
        self.reg.call("process_refund", {"order_id": oid, "amount": price, "reason": "late", "idempotency_key": "full-1"})
        with self.assertRaises(ToolExecutionError):
            self.reg.call("process_refund", {"order_id": oid, "amount": 1, "reason": "late", "idempotency_key": "full-2"})

    def test_audit_log(self):
        conn = get_connection(self.db)
        before = conn.execute("SELECT COUNT(*) FROM tool_calls").fetchone()[0]
        self.reg.call("check_stock", {"product": "Gaming Mouse"})
        after = conn.execute("SELECT COUNT(*) FROM tool_calls").fetchone()[0]
        conn.close()
        self.assertEqual(after, before + 1)


if __name__ == "__main__":
    unittest.main()
SUPPORTDESK_EOF

export PYTHONPATH="$PROJECT_DIR${PYTHONPATH:+:$PYTHONPATH}"

say "Unit tests"
(cd "$PROJECT_DIR" && python3 -m unittest discover -s tests 2>&1 | tail -4)
(cd "$PROJECT_DIR" && python3 -m unittest discover -s tests >/dev/null 2>&1) || { echo "[ERROR] unit tests failed: cd supportdesk && python3 -m unittest discover -s tests"; exit 1; }

say "Starting SupportDesk on port $PORT"
mkdir -p "$PROJECT_DIR/.run"
(cd "$PROJECT_DIR" && python3 -c 'from supportdesk.db import init_db; init_db()')
python3 "$PROJECT_DIR/supportdesk/app.py" > "$PROJECT_DIR/.run/app.log" 2>&1 &
echo $! > "$PROJECT_DIR/.run/app.pid"
for _ in $(seq 1 40); do
  if python3 -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:$PORT/health', timeout=1)" 2>/dev/null; then break; fi
  sleep 0.5
done
python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$PORT/health', timeout=1)" 2>/dev/null || { echo "[ERROR] server did not start:"; tail -20 "$PROJECT_DIR/.run/app.log"; exit 1; }
echo "[INFO] server running (pid $(cat "$PROJECT_DIR/.run/app.pid"))"

cat > "$ROOT/verify.sh" <<'VERIFY_EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT/supportdesk"
cd "$PROJECT_DIR"
export PYTHONPATH="$PROJECT_DIR${PYTHONPATH:+:$PYTHONPATH}"
python3 -m supportdesk.checks
echo "PASS  Lesson 7 complete. Your completion code: SHOP4-EVAL-4X8B"
VERIFY_EOF
chmod +x "$ROOT/verify.sh"

say "Verify"
bash "$ROOT/verify.sh"

say "Demo"
(cd "$PROJECT_DIR" && python3 -m supportdesk.demo)

say "Done. SupportDesk is running on http://127.0.0.1:$PORT"
echo "Run bash verify.sh for your completion code, bash stop.sh when you are finished."
