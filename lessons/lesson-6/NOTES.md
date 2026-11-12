## You can't fix what you can't see

The agent now works, defends itself and survives failures. In production the questions change: how slow is it at p99, how often do tools fail, how many tokens does a conversation use, and what will it cost at 10,000 conversations a day? Logs won't answer those. This lesson adds **telemetry**: one trace per request with every model and tool step, stored and aggregated into a `/metrics` endpoint.

## What you build

`supportdesk/telemetry.py`:

- **`start(session_id)`** creates a trace with a `trace_id` (in a thread-local, because the server handles requests on many threads).
- **`step(kind, name, started, ok, ...)`** records one model or tool call: latency, success, and for model calls the input/output tokens.
- **`finish(...)`** writes one row to a new `interactions` table: latency, model calls, tool calls, tool errors, retries, tokens, estimated cost, and the steps as JSON.
- **`metrics()`** aggregates all interactions: success rate, p50/p99 latency, tool success rate, retries, tokens and cost per 1,000 conversations.

The agent calls `step()` around every model decision and tool call — including failed ones — and `finish()` at the end of `run()`. The API gains:

- `GET /metrics` — the aggregates above.
- `GET /traces/TRACE_ID` — every step of one request.
- An `X-Trace-Id` header on every `/agent` response, so a support ticket can quote the exact trace.

## Tokens and cost without a paid model

The offline model doesn't bill anything, but you still want to know what a hosted model would cost. The offline model estimates tokens as characters ÷ 4 (close enough for English JSON), and the cost uses `PRICE_IN_PER_MTOK` and `PRICE_OUT_PER_MTOK` (default $3 and $15 per million). With `ANTHROPIC_API_KEY` set, the real `usage` numbers from the API are used instead. Either way the formula is the same:

```python
cost = tokens_in / 1e6 * PRICE_IN + tokens_out / 1e6 * PRICE_OUT
```

## Run it

`start.sh` runs 25 unit tests (one trace per request, model → tool → model steps, non-zero cost), then sends 100 `/agent` requests — order status, stock, $5 refunds, a policy question and an off-topic one — and prints `/metrics` and one trace:

```text
interactions                    : 105
success_rate                    : 1.0
latency_p50_ms                  : 2.32
latency_p99_ms                  : 5.63
tool_calls                      : 71
tool_success_rate               : 1.0
tokens_in                       : 8218
tokens_out                      : 3816
cost_per_1k_conversations_usd   : 0.7799
Trace 95147f81… (2.69 ms, 109+42 tokens):
   model  offline-rules-v1     0.124 ms  ok=True
   tool   get_order_status     1.110 ms  ok=True
   model  offline-rules-v1     0.041 ms  ok=True
```

(105 because `verify.sh` sent 5 requests before the demo.) The trace shows where the time goes: the tool call — a SQLite query — is 1.1 ms of the 2.7 ms; the offline model is a rounding error. With a hosted model the picture flips: two model calls of 500–1500 ms each would be 99% of the latency, and the trace would show it immediately.

## Reading the numbers

- **~78 cents per 1,000 conversations** at hosted prices, from ~115 tokens per conversation. Full conversation history is sent on every turn, so long conversations grow quadratically; this is the number to watch when you add summaries or longer prompts.
- **Tool success 100%** here; in Day 5's chaos run it wouldn't be. Alert on this rate, not on individual errors.
- **p99 vs p50.** The ratio tells you about tail behaviour. A p99 ten times the p50 usually means retries, lock waits or a cold cache — the traces of the slowest requests tell you which.

## Trade-offs

- **Store every trace or sample?** We store all; at scale you sample (keep 1%, plus every error and every slow request).
- **SQLite vs a metrics system.** Fine for one process and a lesson. In production you'd export the same fields to OpenTelemetry and Prometheus — the next course in this path does exactly that.
- **Estimated vs exact tokens.** Estimates are good for trends and budgets; use the provider's `usage` for billing.

## What we measured

| Metric (100 requests + 5 from verify) | Result |
| :--- | :--- |
| Success rate | 100% |
| p50 / p99 latency | 2.32 / 5.63 ms |
| Tool calls / tool success | 71 / 100% |
| Tokens in / out | 8,218 / 3,816 |
| Est. cost per 1,000 conversations | $0.78 |

## Say it in an interview

**Q: What would you monitor for an LLM agent in production?**
Per request: latency per step, model calls, tool calls and errors, retries, tokens, cost, outcome. Aggregated: success rate, p50/p99, tool success rate, cost per 1,000 conversations. Every response carries a trace id that links to the steps.

**Q: How do you estimate the cost of an agent before launch?**
Replay realistic conversations, record input and output tokens per call, multiply by prices, and report per 1,000 conversations — ours is $0.78 at $3/$15 per million tokens. Watch how it grows with conversation length.

**Q: The agent got slow. How do you find out why?**
Compare p50 and p99, pull traces of the slowest requests, and see which step dominates: model latency, a slow tool query, or retries.

## Recap

- One trace per request; every model and tool step timed, with tokens.
- `/metrics` aggregates success, latency, tool health, tokens and cost.
- `X-Trace-Id` links a customer complaint to the exact steps.
- At hosted prices this agent costs ~$0.78 per 1,000 conversations.

## Challenge (10 minutes)

Add `GET /metrics?window=60` that reports only the last 60 seconds, so you can watch a load test live.

<details class="sdc-hint"><summary>Hint 1</summary>

`interactions.created_at` is set by SQLite; filter with `WHERE created_at >= datetime('now', ?)` and pass `f"-{window} seconds"`.

</details>

<details class="sdc-hint"><summary>Hint 2</summary>

Parse the query string with `urllib.parse.urlsplit(self.path)` in `do_GET` before matching the path.

</details>
