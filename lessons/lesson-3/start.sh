#!/usr/bin/env bash
# ShopStream SupportDesk — Day 3: Integrate the Agent Loop
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

# ---- the code (15 files) ----
mkdir -p "$PROJECT_DIR/supportdesk"
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
import time
import uuid

from supportdesk.db import get_connection
from supportdesk.model import get_model
from supportdesk.tools import ToolExecutionError, ToolValidationError, build_registry

MAX_STEPS = 5


class Agent:
    def __init__(self, db_path=None, model=None):
        self.db_path = db_path
        self.tools = build_registry(db_path)
        self.model = model or get_model(db_path)

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
        try:
            return self.tools.call(name, args)
        except (ToolValidationError, ToolExecutionError) as e:
            return {"error": str(e)}

    def run(self, message, session_id=None):
        start = time.perf_counter()
        session_id = session_id or uuid.uuid4().hex[:12]
        history = self.load(session_id)
        new = [{"role": "user", "content": message, "session_id": session_id}]
        history += new
        steps, tool_calls, reply = 0, [], None
        while steps < MAX_STEPS:
            steps += 1
            d = self.model.decide(history, self.tools.specs())
            if d["type"] == "reply":
                reply = {"role": "assistant", "content": d["text"], "pending": d.get("pending")}
                break
            result = self.run_tool(d["name"], d["args"])
            tool_calls.append(d["name"])
            msg = {"role": "tool", "name": d["name"], "args": d["args"], "result": result, "id": d.get("id", f"t{steps}")}
            history.append(msg)
            new.append(msg)
        if reply is None:
            reply = {"role": "assistant", "content": "Sorry, I couldn't finish that. A human agent will follow up."}
        new.append(reply)
        self.save(session_id, new)
        return {"session_id": session_id, "reply": reply["content"], "steps": steps, "tool_calls": tool_calls,
                "model": self.model.name, "latency_ms": round((time.perf_counter() - start) * 1000, 2)}
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/app.py" <<'SUPPORTDESK_EOF'
"""SupportDesk HTTP API (standard library only).

GET  /health
POST /chat   {"message": "..."} -> {"intent", "slots", "reply", "latency_ms"}
GET  /tools                 tool names and argument schemas
POST /tools/NAME            run a tool with JSON arguments (400 bad arguments, 422 refused)
POST /agent  {"message": "...", "session_id": optional} -> agent reply, steps, tool calls
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from supportdesk.agent import Agent
from supportdesk.db import init_db
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
            return self.send_json(200, agent.run(str(data["message"]), data.get("session_id")))
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
cat > "$PROJECT_DIR/supportdesk/checks.py" <<'SUPPORTDESK_EOF'
"""Day 3 checks used by verify.sh."""
import sys

from supportdesk.client import get, post
from supportdesk.db import get_connection


def fail(msg):
    print(f"[FAIL] {msg}")
    sys.exit(1)


if get("/health")[0] != 200:
    fail("server is not running: run start.sh first")
conn = get_connection()
real = conn.execute("SELECT status FROM orders WHERE id = 'ORD-1012'").fetchone()[0]
conn.close()
_, a, _ = post("/agent", {"message": "Where is my order?"})
if "Which order" not in a["reply"]:
    fail(f"the agent should ask which order, said: {a['reply']}")
_, b, _ = post("/agent", {"message": "It's ORD-1012", "session_id": a["session_id"]})
if real not in b["reply"] or b["tool_calls"] != ["get_order_status"]:
    fail(f"second turn should look up ORD-1012 ({real}), got {b}")
print(f"[VERIFY] two-turn conversation remembered the question: {b['reply']}")
_, c, _ = post("/agent", {"message": "Tell me a joke"})
if c["tool_calls"]:
    fail("an off-topic question must not call tools")
print("[VERIFY] off-topic question answered without tools")
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
"""Day 3 demo: ten conversations through the agent loop, some over two turns."""
import time

from supportdesk.client import pct, post
from supportdesk.db import get_connection

conn = get_connection()
cheap = conn.execute("SELECT o.id FROM orders o JOIN products p ON p.name = o.item_name WHERE o.status IN ('shipped','delivered') ORDER BY p.price, o.id LIMIT 1").fetchone()[0]
conn.close()
conversations = [
    ["Where is ORD-1005?"],
    ["Where is my order?", "It's ORD-1012"],
    ["Has ORD-1050 shipped yet?"],
    [f"My {cheap} arrived broken, I want a refund"],
    ["I want a refund please", f"{cheap}, it came late"],
    ["Do you have Gaming Mouse in stock?"],
    ["What is your refund policy?"],
    ["Refund ORD-1003 please"],
    ["Tell me a joke"],
    ["Is 4K Monitor available?"],
]
lat, steps, resolved = [], [], 0
for turns in conversations:
    session = None
    for text in turns:
        t = time.perf_counter()
        _, out, _ = post("/agent", {"message": text, "session_id": session})
        lat.append((time.perf_counter() - t) * 1000)
        session = out["session_id"]
        steps.append(out["steps"])
        print(f"  [{session}] {text!r:<44} -> tools {out['tool_calls'] or '-'}")
    print(f"      agent: {out['reply']}")
    resolved += "Which order" not in out["reply"] and "couldn't" not in out["reply"]
print("==================================================")
print(f"Conversations              : {len(conversations)} ({sum(len(c) for c in conversations)} turns)")
print(f"Resolved                   : {resolved}/{len(conversations)}")
print(f"Model steps per turn (avg) : {sum(steps) / len(steps):.2f} (max {max(steps)})")
print(f"Latency p50 / p99          : {pct(lat, .5):.2f} / {pct(lat, .99):.2f} ms")
print("==================================================")
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
                return {"type": "tool", "name": "process_refund",
                        "args": {"order_id": order_id, "amount": o["price"], "reason": reason,
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
        cls.delivered, cls.delivered2 = [r[0] for r in conn.execute("SELECT id FROM orders WHERE status = 'delivered' LIMIT 2")]
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
echo "PASS  Lesson 3 complete. Your completion code: SHOP4-LOOP-5Q9T"
VERIFY_EOF
chmod +x "$ROOT/verify.sh"

say "Verify"
bash "$ROOT/verify.sh"

say "Demo"
(cd "$PROJECT_DIR" && python3 -m supportdesk.demo)

say "Done. SupportDesk is running on http://127.0.0.1:$PORT"
echo "Run bash verify.sh for your completion code, bash stop.sh when you are finished."
