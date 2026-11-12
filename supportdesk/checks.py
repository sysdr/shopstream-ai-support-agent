"""Day 7 checks used by verify.sh."""
import sys

from supportdesk.client import get
from supportdesk.evals.run_eval import run


def fail(msg):
    print(f"[FAIL] {msg}")
    sys.exit(1)


if get("/health")[0] != 200:
    fail("server is not running: run start.sh first")
summary, _ = run()
print(f"[VERIFY] {summary['cases']} cases: task success {summary['task_success']:.0%}, tool selection "
      f"{summary['tool_selection_accuracy']:.0%}, hallucinations {summary['hallucination_rate']:.0%}")
if summary["task_success"] < 0.9 or summary["hallucination_rate"] > 0:
    fail("quality bar: task success >= 90% and no hallucinations")
if get("/metrics")[0] != 200:
    fail("/metrics is not answering")
