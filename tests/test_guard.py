import os
import tempfile
import unittest

from supportdesk.agent import Agent
from supportdesk.db import get_connection, init_db
from supportdesk.guard import CircuitBreaker, Guard, decide


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t


class TestGuard(unittest.TestCase):
    def setUp(self):
        self.fd, self.db = tempfile.mkstemp(suffix=".db")
        init_db(self.db)
        conn = get_connection(self.db)
        q = "SELECT o.id FROM orders o JOIN products p ON p.name = o.item_name WHERE o.status = 'delivered' AND p.price {} 50 ORDER BY o.id"
        self.cheap = [r[0] for r in conn.execute(q.format("<="))]
        self.dear = [r[0] for r in conn.execute(q.format(">"))]
        conn.close()
        self.agent = Agent(self.db, guard=Guard(self.db, CircuitBreaker(max_events=3, window_s=60, cooldown_s=30)))

    def tearDown(self):
        os.close(self.fd)
        os.remove(self.db)

    def refunds(self):
        conn = get_connection(self.db)
        n = conn.execute("SELECT COUNT(*) FROM refunds").fetchone()[0]
        conn.close()
        return n

    def test_small_refund_is_automatic(self):
        res = self.agent.run(f"refund {self.cheap[0]} it arrived damaged")
        self.assertIn("refund #", res["reply"])

    def test_large_refund_is_held_then_approved_once(self):
        res = self.agent.run(f"refund {self.dear[0]} it arrived damaged")
        self.assertIn("review", res["reply"])
        self.assertEqual(self.refunds(), 0)
        conn = get_connection(self.db)
        approval_id = conn.execute("SELECT id FROM approvals").fetchone()[0]
        conn.close()
        self.assertEqual(decide(self.db, self.agent.tools, approval_id, True)[0], 200)
        self.assertEqual(decide(self.db, self.agent.tools, approval_id, True)[0], 409)
        self.assertEqual(self.refunds(), 1)

    def test_partial_refund_amount(self):
        res = self.agent.run(f"please refund $20 on {self.dear[1]}, it was late")
        self.assertIn("$20.00", res["reply"])

    def test_breaker_blocks_a_refund_storm(self):
        replies = [self.agent.run(f"refund $5 on {oid} damaged")["reply"] for oid in self.dear[2:8]]
        self.assertEqual(sum("refund #" in r for r in replies), 4)  # max_events=3: the 4th trips the breaker
        self.assertIn("paused", replies[-1])

    def test_breaker_opens_and_recovers(self):
        clock = FakeClock()
        b = CircuitBreaker(max_events=2, window_s=60, cooldown_s=30, clock=clock)
        for _ in range(3):
            self.assertTrue(b.allow())
            b.record()
        self.assertEqual(b.state, "open")
        self.assertFalse(b.allow())
        clock.t = 31
        self.assertEqual(b.state, "half_open")
        self.assertTrue(b.allow())
        self.assertFalse(b.allow())  # only one trial
        b.record()
        self.assertEqual(b.state, "closed")


if __name__ == "__main__":
    unittest.main()
