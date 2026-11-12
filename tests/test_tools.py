import os
import tempfile
import unittest

from supportdesk.db import get_connection, init_db
from supportdesk.tools import ToolExecutionError, ToolValidationError, build_registry


class TestTools(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fd, cls.db = tempfile.mkstemp(suffix=".db")
        init_db(cls.db)
        cls.reg = build_registry(cls.db)
        conn = get_connection(cls.db)
        cls.shipped = conn.execute("SELECT id FROM orders WHERE status = 'delivered' LIMIT 1").fetchone()[0]
        cls.placed = conn.execute("SELECT id FROM orders WHERE status = 'placed' LIMIT 1").fetchone()[0]
        conn.close()

    @classmethod
    def tearDownClass(cls):
        os.close(cls.fd)
        os.remove(cls.db)

    def test_bad_arguments_name_the_field(self):
        cases = [({}, "order_id"), ({"order_id": 1005}, "order_id"), ({"order_id": "ORD-1"}, "order_id"),
                 ({"order_id": "ORD-1005", "extra": 1}, "extra")]
        for args, field in cases:
            with self.assertRaises(ToolValidationError) as ctx:
                self.reg.call("get_order_status", args)
            self.assertEqual(ctx.exception.field, field)

    def test_refund_rules(self):
        with self.assertRaises(ToolValidationError):
            self.reg.call("process_refund", {"order_id": self.shipped, "amount": -5, "reason": "late", "idempotency_key": "k-neg-1"})
        with self.assertRaises(ToolValidationError):
            self.reg.call("process_refund", {"order_id": self.shipped, "amount": 5, "reason": "bored", "idempotency_key": "k-enum-1"})
        with self.assertRaises(ToolExecutionError):
            self.reg.call("process_refund", {"order_id": self.placed, "amount": 5, "reason": "late", "idempotency_key": "k-placed"})

    def test_idempotent_refund(self):
        args = {"order_id": self.shipped, "amount": 10.0, "reason": "damaged", "idempotency_key": "test-idem-1"}
        first = self.reg.call("process_refund", args)
        again = self.reg.call("process_refund", args)
        self.assertFalse(first["duplicate"])
        self.assertTrue(again["duplicate"])
        self.assertEqual(first["refund_id"], again["refund_id"])
        conn = get_connection(self.db)
        n = conn.execute("SELECT COUNT(*) FROM refunds WHERE idempotency_key = 'test-idem-1'").fetchone()[0]
        conn.close()
        self.assertEqual(n, 1)

    def test_cannot_refund_more_than_the_price(self):
        conn = get_connection(self.db)
        oid, price = conn.execute("SELECT o.id, p.price FROM orders o JOIN products p ON p.name = o.item_name "
                                  "WHERE o.status = 'shipped' ORDER BY o.id DESC LIMIT 1").fetchone()
        conn.close()
        self.reg.call("process_refund", {"order_id": oid, "amount": price, "reason": "late", "idempotency_key": "full-1"})
        with self.assertRaises(ToolExecutionError):
            self.reg.call("process_refund", {"order_id": oid, "amount": 1, "reason": "late", "idempotency_key": "full-2"})

    def test_audit_log(self):
        conn = get_connection(self.db)
        before = conn.execute("SELECT COUNT(*) FROM tool_calls").fetchone()[0]
        self.reg.call("check_stock", {"product": "Gaming Mouse"})
        after = conn.execute("SELECT COUNT(*) FROM tool_calls").fetchone()[0]
        conn.close()
        self.assertEqual(after, before + 1)


if __name__ == "__main__":
    unittest.main()
