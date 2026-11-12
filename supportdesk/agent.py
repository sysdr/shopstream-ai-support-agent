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
