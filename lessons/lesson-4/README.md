# Implementation guide — Day 4: Implement the “Human-in-the-Loop” Circuit Breaker

Time: 35–45 minutes. Python 3.10+ only: no pip, no Docker.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, open the browser sandbox from this page, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-ai-support-agent.git
cd shopstream-ai-support-agent/lessons/lesson-4
```

`start.sh` writes the complete project (everything from Day 1 to Day 4) into `./supportdesk`, so you can start at any lesson.

## What's new in the code

| File | What it does |
|---|---|
| `supportdesk/guard.py` | Guard (auto ≤ REFUND_AUTO_LIMIT, hold above), CircuitBreaker (closed/open/half-open), decide() for approvals |
| `supportdesk/agent.py` | Every tool call passes guard.check() first |
| `supportdesk/model.py` | Partial refunds: “refund $20 on ORD-1001” |
| `supportdesk/app.py` | GET /approvals, POST /approvals/ID/approve|reject, GET /guard |
| `tests/test_guard.py` | Auto vs held, approve once, breaker storm, breaker states with a fake clock |

## Run it

```bash
bash start.sh
```

It checks Python, writes the files, runs the 20 unit tests, starts the server on port 8090 (`SUPPORTDESK_PORT` to change it), writes and runs `verify.sh`, then runs the demo.

## Expected output

Latency depends on your machine; counts and rates should match.

```text
Automatic (<= $50)         : 6
Held for a person (> $50)  : 2  -> pending approvals: 2
Blocked by circuit breaker : 4  (breaker is open)
Approve #1 ($159.71)      : 200 refund #7
Approve #1 again         : 409 already approved
```

## Try it yourself

- `curl -s localhost:8090/approvals`
- `curl -s -X POST localhost:8090/approvals/2/reject -d '{}'`
- `curl -s localhost:8090/guard`
- `REFUND_AUTO_LIMIT=100 BREAKER_MAX_REFUNDS=20 bash start.sh  (change the policy)`

## Verify and get your completion code

```bash
bash verify.sh
```

On a fresh database: a $30 refund runs automatically, a full refund over $50 is held, approving twice refunds once (second call 409), and a refund storm opens the breaker. On success it prints:

```text
PASS  Lesson 4 complete. Your completion code: SHOP4-GUARD-2W6H
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
