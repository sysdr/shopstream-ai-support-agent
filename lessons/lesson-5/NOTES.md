## Everything fails, sometimes twice

So far every call worked. In production, the model API times out during a traffic spike, the order database drops a connection during a failover, and — worst of all — a tool succeeds but its response never makes it back. The agent then doesn't know whether the refund happened. This lesson breaks the agent on purpose and makes it survive: **failure injection**, **retries with exponential backoff and jitter**, a **time budget**, and a **graceful fallback**, all without ever refunding twice.

## What you build

`supportdesk/resilience.py`:

- **`FaultInjector(rate)`** — with probability `FAULT_RATE` a call fails. For the model, a timeout or connection error before the call. For a tool, either *before* (timeout) or *after* — the tool ran, then the response was "lost". The seed is fixed (`FAULT_SEED=7`) so your numbers match ours.
- **`retry(fn, attempts, base, cap, budget_s)`** — retries only transient errors (`TimeoutError`, `ConnectionError`), waiting `random(0, min(cap, base × 2ⁿ))` between tries ("full jitter"), and gives up early if the next wait would cross the time budget. Validation and business errors are never retried: a bad argument won't get better by asking again.
- **`supportdesk/chaos.py`** — plays the same 60 conversations twice under faults, once with retries off and once with 5 attempts, and reports success, latency, retries and duplicate refunds.

In the agent, both the model call and each tool call go through `retry`. If the budget runs out, the agent doesn't crash; it replies:

> I'm having trouble reaching our order system right now. Please try again in a minute; nothing will be refunded twice.

## The lost-response problem

Here's the failure that makes retries dangerous:

```text
attempt 1: process_refund(...)  -> refund row written -> response lost (ConnectionError)
attempt 2: process_refund(...)  -> ???
```

Without protection, attempt 2 refunds again. With Day 2's idempotency key it returns the first result with `"duplicate": true`. The agent's key is derived from the session and the order, so every retry of the same intent carries the same key. That's why we built idempotency before retries: **retries are only safe on top of idempotent operations.**

## Why jitter

If 1,000 conversations hit the same timeout at the same moment and all retry after exactly 100 ms, the dependency gets a second spike exactly 100 ms later. Random delays spread retries out so a struggling service can recover. The cap stops the delays from growing beyond what a customer will wait, and the budget bounds the whole operation.

## Run it

`start.sh` runs 24 unit tests (retry recovers, gives up, never retries a `ValueError`, chaos run has no duplicates), then the chaos demo at a 30% failure rate:

```text
60 conversations, FAULT_RATE=0.3
 retries  success  p50 ms  p99 ms  faults  retried  dup refunds
     off    26.7%     2.1     5.1      44        0            0
 5 tries    98.3%    15.3   191.7      93       92            0
```

Read it carefully:

- **Without retries, 26.7% of conversations succeed.** A refund needs three model calls and two tool calls; at 30% per call, most conversations hit at least one failure.
- **With 5 attempts, 98.3% succeed**, at the cost of latency: p99 goes from 5 ms to 192 ms because of backoff waits.
- **93 faults were injected and 92 retries made — and 0 duplicate refunds**, even though some faults hit after the refund was written.
- The one failure out of 60 got the fallback message, not an error page.

30% is brutal; real dependencies fail far less often. The point of injecting that much is to prove the properties (no duplicates, bounded latency, graceful failure) under stress, so they hold at 0.1% too.

## Trade-offs

- **More attempts** raise success and raise tail latency and load on the failing dependency. Five quick attempts within a 2-second budget suit a chat; a background job could retry for minutes.
- **What to retry.** Only transient errors. Retrying a 400 or a business refusal wastes time and, worse, can hide a bug.
- **Where to retry.** Retrying at every layer multiplies attempts (3 layers × 5 attempts = 125 calls). Retry at one layer — here, the agent — and let the others fail fast.

## What we measured

| Metric (60 conversations, 30% faults) | Retries off | 5 attempts |
| :--- | :--- | :--- |
| Success rate | 26.7% | 98.3% |
| p50 / p99 latency | 2.1 / 5.1 ms | 15.3 / 191.7 ms |
| Injected faults / retries | 44 / 0 | 93 / 92 |
| Duplicate refunds | 0 | 0 |

## Say it in an interview

**Q: How do you make an agent resilient to a flaky model API?**
Retry transient errors with capped exponential backoff and full jitter inside a time budget, never retry validation errors, and fall back to a clear message when the budget runs out. Measure success and p99 under injected faults; ours went from 26.7% to 98.3% success at 30% failure.

**Q: Retries plus payments: what can go wrong?**
A response can be lost after the payment succeeded, so a retry pays twice. Make the operation idempotent with a key stored atomically with the effect; the retry returns the original result. In our chaos run: 92 retries, 0 duplicate refunds.

**Q: Why jitter?**
Synchronised retries create retry storms that keep a recovering service down. Random delays spread the load.

## Recap

- Faults are injected before and after calls, at a fixed seed.
- Retries: transient errors only, exponential backoff, full jitter, a time budget.
- Idempotency keys make retried refunds safe: 0 duplicates.
- When retries run out, the customer gets an honest fallback message.

## Challenge (10 minutes)

Add a per-dependency circuit breaker for the model: after 5 consecutive model failures, skip retries for 10 seconds and reply with the fallback immediately.

<details class="sdc-hint"><summary>Hint 1</summary>

Reuse `CircuitBreaker` from Day 4, but count failures instead of successes: call `record()` from the `except RetryBudgetExceeded` branch around the model call.

</details>

<details class="sdc-hint"><summary>Hint 2</summary>

Check `breaker.allow()` before calling `self.decide(history)`; if it's not allowed, use the fallback reply. Test it with `FaultInjector(rate=1.0)`.

</details>
