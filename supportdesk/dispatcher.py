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
