#!/usr/bin/env bash
# ShopStream SupportDesk — Day 2: Instrument the Tool-Calling Interface
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

# ---- the code (12 files) ----
mkdir -p "$PROJECT_DIR/supportdesk"
mkdir -p "$PROJECT_DIR/tests"
cat > "$PROJECT_DIR/supportdesk/__init__.py" <<'SUPPORTDESK_EOF'
"""ShopStream SupportDesk Core Package"""
__version__ = "0.1.0"
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/app.py" <<'SUPPORTDESK_EOF'
"""SupportDesk HTTP API (standard library only).

GET  /health
POST /chat   {"message": "..."} -> {"intent", "slots", "reply", "latency_ms"}
GET  /tools                 tool names and argument schemas
POST /tools/NAME            run a tool with JSON arguments (400 bad arguments, 422 refused)
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from supportdesk.db import init_db
from supportdesk.dispatcher import IntentDispatcher
from supportdesk.tools import ToolExecutionError, ToolValidationError

PORT = int(os.environ.get("SUPPORTDESK_PORT", 8090))
dispatcher = None


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
    global dispatcher
    init_db()
    dispatcher = IntentDispatcher()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), SupportHandler)
    server.daemon_threads = True
    print(f"[INFO] Server starting on port {PORT}...", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    run_server()
SUPPORTDESK_EOF
cat > "$PROJECT_DIR/supportdesk/checks.py" <<'SUPPORTDESK_EOF'
"""Day 2 checks used by verify.sh. Exit 1 on the first failure."""
import sys
import time

from supportdesk.client import get, post
from supportdesk.db import get_connection


def fail(msg):
    print(f"[FAIL] {msg}")
    sys.exit(1)


if get("/health")[0] != 200:
    fail("server is not running: run start.sh first")
status, body, _ = post("/tools/get_order_status", {"order_id": 1005})
if status != 400 or body.get("field") != "order_id":
    fail(f"a bad argument should give 400 naming the field, got {status} {body}")
print(f"[VERIFY] bad argument rejected: {body['error']}")
conn = get_connection()
order = conn.execute("SELECT id FROM orders WHERE status = 'delivered' ORDER BY id DESC LIMIT 1").fetchone()[0]
conn.close()
key = f"verify-{int(time.time() * 1000)}"
args = {"order_id": order, "amount": 1.0, "reason": "late", "idempotency_key": key}
a, b = post("/tools/process_refund", args)[1], post("/tools/process_refund", args)[1]
conn = get_connection()
rows = conn.execute("SELECT COUNT(*) FROM refunds WHERE idempotency_key = ?", (key,)).fetchone()[0]
conn.close()
if rows != 1 or not b["result"]["duplicate"]:
    fail(f"the same refund twice must create exactly one row (rows={rows})")
print(f"[VERIFY] refund sent twice -> 1 row, second call marked duplicate")
s, chat, _ = post("/chat", {"message": "where is order ORD-1005"})
if s != 200 or "ORD-1005" not in chat.get("reply", ""):
    fail("/chat no longer answers order status")
print("[VERIFY] /chat still answers through the tool layer")
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
"""Day 2 demo: 40 tool calls through the HTTP API, 10 of them deliberately bad."""
import time

from supportdesk.client import get, pct, post
from supportdesk.db import get_connection

conn = get_connection()
delivered = [r[0] for r in conn.execute("SELECT id FROM orders WHERE status = 'delivered' ORDER BY id LIMIT 5")]
placed = conn.execute("SELECT id FROM orders WHERE status = 'placed' LIMIT 1").fetchone()[0]
conn.close()
run = str(int(time.time()))

calls = [("get_order_status", {"order_id": f"ORD-{1001 + i * 17}"}) for i in range(15)]
calls += [("check_stock", {"product": p}) for p in ["Gaming Mouse", "4K Monitor", "USB Hub", "Desk Pad", "Smart Watch",
                                                   "Laptop Stand", "HD Webcam", "Microphone Arm", "LED Desk Lamp", "Vertical Mouse"]]
calls += [("process_refund", {"order_id": o, "amount": 5.0, "reason": "damaged", "idempotency_key": f"demo-{run}-{o}"}) for o in delivered[:3]]
calls += [("process_refund", {"order_id": o, "amount": 5.0, "reason": "damaged", "idempotency_key": f"demo-{run}-{o}"}) for o in delivered[:2]]  # retries
calls += [
    ("get_order_status", {}), ("get_order_status", {"order_id": 1005}), ("get_order_status", {"order_id": "1005"}),
    ("get_order_status", {"order_id": "ORD-1005", "verbose": True}), ("check_stock", {"product": "x" * 200}),
    ("process_refund", {"order_id": delivered[0], "amount": -5, "reason": "late", "idempotency_key": f"bad-{run}-1"}),
    ("process_refund", {"order_id": delivered[0], "amount": 5, "reason": "bored", "idempotency_key": f"bad-{run}-2"}),
    ("process_refund", {"order_id": delivered[0], "amount": 5, "reason": "late"}),
    ("process_refund", {"order_id": placed, "amount": 5, "reason": "late", "idempotency_key": f"bad-{run}-3"}),
    ("delete_all_orders", {}),
]
codes, lat, dup = {}, [], 0
for name, args in calls:
    t = time.perf_counter()
    status, body, _ = post(f"/tools/{name}", args)
    lat.append((time.perf_counter() - t) * 1000)
    codes[status] = codes.get(status, 0) + 1
    dup += status == 200 and body["result"].get("duplicate", False)
    if status != 200:
        print(f"  {status}  {name:<18} {body['error']}")
conn = get_connection()
refunds = conn.execute("SELECT COUNT(*) FROM refunds WHERE idempotency_key LIKE ?", (f"demo-{run}-%",)).fetchone()[0]
audit = conn.execute("SELECT COUNT(*), SUM(ok) FROM tool_calls").fetchone()
conn.close()
print("==================================================")
print(f"Tool calls sent            : {len(calls)}")
print(f"Accepted (200)             : {codes.get(200, 0)}")
print(f"Rejected by schema (400)   : {codes.get(400, 0)}")
print(f"Refused by business rule (422): {codes.get(422, 0)}")
print(f"Refunds created            : {refunds} (5 refund calls, 2 were retries)")
print(f"Duplicate refunds prevented: {dup}")
print(f"Audit rows (ok / total)    : {audit[1]} / {audit[0]}")
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
echo "PASS  Lesson 2 complete. Your completion code: SHOP4-TOOLS-8M2C"
VERIFY_EOF
chmod +x "$ROOT/verify.sh"

say "Verify"
bash "$ROOT/verify.sh"

say "Demo"
(cd "$PROJECT_DIR" && python3 -m supportdesk.demo)

say "Done. SupportDesk is running on http://127.0.0.1:$PORT"
echo "Run bash verify.sh for your completion code, bash stop.sh when you are finished."
