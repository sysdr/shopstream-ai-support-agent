# Implementation guide — Day 2: Instrument the Tool-Calling Interface

Time: 35–45 minutes. Python 3.10+ only: no pip, no Docker.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, open the browser sandbox from this page, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-ai-support-agent.git
cd shopstream-ai-support-agent/lessons/lesson-2
```

`start.sh` writes the complete project (everything from Day 1 to Day 2) into `./supportdesk`, so you can start at any lesson.

## What's new in the code

| File | What it does |
|---|---|
| `supportdesk/tools.py` | Schema validator, ToolRegistry, get_order_status, check_stock, process_refund (idempotent, capped at the price) |
| `supportdesk/db.py` | New tables: refunds (UNIQUE idempotency_key) and tool_calls (audit) |
| `supportdesk/dispatcher.py` | Lookups now go through the registry |
| `supportdesk/app.py` | GET /tools, POST /tools/NAME (400 bad arguments, 422 refused) |
| `supportdesk/demo.py, supportdesk/checks.py` | The 40-call demo and the checks verify.sh runs |
| `tests/test_tools.py` | Validation, refund rules, idempotency, audit |

## Run it

```bash
bash start.sh
```

It checks Python, writes the files, runs the 11 unit tests, starts the server on port 8090 (`SUPPORTDESK_PORT` to change it), writes and runs `verify.sh`, then runs the demo.

## Expected output

Latency depends on your machine; counts and rates should match.

```text
Accepted (200)             : 30
Rejected by schema (400)   : 9
Refused by business rule (422): 1
Refunds created            : 3 (5 refund calls, 2 were retries)
Duplicate refunds prevented: 2
Latency p50 / p99          : 1.70 / 7.88 ms
```

## Try it yourself

- `curl -s localhost:8090/tools`
- `curl -s -X POST localhost:8090/tools/get_order_status -d '{"order_id": 1005}'`
- `curl -s -X POST localhost:8090/tools/process_refund -d '{"order_id":"ORD-1001","amount":5,"reason":"late","idempotency_key":"try-it-1"}'  (run it twice)`

## Verify and get your completion code

```bash
bash verify.sh
```

Checks a bad argument returns 400 naming the field, the same refund twice creates exactly one row, and /chat still works. On success it prints:

```text
PASS  Lesson 2 complete. Your completion code: SHOP4-TOOLS-8M2C
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
