# Implementation guide — Day 1: Build a Deterministic Dispatcher

Time: 30–40 minutes. Everything runs on your machine or in the browser sandbox; nothing is installed system-wide.

## Before you start

- **Python 3.10 or newer** (`python3 --version`) and `curl`. No `pip install`: the project uses only the standard library and SQLite.
- Linux, macOS, or Windows with WSL — or click **Run in browser sandbox** on this page.
- Get the scripts: download **start.sh** and **stop.sh** from the Scripts tab, or clone the course repo and open the lesson folder:

```bash
git clone https://github.com/sysdr/shopstream-ai-support-agent.git
cd shopstream-ai-support-agent/lessons/lesson-1
```

## Run it

```bash
bash start.sh
```

`start.sh` does everything in order:

1. Checks for Python 3.10+.
2. Writes the project into `./supportdesk`: `supportdesk/db.py` (schema and seed), `supportdesk/dispatcher.py` (intent rules and SQL handlers), `supportdesk/app.py` (HTTP server), `tests/cases.json` (30 labelled messages) and `tests/test_dispatcher.py`.
3. Runs the unit tests and stops if any fail.
4. Seeds `shop.db` with 50 customers, 20 products and 300 orders (`random.Random(42)`, so your data matches ours).
5. Starts the server on port 8090 (`SUPPORTDESK_PORT` to change it) and waits for `/health`.
6. Writes `verify.sh`, runs it, then runs the demo.

## Expected output

```text
Ran 5 tests ... OK
[VERIFY] Benchmark Accuracy: 100.00% (Threshold: 90.00%)
PASS  Lesson 1 complete. Your completion code: SHOP4-DISPATCH-3K7R
Total Test Cases Processed : 30
Intent Matching Accuracy   : 100.00%
Unknown Intent Rate        : 13.33%
Latency p50                : 1.74 ms
Latency p99                : 29.56 ms
```

Latency depends on your machine; accuracy and the unknown rate should match exactly.

## Try it by hand

```bash
curl -s -X POST localhost:8090/chat -H 'Content-Type: application/json' -d '{"message":"where is order ORD-1005"}'
curl -s -X POST localhost:8090/chat -H 'Content-Type: application/json' -d '{"message":"refund ORD-1020 please"}'
curl -s -X POST localhost:8090/chat -H 'Content-Type: application/json' -d '{"message":"tell me a joke"}'
```

The last one returns `"intent": "unknown"` with a reply asking for an order id — the safe fallback that later lessons hand to the model.

## Verify and get your completion code

```bash
bash verify.sh
```

It checks `/health`, a real order lookup and at least 90% accuracy on the test set, then prints `PASS  Lesson 1 complete. Your completion code: SHOP4-DISPATCH-3K7R`. Enter the code below the lesson to mark it complete.

## Stop

```bash
bash stop.sh
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Address already in use` | Another app uses port 8090. Run `bash stop.sh`, or `SUPPORTDESK_PORT=8091 bash start.sh`. |
| `Server failed to pass health check` | Read `supportdesk/.run/app.log`; the Python error is there. |
| Tests fail after you edit the code | Run `python3 -m unittest discover -s supportdesk/tests` inside the lesson folder to see which one. |
