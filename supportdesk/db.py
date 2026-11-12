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
