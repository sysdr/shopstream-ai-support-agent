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
