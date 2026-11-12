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
