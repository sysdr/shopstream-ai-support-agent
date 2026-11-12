# Implementation guide — Day 7: Run the Evaluation Harness

Time: 35–45 minutes. Python 3.10+ only: no pip, no Docker.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, open the browser sandbox from this page, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-ai-support-agent.git
cd shopstream-ai-support-agent/lessons/lesson-7
```

`start.sh` writes the complete project (everything from Day 1 to Day 7) into `./supportdesk`, so you can start at any lesson.

## What's new in the code

| File | What it does |
|---|---|
| `supportdesk/evals/cases.json` | 50 labelled conversations |
| `supportdesk/evals/run_eval.py` | Replays the cases on a fresh database; task success, tool selection, hallucination, latency, cost; writes report.json/report.md |
| `tests/test_eval.py` | The quality bar as a unit test |

## Run it

```bash
bash start.sh
```

It checks Python, writes the files, runs the 26 unit tests, starts the server on port 8090 (`SUPPORTDESK_PORT` to change it), writes and runs `verify.sh`, then runs the demo.

## Expected output

Latency depends on your machine; counts and rates should match.

```text
cases: 50
task_success: 1.0
tool_selection_accuracy: 1.0
hallucination_rate: 0.0
est_cost_per_1k_conversations_usd: 1.099
Same eval with the production breaker (5 refunds per minute):
task_success: 0.94
```

## Try it yourself

- `cd supportdesk && PYTHONPATH=. python3 -m supportdesk.evals.run_eval`
- `less supportdesk/supportdesk/evals/report.md`
- `EVAL_BREAKER_MAX=5 PYTHONPATH=. python3 -m supportdesk.evals.run_eval  (the production breaker)`
- `export ANTHROPIC_API_KEY=... and run the eval again to score Claude`

## Verify and get your completion code

```bash
bash verify.sh
```

Runs the 50-case evaluation: task success must be at least 90% and hallucination 0%. On success it prints:

```text
PASS  Lesson 7 complete. Your completion code: SHOP4-EVAL-4X8B
```

Enter the code below the lesson to mark it complete.

## Stop

```bash
bash stop.sh
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Address already in use` | Run `bash stop.sh`, or `SUPPORTDESK_PORT=8091 bash start.sh` |
| `server did not start` | Read `supportdesk/.run/app.log` |
| `unit tests failed` | `cd supportdesk && python3 -m unittest discover -s tests -v` shows which one |
