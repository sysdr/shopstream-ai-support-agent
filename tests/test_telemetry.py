import os
import tempfile
import unittest

from supportdesk import telemetry
from supportdesk.agent import Agent
from supportdesk.db import init_db


class TestTelemetry(unittest.TestCase):
    def setUp(self):
        self.fd, self.db = tempfile.mkstemp(suffix=".db")
        init_db(self.db)
        self.agent = Agent(self.db)

    def tearDown(self):
        os.close(self.fd)
        os.remove(self.db)

    def test_every_request_is_one_trace(self):
        outs = [self.agent.run(m) for m in ["Where is ORD-1005?", "Do you have Gaming Mouse in stock?", "hello"]]
        m = telemetry.metrics(self.db)
        self.assertEqual(m["interactions"], 3)
        self.assertEqual(m["tool_calls"], 2)
        t = telemetry.trace(self.db, outs[0]["trace_id"])
        self.assertEqual([s["kind"] for s in t["steps"]], ["model", "tool", "model"])
        self.assertGreater(t["tokens_in"], 0)
        self.assertGreater(m["cost_usd"], 0)


if __name__ == "__main__":
    unittest.main()
