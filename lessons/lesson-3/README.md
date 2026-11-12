# Implementation guide — Day 3: Integrate the Agent Loop

Time: 35–45 minutes. Python 3.10+ only: no pip, no Docker.

## Get the code

Download **start.sh** and **stop.sh** from the Scripts tab, open the browser sandbox from this page, or clone the course repo:

```bash
git clone https://github.com/sysdr/shopstream-ai-support-agent.git
cd shopstream-ai-support-agent/lessons/lesson-3
```

`start.sh` writes the complete project (everything from Day 1 to Day 3) into `./supportdesk`, so you can start at any lesson.

## What's new in the code

| File | What it does |
|---|---|
| `supportdesk/model.py` | decide() interface; OfflineModel (default, deterministic) and ClaudeModel (urllib, when ANTHROPIC_API_KEY is set) |
| `supportdesk/agent.py` | The loop: model → tool → result → model, MAX_STEPS = 5, sessions in SQLite |
| `supportdesk/db.py` | New messages table (conversation history per session) |
| `supportdesk/app.py` | POST /agent {message, session_id} |
| `tests/test_agent.py` | Two-turn memory, two-step refund, refund across turns, off-topic |

## Run it

```bash
bash start.sh
```

It checks Python, writes the files, runs the 15 unit tests, starts the server on port 8090 (`SUPPORTDESK_PORT` to change it), writes and runs `verify.sh`, then runs the demo.

## Expected output

Latency depends on your machine; counts and rates should match.

```text
Conversations              : 10 (12 turns)
Resolved                   : 9/10
Model steps per turn (avg) : 1.83 (max 3)
Latency p50 / p99          : 2.72 / 8.83 ms
```

## Try it yourself

- `curl -s -X POST localhost:8090/agent -d '{"message":"Where is my order?"}'  (copy the session_id)`
- `curl -s -X POST localhost:8090/agent -d '{"message":"It is ORD-1012","session_id":"PASTE"}'`
- `export ANTHROPIC_API_KEY=... then bash start.sh to run the same loop on Claude`

## Verify and get your completion code

```bash
bash verify.sh
```

Checks a two-turn conversation (the agent asks which order, then answers from the database) and that off-topic questions call no tools. On success it prints:

```text
PASS  Lesson 3 complete. Your completion code: SHOP4-LOOP-5Q9T
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
