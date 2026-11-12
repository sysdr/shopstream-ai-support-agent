## From a dispatcher to an agent

Day 1's dispatcher answers one message with one rule. Real support conversations don't look like that: "Where is my order?" … "It's ORD-1012." Or "I want a refund" … "ORD-1080, it came late." Answering them needs three things the dispatcher doesn't have: **memory** of the conversation, a **model** that decides what to do next, and a **loop** that lets the model call a tool, look at the result, and decide again. That loop is what people mean by "agent", and it is small enough to read in one sitting.

## What you build

- **`supportdesk/model.py`** — one interface, two models. `decide(history, tools)` returns either `{"type": "tool", "name", "args"}` or `{"type": "reply", "text"}`, plus estimated token usage.
  - `OfflineModel` is deterministic: it reuses Day 1's intent rules, remembers an order id mentioned earlier in the session, and remembers what it was asking about (a `pending` intent). It is the default and what the tests and `verify.sh` use, so your results match ours exactly.
  - `ClaudeModel` sends the same history and the tool schemas from Day 2 to the Anthropic Messages API with `urllib` when `ANTHROPIC_API_KEY` is set, and maps `tool_use` blocks back to the same decision shape.
- **`supportdesk/agent.py`** — the loop, with sessions stored in a new `messages` table.
- **`POST /agent`** — `{"message", "session_id"}` in; reply, steps, tool calls and session id out.

The loop itself:

```python
while steps < MAX_STEPS:
    steps += 1
    d = self.model.decide(history, self.tools.specs())
    if d["type"] == "reply":
        break
    result = self.run_tool(d["name"], d["args"])   # Day 2 registry: validated + audited
    history.append({"role": "tool", "name": d["name"], "args": d["args"], "result": result})
```

Three details carry most of the weight:

1. **`MAX_STEPS = 5`.** A model that keeps calling tools is the agent version of an infinite loop. Five is plenty for these tasks (a refund takes three: look up, refund, reply) and caps the worst-case cost of a confused model.
2. **Tool errors become data, not exceptions.** `run_tool` turns a 400/422-style error into `{"error": "..."}` in the history. The model sees it and can explain it to the customer instead of the request crashing.
3. **State lives in SQLite, not in the process.** Any server process can continue any session, which is what lets you run more than one later.

A refund is the clearest example of the loop. The model doesn't know the price, so it can't refund in one step:

```text
user:  My ORD-1080 arrived broken, I want a refund
model: tool get_order_status {"order_id": "ORD-1080"}
tool:  {"status": "delivered", "price": 46.68, ...}
model: tool process_refund {"order_id": "ORD-1080", "amount": 46.68, "reason": "damaged",
                            "idempotency_key": "<session>-ORD-1080"}
tool:  {"refund_id": 1, "duplicate": false}
model: reply "Done: refund #1 of $46.68 for order ORD-1080 is on its way."
```

The idempotency key is derived from the session and the order, so if the same conversation is retried it can't refund twice.

## Run it

`start.sh` runs 15 unit tests (two-turn memory, refunds across turns, off-topic questions), starts the server and plays 10 conversations, three of them over two turns:

```text
[dc11…] 'Where is my order?'      -> tools -
[dc11…] "It's ORD-1012"           -> tools ['get_order_status']
    agent: Order ORD-1012 (USB-C Fast Charger) is cancelled.
[51e8…] 'My ORD-1080 arrived broken, I want a refund' -> tools ['get_order_status', 'process_refund']
    agent: Done: refund #1 of $46.68 for order ORD-1080 is on its way.
[caf6…] 'I want a refund please'  -> tools -
[caf6…] 'ORD-1080, it came late'  -> tools ['get_order_status', 'process_refund']
    agent: I couldn't refund order ORD-1080: order ORD-1080 has $46.68 refunded already; ...
Resolved                   : 9/10
Model steps per turn (avg) : 1.83 (max 3)
Latency p50 / p99          : 2.72 / 8.83 ms
```

Look at the second refund. A different conversation asked to refund the same order. The model did exactly what it was told, with a new session and so a new idempotency key, and the only thing that stopped a double refund was Day 2's rule in the tool: never refund more than the price in total. That is the pattern to remember: **guardrails belong in the tools, because the model will be wrong in ways your prompt didn't anticipate.**

## Trade-offs

- **Offline vs hosted model.** The rules model is free, deterministic and ~0.1 ms; it can't understand "the thing I bought last Tuesday". A hosted model can, at 0.5–3 s and real money per turn. Keeping both behind one interface lets you test the system deterministically and switch the brain with an environment variable.
- **Full history vs summaries.** We send the whole session each turn. That's simple and correct; for long chats you'd summarise older turns to cap tokens (Day 6 measures exactly how many).
- **Step cap vs completeness.** A higher cap solves more edge cases and makes runaway loops more expensive. Measure average steps (1.83 here) and set the cap a little above your longest legitimate plan.

## What we measured

| Metric | Result |
| :--- | :--- |
| Conversations / turns | 10 / 12 |
| Resolved | 9 of 10 (the 10th was a double refund, correctly refused) |
| Steps per turn | 1.83 average, 3 max |
| p50 / p99 latency | 2.72 ms / 8.83 ms |

## Say it in an interview

**Q: What is an agent loop, concretely?**
A loop where a model reads the conversation plus tool results and either calls a tool or replies, with a step limit. Tools are validated and audited; their errors go back into the history so the model can recover or explain.

**Q: How does a multi-turn agent remember context?**
Store messages per session (we use SQLite), reload them each turn, and let the model see earlier turns. Our model also records a pending intent when it asks a question, so "ORD-1012" alone continues "where is my order?".

**Q: How do you stop an agent from refunding twice?**
Not with the prompt. Idempotency keys per conversation and order, and a hard rule in the refund tool that the total can't exceed the price. In our demo a second conversation tried to refund the same order and the tool refused.

## Recap

- One `decide()` interface; a deterministic offline model by default, Claude when a key is set.
- The loop calls validated tools, feeds results back, and stops at 5 steps.
- Sessions in SQLite give multi-turn memory: 3 two-turn conversations resolved.
- A double refund attempt was stopped by the tool, not the model.

## Challenge (10 minutes)

Make "and where is my other order, ORD-1100?" work in the same session after a refund: the agent should answer the status of ORD-1100, not try to refund it.

<details class="sdc-hint"><summary>Hint 1</summary>

Look at how `pending` is used in `OfflineModel._decide`: a pending intent should only apply when the new message contains an order id and nothing else that signals a different intent.

</details>

<details class="sdc-hint"><summary>Hint 2</summary>

Treat the words "where", "status" and "track" as a new `order_status` intent that wins over a pending refund, and add a unit test with the three-turn conversation.

</details>
