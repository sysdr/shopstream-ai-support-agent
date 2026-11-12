import random
import unittest

from supportdesk.chaos import run
from supportdesk.resilience import RetryBudgetExceeded, retry


class TestRetry(unittest.TestCase):
    def test_recovers_from_transient_errors(self):
        calls = []

        def flaky():
            calls.append(1)
            if len(calls) < 3:
                raise ConnectionError("boom")
            return "ok"
        self.assertEqual(retry(flaky, attempts=4, sleep=lambda s: None, rng=random.Random(1)), "ok")
        self.assertEqual(len(calls), 3)

    def test_gives_up(self):
        def down():
            raise TimeoutError("down")
        with self.assertRaises(RetryBudgetExceeded) as ctx:
            retry(down, attempts=3, sleep=lambda s: None)
        self.assertEqual(ctx.exception.attempts, 3)

    def test_other_errors_are_not_retried(self):
        calls = []

        def bug():
            calls.append(1)
            raise ValueError("bug")
        with self.assertRaises(ValueError):
            retry(bug, sleep=lambda s: None)
        self.assertEqual(len(calls), 1)

    def test_chaos_no_duplicate_refunds(self):
        off, on = run(0.3, 1, 30), run(0.3, 5, 30)
        self.assertGreater(on["success_rate"], off["success_rate"])
        self.assertGreaterEqual(on["success_rate"], 0.9)
        self.assertEqual(on["duplicate_refunds"], 0)


if __name__ == "__main__":
    unittest.main()
