import json
import os
import tempfile
import unittest
from pathlib import Path

from supportdesk.db import init_db
from supportdesk.dispatcher import IntentDispatcher


class TestIntentDispatcher(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db_fd, cls.db_path = tempfile.mkstemp(suffix=".db")
        init_db(cls.db_path)
        cls.dispatcher = IntentDispatcher(cls.db_path)

    @classmethod
    def tearDownClass(cls):
        os.close(cls.db_fd)
        os.remove(cls.db_path)

    def test_order_status_dispatch(self):
        res = self.dispatcher.dispatch("Where is order ORD-1005?")
        self.assertEqual(res["intent"], "order_status")
        self.assertEqual(res["slots"]["order_id"], "ORD-1005")
        self.assertIn("ORD-1005", res["reply"])

    def test_refund_request_dispatch(self):
        res = self.dispatcher.dispatch("I want a refund for ORD-1010")
        self.assertEqual(res["intent"], "refund_request")

    def test_stock_check_dispatch(self):
        res = self.dispatcher.dispatch("Do you have Wireless Headphones in stock?")
        self.assertEqual(res["slots"].get("product"), "Wireless Headphones")

    def test_refund_policy_dispatch(self):
        res = self.dispatcher.dispatch("What is your refund policy?")
        self.assertIn("Unopened items", res["reply"])

    def test_unknown_fallback(self):
        self.assertEqual(self.dispatcher.dispatch("What is the capital of France?")["intent"], "unknown")

    def test_labelled_cases_accuracy(self):
        cases = json.loads((Path(__file__).parent / "cases.json").read_text())
        ok = sum(self.dispatcher.dispatch(c["message"])["intent"] == c["expected_intent"] for c in cases)
        self.assertGreaterEqual(ok / len(cases), 0.9)


if __name__ == "__main__":
    unittest.main()
