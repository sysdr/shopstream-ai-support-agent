## Some actions need a person

After Day 3 the agent can move money. For a $5 partial refund on a late delivery that's exactly what you want: instant, cheap, happy customer. For a $160 refund on a chair, or the fiftieth refund in a minute, it isn't. Real support systems separate actions by **risk**: low-risk actions run automatically, high-risk ones wait for a human, and when something looks wrong at scale, the system stops itself. This lesson adds both: a **human-in-the-loop approval queue** and a **circuit breaker**.

## What you build

`supportdesk/guard.py`, wired into the agent before every tool call:

```python
verdict, result = self.guard.check(name, args)
if verdict != "allow":
    return result            # held or blocked: the model explains it to the customer
result = self.tools.call(name, args)
self.guard.after(name, result)   # counts automatic refunds for the breaker
```

- **Risk threshold.** `process_refund` above `REFUND_AUTO_LIMIT` (default $50) is **held**: a row goes into a new `approvals` table and the tool returns `{"status": "pending_approval", "approval_id": N}`. The customer hears "needs a quick review by our team".
- **Approvals API.** `GET /approvals` lists pending requests; `POST /approvals/N/approve` runs the refund using the idempotency key stored with the request, then marks it approved. Approving twice returns **409** and never refunds twice. `/reject` declines.
- **Circuit breaker.** A classic three-state breaker counts automatic refunds in a sliding window. More than `BREAKER_MAX_REFUNDS` (5) in `BREAKER_WINDOW_S` (60 s) and it **opens**: refunds are refused for `BREAKER_COOLDOWN_S` (30 s). Then it goes **half-open** and lets exactly one trial refund through; if that succeeds, it closes.
- **Partial refunds.** The model now understands "refund $20 on ORD-1001", so small, auto-approvable refunds are possible even on expensive items.

## Why a breaker, not just a limit

A per-request limit ($50) protects against one bad decision. It does nothing against many small ones: a prompt-injection campaign, a bug in your intent rules, or a confused model looping through a customer's orders. The breaker watches the **rate** of an action across all conversations and fails closed when that rate looks abnormal. It's the same pattern that protects a service from hammering a failing dependency, pointed at your own agent.

## Run it

`start.sh` runs 20 unit tests (including a fake clock that walks the breaker through closed → open → half-open → closed), then sends 12 refund requests through the agent:

```text
auto     Please refund $20 on ORD-1001, it came late   -> Done: refund #1 of $20.00 ...
held     I want a full refund for ORD-1002, it is broken -> ... needs a quick review by our team
held     Refund ORD-1005, wrong item                   -> ... needs a quick review by our team
auto     Please refund $35 on ORD-1008, damaged        -> Done: refund #2 of $35.00 ...
auto     Refund $5 on ORD-1009 ... ORD-1015 (4 more)   -> Done
blocked  Refund $5 on ORD-1016, it arrived damaged     -> refunds are paused (circuit open)
...
Automatic (<= $50)         : 6
Held for a person (> $50)  : 2  -> pending approvals: 2
Blocked by circuit breaker : 4  (breaker is open)
Approve #1 ($159.71)      : 200 refund #7
Approve #1 again         : 409 already approved
```

The sixth automatic refund in a minute tripped the breaker; the next four were refused with a message the customer can understand. The first held refund was approved by "a person" (the demo), executed once, and the second approval was rejected with 409.

## Where the human fits

The approval queue is deliberately boring: a table, two endpoints, and an idempotency key. That's the point. The agent never waits for the human; it tells the customer what happens next and finishes the conversation. The human works the queue at their own pace, and approving executes the exact refund the agent proposed, not a new one. In production you'd notify the queue (Slack, email), show the conversation next to each request, and record who approved.

## Trade-offs

- **Threshold too low** and humans drown in approvals; **too high** and the agent moves real money unsupervised. Start strict, then raise it using the data from Day 6's metrics.
- **Breaker too sensitive** blocks legitimate busy hours; **too lax** lets a runaway agent do damage first. Size it from the normal peak rate of the action, not from a guess.
- **Fail closed vs open.** For refunds we fail closed (stop refunding). For read-only tools like order status you'd fail open. Decide per action.

## What we measured

| Metric | Result |
| :--- | :--- |
| Refund requests | 12 |
| Automatic / held / blocked | 6 / 2 / 4 |
| Approvals | first approve 200 (refund #7), second 409 |
| Unit tests | 20 passing |

## Say it in an interview

**Q: How would you let an AI agent issue refunds safely?**
Small refunds automatically, large ones to a human approval queue, all idempotent; business rules in the tool; and a circuit breaker on the refund rate that stops the agent when behaviour looks abnormal. The agent tells the customer what happens next instead of waiting.

**Q: Explain the circuit breaker states.**
Closed: actions flow and are counted. Open: too many in the window, actions are refused for a cooldown. Half-open: after the cooldown one trial is allowed; success closes the breaker, failure (or another burst) opens it again.

**Q: What stops a reviewer from approving the same refund twice?**
The approval stores the original idempotency key; approving runs the refund with that key, and the approval row moves to `approved` in a guarded UPDATE, so a second click returns 409 and the refund tool returns the original refund anyway.

## Recap

- Risk-based routing: ≤ $50 automatic, > $50 held for a person.
- Approvals execute the exact proposed refund once; repeats get 409.
- A three-state breaker stopped a burst after 6 automatic refunds.
- The agent explains held and blocked actions instead of failing.

## Challenge (10 minutes)

Make the threshold depend on the customer: customers with no refunds in the last 30 days get $75, everyone else $50.

<details class="sdc-hint"><summary>Hint 1</summary>

`Guard.check` receives the tool arguments; look up the order's `customer_id`, then count that customer's rows in `refunds` (join through `orders`).

</details>

<details class="sdc-hint"><summary>Hint 2</summary>

Keep the decision in one function (`limit_for(customer_id)`) so you can unit-test it without the agent, and add a test for each side of the boundary.

</details>
