import os
import tempfile
import unittest

from supportdesk.agent import Agent
from supportdesk.db import get_connection, init_db


class TestAgent(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fd, cls.db = tempfile.mkstemp(suffix=".db")
        init_db(cls.db)
        cls.agent = Agent(cls.db)
        conn = get_connection(cls.db)
        cls.delivered = conn.execute(
            "SELECT o.id FROM orders o JOIN products p ON p.name = o.item_name "
            "WHERE o.status = 'delivered' AND p.price <= 50 LIMIT 2").fetchall()
        cls.delivered, cls.delivered2 = cls.delivered[0][0], cls.delivered[1][0]
        cls.o1005 = conn.execute("SELECT status FROM orders WHERE id = 'ORD-1005'").fetchone()[0]
        conn.close()

    @classmethod
    def tearDownClass(cls):
        os.close(cls.fd)
        os.remove(cls.db)

    def test_two_turn_order_status(self):
        first = self.agent.run("Where is my order?")
        self.assertIn("Which order", first["reply"])
        second = self.agent.run("It's ORD-1005", first["session_id"])
        self.assertIn(self.o1005, second["reply"])
        self.assertEqual(second["tool_calls"], ["get_order_status"])

    def test_refund_takes_two_tool_steps(self):
        res = self.agent.run(f"My {self.delivered} arrived broken, I want a refund")
        self.assertEqual(res["tool_calls"], ["get_order_status", "process_refund"])
        self.assertIn("refund #", res["reply"])

    def test_refund_continues_across_turns(self):
        a = self.agent.run("I want a refund please")
        b = self.agent.run(self.delivered2, a["session_id"])
        self.assertIn("process_refund", b["tool_calls"])

    def test_unknown_question(self):
        res = self.agent.run("Tell me a joke")
        self.assertEqual(res["tool_calls"], [])


if __name__ == "__main__":
    unittest.main()
