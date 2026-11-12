#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT/supportdesk"
cd "$ROOT"

echo "[INFO] Starting setup for ShopStream SupportDesk Day 1..."

# 1. Check Python version >= 3.10
echo "[INFO] Checking Python version..."
if ! command -v python3 &> /dev/null; then
    echo "[ERROR] python3 could not be found. Please install Python 3.10 or higher."
    exit 1
fi

PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

if [ "$MAJOR" -lt 3 ] || { [ "$MAJOR" -eq 3 ] && [ "$MINOR" -lt 10 ]; }; then
    echo "[ERROR] Python version 3.10+ is required. Found version $PYTHON_VERSION."
    echo "[HINT] Install Python 3.10+ using your package manager (e.g., sudo apt install python3)."
    exit 1
fi
echo "[INFO] Python $PYTHON_VERSION detected."

# 2. Scaffolding directory structure
mkdir -p "$PROJECT_DIR/supportdesk"
mkdir -p "$PROJECT_DIR/tests"
mkdir -p "$PROJECT_DIR/.run"

# 3. Writing source files via quoted heredocs

# supportdesk/__init__.py
cat << 'PYEOF' > "$PROJECT_DIR/supportdesk/__init__.py"
"""ShopStream SupportDesk Core Package"""
__version__ = "0.1.0"
PYEOF

# supportdesk/db.py
cat << 'PYEOF' > "$PROJECT_DIR/supportdesk/db.py"
import sqlite3
import random
import os
from pathlib import Path

DB_PATH = Path(__file__).parent.parent / "shop.db"

def get_connection(db_path=None):
    target_path = db_path or DB_PATH
    conn = sqlite3.connect(target_path)
    conn.row_factory = sqlite3.Row
    return conn

