"""Day 7 demo: the full evaluation, and what the production breaker does to it."""
import os
import runpy
import subprocess
import sys

r = subprocess.run([sys.executable, "-m", "supportdesk.evals.run_eval"], capture_output=True, text=True)
print(r.stdout)
env = {**os.environ, "EVAL_BREAKER_MAX": "5"}
r2 = subprocess.run([sys.executable, "-m", "supportdesk.evals.run_eval"], capture_output=True, text=True, env=env)
print("Same eval with the production breaker (5 refunds per minute):")
print("\n".join(l for l in r2.stdout.splitlines() if "task_success" in l or "FAILED" in l))
print("Report written to supportdesk/supportdesk/evals/report.md")
