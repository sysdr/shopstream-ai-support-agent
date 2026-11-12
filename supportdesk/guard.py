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
