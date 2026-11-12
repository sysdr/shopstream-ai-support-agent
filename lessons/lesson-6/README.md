# Implementation guide — Day 6: Build an Observability Wrapper

Time: 35–45 minutes. Python 3.10+ only: no pip, no Docker.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, open the browser sandbox from this page, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-ai-support-agent.git
cd shopstream-ai-support-agent/lessons/lesson-6
```

`start.sh` writes the complete project (everything from Day 1 to Day 6) into `./supportdesk`, so you can start at any lesson.

## What's new in the code

| File | What it does |
|---|---|
| `supportdesk/telemetry.py` | Thread-local traces, step() for model/tool calls, finish() to the interactions table, metrics(), trace() |
| `supportdesk/agent.py` | Every model and tool call recorded (including failures) |
| `supportdesk/db.py` | New interactions table |
| `supportdesk/app.py` | GET /metrics, GET /traces/ID, X-Trace-Id header on /agent |
| `tests/test_telemetry.py` | One trace per request, model → tool → model steps, tokens and cost |

## Run it

```bash
bash start.sh
```

It checks Python, writes the files, runs the 25 unit tests, starts the server on port 8090 (`SUPPORTDESK_PORT` to change it), writes and runs `verify.sh`, then runs the demo.

## Expected output

Latency depends on your machine; counts and rates should match.

```text
interactions                    : 105
success_rate                    : 1.0
latency_p50_ms                  : 2.32
latency_p99_ms                  : 5.63
tool_calls                      : 71
tokens_in                       : 8218
tokens_out                      : 3816
cost_per_1k_conversations_usd   : 0.7799
```

## Try it yourself

- `curl -s localhost:8090/metrics`
- `curl -si -X POST localhost:8090/agent -d '{"message":"Where is ORD-1100?"}' | grep -i x-trace-id`
- `curl -s localhost:8090/traces/PASTE_TRACE_ID`
- `PRICE_IN_PER_MTOK=0.8 PRICE_OUT_PER_MTOK=4 bash start.sh  (a cheaper model's cost)`

## Verify and get your completion code

```bash
bash verify.sh
```

Sends 5 requests and checks /metrics grew by exactly 5, every response has X-Trace-Id, and the trace shows model → tool → model. On success it prints:

```text
PASS  Lesson 6 complete. Your completion code: SHOP4-OBSERVE-9D1P
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
