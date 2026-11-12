import unittest

from supportdesk.evals.run_eval import run


class TestEval(unittest.TestCase):
    def test_quality_bar(self):
        summary, results = run()
        self.assertEqual(summary["cases"], 50)
        self.assertGreaterEqual(summary["task_success"], 0.9)
        self.assertEqual(summary["hallucination_rate"], 0)


if __name__ == "__main__":
    unittest.main()
