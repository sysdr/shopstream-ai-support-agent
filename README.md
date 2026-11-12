# ShopStream AI Support Agent (Python)

Source code for the free course **[Build a Production-Grade AI Support Agent for ShopStream (Python)](https://systemdrd.com/courses/build-a-production-grade-ai-support-agent-for-shopstream-python/)** on systemdrd.com — step 4 of the free ShopStream learning path.

You build one project, `supportdesk`: a customer-support agent for the ShopStream shop that answers order, refund and stock questions by calling real tools against SQLite, with guardrails, retries, observability and an evaluation harness.

- **Python 3.10+ standard library and SQLite only.** No pip, no Docker.
- **Runs offline by default** with a deterministic model, so every number in the lessons is reproducible. Set `ANTHROPIC_API_KEY` to run the same agent on Claude.

## Lessons

Each lesson folder is self-contained: `start.sh` writes the complete project up to that day, runs the unit tests, starts the server on port 8090, verifies it and runs the demo. `README.md` is the implementation guide, `NOTES.md` the lesson notes, `diagrams/` the diagrams.

| Day | Lesson | What you measure |
|---|---|---|
| 1 | [Build a deterministic dispatcher](lessons/lesson-1) | 100% intent accuracy on 30 messages, p50 1.7 ms |
| 2 | [Instrument the tool-calling interface](lessons/lesson-2) | 9 bad calls rejected, 2 duplicate refunds prevented |
| 3 | [Integrate the agent loop](lessons/lesson-3) | 9/10 conversations resolved, 1.83 model steps per turn |
| 4 | [Human-in-the-loop circuit breaker](lessons/lesson-4) | 6 auto, 2 held, 4 blocked; approve-twice → 409 |
| 5 | [Break the agent](lessons/lesson-5) | 26.7% → 98.3% success at 30% faults, 0 duplicate refunds |
| 6 | [Observability wrapper](lessons/lesson-6) | traces, p50/p99, $0.78 per 1,000 conversations |
| 7 | [Evaluation harness](lessons/lesson-7) | 100% task success, 0% hallucination on 50 cases |

## Quick start

```bash
git clone https://github.com/sysdr/shopstream-ai-support-agent.git
cd shopstream-ai-support-agent/lessons/lesson-1
bash start.sh      # build, test, run, verify, demo
bash stop.sh
```

Or click **Run in browser sandbox** on any lesson page.

## The finished project

The repository root holds the final code (Day 7):

```bash
python3 -m unittest discover -s tests        # 26 tests
python3 -c "from supportdesk.db import init_db; init_db()"
python3 -m supportdesk.app &                  # http://localhost:8090
python3 -m supportdesk.evals.run_eval         # writes supportdesk/evals/report.md
```

| Module | Role |
|---|---|
| `db.py` | Schema and deterministic seed (`random.Random(42)`) |
| `dispatcher.py` | Day 1 regex dispatcher |
| `tools.py` | Schema-validated, audited tools; idempotent refunds |
| `model.py`, `agent.py` | Model interface (offline / Claude) and the agent loop |
| `guard.py` | Approval threshold and refund circuit breaker |
| `resilience.py`, `chaos.py` | Fault injection, retries with backoff and jitter |
| `telemetry.py` | Traces, `/metrics`, token and cost estimates |
| `evals/` | 50-case evaluation harness |

`bash test_all.sh` runs every lesson end to end.

## License

MIT