def init_db(db_path=None):
    target_path = db_path or DB_PATH
    conn = get_connection(target_path)
    cursor = conn.cursor()

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS customers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        email TEXT NOT NULL
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        stock INTEGER NOT NULL,
        price REAL NOT NULL
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS orders (
        id TEXT PRIMARY KEY,
        customer_id INTEGER NOT NULL,
        status TEXT NOT NULL,
        item_name TEXT NOT NULL,
        created_at TEXT NOT NULL,
        shipped_at TEXT,
        FOREIGN KEY(customer_id) REFERENCES customers(id)
    )
    """)

    cursor.execute("""
    CREATE TABLE IF NOT EXISTS refund_policy (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        condition TEXT NOT NULL,
        max_days INTEGER NOT NULL,
        policy_text TEXT NOT NULL
    )
    """)

    conn.commit()

    # Seed if empty
    cursor.execute("SELECT COUNT(*) FROM customers")
    if cursor.fetchone()[0] == 0:
        seed_db(conn)

    conn.close()

def seed_db(conn):
    rng = random.Random(42)
    cursor = conn.cursor()

    # Customers
    first_names = ["Alex", "Jordan", "Taylor", "Morgan", "Casey", "Riley", "Sam", "Dakota", "Reese", "Quinn"]
    last_names = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Martinez"]
    
    customers = []
    for i in range(1, 51):
        fn = rng.choice(first_names)
        ln = rng.choice(last_names)
        email = f"{fn.lower()}.{ln.lower()}{i}@example.com"
        customers.append((f"{fn} {ln}", email))
    
    cursor.executemany("INSERT INTO customers (name, email) VALUES (?, ?)", customers)

    # Products
    product_names = [
        "Wireless Headphones", "Ergonomic Desk Chair", "Mechanical Keyboard", 
        "USB-C Fast Charger", "Noise Canceling Earbuds", "Gaming Mouse", 
        "4K Monitor", "Laptop Stand", "Smart Watch", "Bluetooth Speaker",
        "HD Webcam", "Portable SSD 1TB", "Desk Pad", "Microphone Arm",
        "LED Desk Lamp", "Vertical Mouse", "Wireless Charger", "USB Hub",
        "Cable Management Kit", "Screen Cleaner Kit"
    ]
    
    products = []
    for name in product_names:
        stock = rng.randint(0, 150)
        price = round(rng.uniform(15.0, 299.0), 2)
        products.append((name, stock, price))
    
    cursor.executemany("INSERT INTO products (name, stock, price) VALUES (?, ?, ?)", products)

    # Orders
    statuses = ["placed", "shipped", "delivered", "cancelled"]
    orders = []
    for order_num in range(1001, 1301):
        order_id = f"ORD-{order_num}"
        customer_id = rng.randint(1, 50)
        status = rng.choice(statuses)
        item_name = rng.choice(product_names)
        created_day = rng.randint(1, 28)
        created_at = f"2024-01-{created_day:02d}"
        shipped_at = f"2024-01-{(created_day+2):02d}" if status in ["shipped", "delivered"] else None
        orders.append((order_id, customer_id, status, item_name, created_at, shipped_at))

    cursor.executemany("INSERT INTO orders (id, customer_id, status, item_name, created_at, shipped_at) VALUES (?, ?, ?, ?, ?, ?)", orders)

    # Refund Policies
    policies = [
        ("unopened", 30, "Unopened items in original packaging can be returned within 30 days for a full refund."),
        ("opened", 14, "Opened items in working condition can be returned within 14 days subject to a 15% restocking fee."),
        ("defective", 90, "Defective products are covered under full warranty and eligible for free replacement or full refund within 90 days.")
    ]
    cursor.executemany("INSERT INTO refund_policy (condition, max_days, policy_text) VALUES (?, ?, ?)", policies)

    conn.commit()
PYEOF

# supportdesk/dispatcher.py
cat << 'PYEOF' > "$PROJECT_DIR/supportdesk/dispatcher.py"
import re
import time
from supportdesk.db import get_connection

ORDER_ID_PATTERN = re.compile(r"\b(ORD-\d{4})\b", re.IGNORECASE)
REFUND_KEYWORDS = re.compile(r"\b(refund|return|money back|cancel)\b", re.IGNORECASE)
STOCK_KEYWORDS = re.compile(r"\b(stock|inventory|available|in stock|have)\b", re.IGNORECASE)
POLICY_KEYWORDS = re.compile(r"\b(policy|rule|rules|returns|refunds)\b", re.IGNORECASE)

class IntentDispatcher:
    def __init__(self, db_path=None):
        self.db_path = db_path

    def dispatch(self, message: str) -> dict:
        start_time = time.perf_counter()
        normalized_msg = message.strip()
        
        intent = "unknown"
        slots = {}
        reply = "I am sorry, I could not understand your request. Could you please provide your order ID (e.g., ORD-1042) or product name?"

        order_match = ORDER_ID_PATTERN.search(normalized_msg)
        
        if order_match:
            order_id = order_match.group(1).upper()
            slots["order_id"] = order_id
            
            if REFUND_KEYWORDS.search(normalized_msg):
                intent = "refund_request"
                reply = self._handle_refund_request(order_id)
            else:
                intent = "order_status"
                reply = self._handle_order_status(order_id)
        elif STOCK_KEYWORDS.search(normalized_msg):
            intent = "stock_check"
            product_name = self._extract_product_name(normalized_msg)
            if product_name:
                slots["product"] = product_name
                reply = self._handle_stock_check(product_name)
            else:
                reply = "Please specify a valid product name to check inventory."
        elif POLICY_KEYWORDS.search(normalized_msg):
            intent = "refund_policy"
            reply = self._handle_refund_policy()

        latency_ms = round((time.perf_counter() - start_time) * 1000, 2)
        
        return {
            "intent": intent,
            "slots": slots,
            "reply": reply,
            "latency_ms": latency_ms
        }

    def _handle_order_status(self, order_id: str) -> str:
        conn = get_connection(self.db_path)
        cursor = conn.cursor()
        cursor.execute("SELECT id, status, item_name, created_at FROM orders WHERE id = ?", (order_id,))
        row = cursor.fetchone()
        conn.close()

        if row:
            return f"Order {row['id']} containing '{row['item_name']}' is currently {row['status']} (placed on {row['created_at']})."
        return f"Order {order_id} was not found in our system."

    def _handle_refund_request(self, order_id: str) -> str:
        conn = get_connection(self.db_path)
        cursor = conn.cursor()
        cursor.execute("SELECT id, status, item_name FROM orders WHERE id = ?", (order_id,))
        row = cursor.fetchone()
        conn.close()

        if not row:
            return f"Order {order_id} was not found. Refund request cannot be processed."

        if row["status"] in ["delivered", "shipped"]:
            return f"Refund request initialized for order {row['id']} ('{row['item_name']}'). Please return the item within 30 days of delivery."
        elif row["status"] == "placed":
            return f"Order {row['id']} has not shipped yet. You can cancel it directly for a full refund."
        else:
            return f"Order {row['id']} is currently '{row['status']}' and is not eligible for return."

    def _extract_product_name(self, text: str) -> str | None:
        conn = get_connection(self.db_path)
        cursor = conn.cursor()
        cursor.execute("SELECT name FROM products")
        products = [row["name"] for row in cursor.fetchall()]
        conn.close()

        for prod in products:
            if prod.lower() in text.lower():
                return prod
        return None

    def _handle_stock_check(self, product_name: str) -> str:
        conn = get_connection(self.db_path)
        cursor = conn.cursor()
        cursor.execute("SELECT name, stock FROM products WHERE name = ?", (product_name,))
        row = cursor.fetchone()
        conn.close()

        if row:
            stock = row["stock"]
            if stock > 0:
                return f"Product '{row['name']}' is in stock ({stock} units available)."
            return f"Product '{row['name']}' is currently out of stock."
        return f"Product '{product_name}' was not found in our catalog."

    def _handle_refund_policy(self) -> str:
        conn = get_connection(self.db_path)
        cursor = conn.cursor()
        cursor.execute("SELECT policy_text FROM refund_policy WHERE condition = 'unopened'")
        row = cursor.fetchone()
        conn.close()

        if row:
            return row["policy_text"]
        return "Standard policy: Returns accepted within 30 days of purchase with receipt."
PYEOF

# supportdesk/app.py
cat << 'PYEOF' > "$PROJECT_DIR/supportdesk/app.py"
import os
import json
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from supportdesk.db import init_db
from supportdesk.dispatcher import IntentDispatcher

PORT = int(os.environ.get("SUPPORTDESK_PORT", 8090))
dispatcher = None

class SupportHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok"}).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/chat":
            content_length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(content_length).decode("utf-8")
            
            try:
                data = json.loads(body)
                message = data.get("message", "")
                response = dispatcher.dispatch(message)
                
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(response).encode("utf-8"))
            except Exception as e:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Silence default HTTP server logging in stdout
        return

def run_server():
    global dispatcher
    init_db()
    dispatcher = IntentDispatcher()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), SupportHandler)
    print(f"[INFO] Server starting on port {PORT}...")
    server.serve_forever()

if __name__ == "__main__":
    run_server()
PYEOF

# tests/__init__.py
cat << 'PYEOF' > "$PROJECT_DIR/tests/__init__.py"
PYEOF

# tests/cases.json
cat << 'PYEOF' > "$PROJECT_DIR/tests/cases.json"
[
  {"message": "Where is my order ORD-1005?", "expected_intent": "order_status"},
  {"message": "Can you tell me the status of order ORD-1012?", "expected_intent": "order_status"},
  {"message": "Track order ORD-1045 please", "expected_intent": "order_status"},
  {"message": "I need an update on ORD-1100", "expected_intent": "order_status"},
  {"message": "What is going on with order ORD-1200?", "expected_intent": "order_status"},
  {"message": "Has ORD-1050 shipped yet?", "expected_intent": "order_status"},
  {"message": "Check status for ORD-1080", "expected_intent": "order_status"},
  {"message": "Where is ORD-1001?", "expected_intent": "order_status"},
  {"message": "Status of ORD-1299", "expected_intent": "order_status"},
  {"message": "Please locate ORD-1150", "expected_intent": "order_status"},
  {"message": "I want to request a refund for order ORD-1020", "expected_intent": "refund_request"},
  {"message": "How do I return item from ORD-1033?", "expected_intent": "refund_request"},
  {"message": "Can I get my money back for ORD-1077?", "expected_intent": "refund_request"},
  {"message": "I need a refund on ORD-1120", "expected_intent": "refund_request"},
  {"message": "Process return for ORD-1210", "expected_intent": "refund_request"},
  {"message": "What is your refund policy?", "expected_intent": "refund_policy"},
  {"message": "What are the return rules?", "expected_intent": "refund_policy"},
  {"message": "Tell me about the return policy", "expected_intent": "refund_policy"},
  {"message": "Do you have Wireless Headphones in stock?", "expected_intent": "stock_check"},
  {"message": "Is Mechanical Keyboard available?", "expected_intent": "stock_check"},
  {"message": "Check inventory for USB-C Fast Charger", "expected_intent": "stock_check"},
  {"message": "Do you have Noise Canceling Earbuds in stock?", "expected_intent": "stock_check"},
  {"message": "Is Ergonomic Desk Chair available?", "expected_intent": "stock_check"},
  {"message": "How many Wireless Headphones do you have left?", "expected_intent": "stock_check"},
  {"message": "Stock status for Mechanical Keyboard", "expected_intent": "stock_check"},
  {"message": "Do you have stock for Gaming Mouse?", "expected_intent": "stock_check"},
  {"message": "What is the weather in Seattle?", "expected_intent": "unknown"},
  {"message": "Who won the World Cup?", "expected_intent": "unknown"},
  {"message": "Tell me a funny joke", "expected_intent": "unknown"},
  {"message": "Can you write a poem about cats?", "expected_intent": "unknown"}
]
PYEOF

# tests/test_dispatcher.py
cat << 'PYEOF' > "$PROJECT_DIR/tests/test_dispatcher.py"
import unittest
import tempfile
import os
import json
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
        if os.path.exists(cls.db_path):
            os.remove(cls.db_path)

    def test_order_status_dispatch(self):
        res = self.dispatcher.dispatch("Where is order ORD-1005?")
        self.assertEqual(res["intent"], "order_status")
        self.assertEqual(res["slots"].get("order_id"), "ORD-1005")
        self.assertIn("ORD-1005", res["reply"])

    def test_refund_request_dispatch(self):
        res = self.dispatcher.dispatch("I want a refund for ORD-1010")
        self.assertEqual(res["intent"], "refund_request")
        self.assertEqual(res["slots"].get("order_id"), "ORD-1010")

    def test_stock_check_dispatch(self):
        res = self.dispatcher.dispatch("Do you have Wireless Headphones in stock?")
        self.assertEqual(res["intent"], "stock_check")
        self.assertEqual(res["slots"].get("product"), "Wireless Headphones")

    def test_refund_policy_dispatch(self):
        res = self.dispatcher.dispatch("What is your refund policy?")
        self.assertEqual(res["intent"], "refund_policy")
        self.assertIn("Unopened items", res["reply"])

    def test_unknown_fallback(self):
        res = self.dispatcher.dispatch("What is the capital of France?")
        self.assertEqual(res["intent"], "unknown")
        self.assertIn("could not understand", res["reply"])

if __name__ == "__main__":
    unittest.main()
PYEOF

# 4. Run unit tests
echo "[INFO] Running unit tests..."
export PYTHONPATH="$PROJECT_DIR${PYTHONPATH:+:$PYTHONPATH}"
python3 -m unittest discover -s "$PROJECT_DIR/tests"

# Initialize DB explicitly
python3 -c "import sys; sys.path.insert(0, '$PROJECT_DIR'); from supportdesk.db import init_db; init_db()"
echo "[INFO] Database seeded with 50 customers and 300 orders."

# 5. Start background server idempotently
PORT="${SUPPORTDESK_PORT:-8090}"
PID_FILE="$PROJECT_DIR/.run/app.pid"
LOG_FILE="$PROJECT_DIR/.run/app.log"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "[INFO] Server is already running on PID $(cat "$PID_FILE")."
else
    echo "[INFO] Starting HTTP server on port $PORT..."
    python3 "$PROJECT_DIR/supportdesk/app.py" > "$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$PID_FILE"
    echo "[INFO] Server running with PID $SERVER_PID."
fi

# Wait for health check (max 20 seconds)
HEALTH_OK=false
for i in {1..20}; do
    if curl -s "http://127.0.0.1:$PORT/health" | grep -q '"ok"'; then
        HEALTH_OK=true
        break
    fi
    sleep 1
done

if [ "$HEALTH_OK" = false ]; then
    echo "[ERROR] Server failed to pass health check on port $PORT within 20s."
    cat "$LOG_FILE"
    exit 1
fi

# 6. Write verify.sh script before demo execution
cat << 'PYEOF' > "$ROOT/verify.sh"
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$ROOT/supportdesk"
cd "$ROOT"
PORT="${SUPPORTDESK_PORT:-8090}"

echo "[VERIFY] Checking health endpoint..."
HEALTH_RES=$(curl -s "http://127.0.0.1:$PORT/health" || true)
if [[ "$HEALTH_RES" != *'"ok"'* ]]; then
    echo "[FAIL] Health endpoint returned unexpected response: $HEALTH_RES"
    exit 1
fi
echo "[VERIFY] Checking health endpoint... OK"

echo "[VERIFY] Testing canonical query ORD-1005..."
STATUS_RES=$(curl -s -X POST "http://127.0.0.1:$PORT/chat" \
  -H "Content-Type: application/json" \
  -d '{"message": "where is order ORD-1005"}' || true)

if [[ "$STATUS_RES" != *"ORD-1005"* ]] || [[ "$STATUS_RES" != *"order_status"* ]]; then
    echo "[FAIL] Failed canonical order query lookup. Response: $STATUS_RES"
    exit 1
fi
echo "[VERIFY] Testing canonical query ORD-1005... OK"

echo "[VERIFY] Evaluating intent benchmark dataset (30 samples)..."
export PYTHONPATH="$PROJECT_DIR${PYTHONPATH:+:$PYTHONPATH}"
python3 - "$PORT" << 'PYCHECK'
import json
import urllib.request
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8090
cases_file = "supportdesk/tests/cases.json"

with open(cases_file, "r") as f:
    cases = json.load(f)

correct = 0
total = len(cases)

for case in cases:
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/chat",
        data=json.dumps({"message": case["message"]}).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("intent") == case["expected_intent"]:
                correct += 1
    except Exception as e:
        pass

accuracy = (correct / total) * 100
print(f"[VERIFY] Benchmark Accuracy: {accuracy:.2f}% (Threshold: 90.00%)")

if accuracy < 90.0:
    print("[FAIL] Accuracy benchmark below 90.00% threshold.")
    sys.exit(1)

PYCHECK

echo "PASS  Lesson 1 complete. Your completion code: SHOP4-DISPATCH-3K7R"
PYEOF

chmod +x "$ROOT/verify.sh"

# Run verify script
"$ROOT/verify.sh"

# 7. Run Demo & print latency/accuracy benchmark metrics
python3 - << 'PYDEMO'
import json
import urllib.request
import time
import os

PORT = int(os.environ.get("SUPPORTDESK_PORT", 8090))
cases_file = "supportdesk/tests/cases.json"

with open(cases_file, "r") as f:
    cases = json.load(f)

latencies = []
correct = 0
unknown_count = 0
total = len(cases)

for case in cases:
    t0 = time.perf_counter()
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/chat",
        data=json.dumps({"message": case["message"]}).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        elapsed = (time.perf_counter() - t0) * 1000
        latencies.append(elapsed)
        
        if data.get("intent") == case["expected_intent"]:
            correct += 1
        if data.get("intent") == "unknown":
            unknown_count += 1

latencies.sort()
p50 = latencies[int(total * 0.50)]
p99 = latencies[min(int(total * 0.99), total - 1)]

print("==================================================")
print("              DAY 1 BENCHMARK DEMO                ")
print("==================================================")
print(f"Total Test Cases Processed : {total}")
print(f"Intent Matching Accuracy   : {(correct/total)*100:.2f}%")
print(f"Unknown Intent Rate        : {(unknown_count/total)*100:.2f}%")
print(f"Latency p50                : {p50:.2f} ms")
print(f"Latency p99                : {p99:.2f} ms")
print("==================================================")
PYDEMO