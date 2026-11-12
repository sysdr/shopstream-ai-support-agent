# Implementation guide — Day 5: Break the Agent

Time: 35–45 minutes. Python 3.10+ only: no pip, no Docker.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, open the browser sandbox from this page, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-ai-support-agent.git
cd shopstream-ai-support-agent/lessons/lesson-5
```

`start.sh` writes the complete project (everything from Day 1 to Day 5) into `./supportdesk`, so you can start at any lesson.

## What's new in the code

| File | What it does |
|---|---|
| `supportdesk/resilience.py` | FaultInjector (before/after faults, fixed seed), retry() with exponential backoff, full jitter and a time budget |
| `supportdesk/agent.py` | Model and tool calls retried; fallback reply when the budget runs out |
| `supportdesk/chaos.py` | Same conversations with retries off vs on, under FAULT_RATE |
| `tests/test_resilience.py` | Recovery, giving up, no retry for bugs, no duplicate refunds |

## Run it

```bash
bash start.sh
```

It checks Python, writes the files, runs the 24 unit tests, starts the server on port 8090 (`SUPPORTDESK_PORT` to change it), writes and runs `verify.sh`, then runs the demo.

## Expected output

Latency depends on your machine; counts and rates should match.

```text
60 conversations, FAULT_RATE=0.3
 retries  success  p50 ms  p99 ms  faults  retried  dup refunds
     off    26.7%     2.1     5.1      44        0            0
 5 tries    98.3%    15.3   191.7      93       92            0
```

## Try it yourself

- `cd supportdesk && PYTHONPATH=. python3 -m supportdesk.chaos --rate 0.5 --conversations 100`
- `PYTHONPATH=. python3 -m supportdesk.chaos --rate 0.3 --attempts 3`
- `FAULT_RATE=0.2 bash start.sh  (the live server now fails 20% of calls; try /agent)`

## Verify and get your completion code

```bash
bash verify.sh
```

Runs 40 conversations at FAULT_RATE=0.3: at least 95% must succeed with retries and no refund may be duplicated. On success it prints:

```text
PASS  Lesson 5 complete. Your completion code: SHOP4-RETRY-7F4N
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
