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
