## Why tools need contracts

On Day 1 the dispatcher ran SQL directly. That is fine while the only caller is your own regex. From Day 3 on, the caller is a model, and a model will eventually send `{"order_id": 1005}` (a number), `"ORD-1"` (half an id), an amount of `-40`, or a tool name it invented. In production the cheapest place to stop that is the boundary between "the model decided" and "the database changed". This lesson builds that boundary: a **tool registry** where every tool declares its arguments and its result, and nothing runs until both check out.

## What you build

`supportdesk/tools.py` adds three things to the project:

- **A small schema validator.** A subset of JSON Schema that the standard library can check in a few lines: `type`, `required`, `enum`, `minimum`/`maximum`, `pattern` and `maxLength`, plus "no extra fields". A failure raises `ToolValidationError` with the **field name**, so the caller (and later the model) knows exactly what to fix.
- **Three tools.** `get_order_status(order_id)` returns status, item, dates and price. `check_stock(product)` returns stock and price. `process_refund(order_id, amount, reason, idempotency_key)` writes to a new `refunds` table.
- **An audit trail.** Every call, good or bad, becomes a row in `tool_calls`: tool, arguments, ok, error, latency.

The registry is the only door:

```python
def call(self, name, args):
    tool = self.tools[name]            # unknown tool -> ToolValidationError("tool", ...)
    validate(tool.params, args)        # BEFORE: arguments
    result = tool.fn(self.db_path, **args)
    validate(tool.returns, result, where="result")   # AFTER: the tool's own output
    return result
```

Validating the result too sounds paranoid until a schema migration renames a column and your agent starts telling customers their order is `None`.

The HTTP API gets `GET /tools` (names and argument schemas) and `POST /tools/NAME`. Bad arguments return **400** with the field; arguments that are valid but break a business rule (refunding an order that hasn't shipped) return **422**. The Day 1 `/chat` endpoint keeps working, now going through the same tools.

## Refunds must be safe to repeat

`process_refund` takes an `idempotency_key`. The first call with a key creates a refund; any later call with the same key returns the first result with `"duplicate": true` and changes nothing. The key has a `UNIQUE` constraint in SQLite, so even two threads racing can't both insert.

Why now, before there is any retry logic? Because the client that calls you will retry whether or not you planned for it: a mobile app on a train, a load balancer that times out at 30 s, and from Day 5 our own retry loop. Idempotency has to be a property of the tool, not a promise from the caller.

The tool also enforces money rules that no schema can express: only shipped or delivered orders can be refunded, and the total refunded for an order can never exceed the item's price. We'll see that second rule catch a real bug on Day 3.

## Measure it

`start.sh` runs the unit tests (11), starts the server and fires 40 tool calls through HTTP: 15 order lookups, 10 stock checks, 5 refunds of which 2 are deliberate retries, and 10 bad calls. From our run:

```text
  400  get_order_status   order_id: is required
  400  get_order_status   order_id: must be string
  400  get_order_status   order_id: must match ORD-\d{4}
  400  get_order_status   verbose: is not an allowed field
  400  check_stock        product: must be at most 80 characters
  400  process_refund     amount: must be >= 0.01
  400  process_refund     reason: must be one of [...]
  400  process_refund     idempotency_key: is required
  422  process_refund     order ORD-1003 is placed; only shipped or delivered orders can be refunded
  400  delete_all_orders  tool: unknown tool 'delete_all_orders'
Accepted (200)             : 30
Rejected by schema (400)   : 9
Refused by business rule (422): 1
Refunds created            : 3 (5 refund calls, 2 were retries)
Duplicate refunds prevented: 2
Latency p50 / p99          : 1.52 / 8.32 ms
```

Every bad call was stopped with a message that names the problem, the two retries didn't move money, and validation added well under a millisecond. The audit table now holds a row for every one of those calls, including the rejected ones, which is what you will want the first time someone asks "did the bot really try to refund that?"

## Design choices worth defending

- **Allow-list, not block-list.** Unknown fields are rejected. If the model starts sending `{"order_id": ..., "force": true}`, you want a 400, not a silently ignored flag.
- **Two error types.** 400 means "fix your input", 422 means "the input is fine, the answer is no". Agents (and humans) handle them differently: one is retried with corrected arguments, the other is explained to the customer.
- **Patterns at the edge.** `order_id` must match `ORD-\d{4}` before it reaches SQL. Parameterised queries already stop injection; the pattern stops nonsense from becoming a slow query or a confusing "not found".

## What we measured

| Metric | Result |
| :--- | :--- |
| Calls / accepted / 400 / 422 | 40 / 30 / 9 / 1 |
| Refunds created vs refund calls | 3 of 5 (2 retries deduplicated) |
| p50 / p99 latency over HTTP | 1.52 ms / 8.32 ms |
| Unit tests | 11 passing |

## Say it in an interview

**Q: An LLM agent can call your refund API. What do you put between them?**
A tool layer with explicit schemas: validate types, enums, ranges and patterns before execution, validate the result after, reject unknown fields and unknown tools, and log every call. Business rules (only shipped orders, never more than the price) live in the tool, not in the prompt.

**Q: How do you make a refund endpoint safe to retry?**
Require an idempotency key, store it with a unique constraint in the same transaction as the refund, and return the original result for a repeated key. In our demo, 5 refund calls with 2 retries created exactly 3 refunds.

**Q: Why validate the tool's output?**
Because the output becomes the model's input. A changed schema or a NULL column would otherwise turn into a confident wrong answer; validating the result turns it into a clear error at the boundary.

## Recap

- Every tool declares argument and result schemas; the registry validates both and audits every call.
- 400 for bad input (with the field name), 422 for valid input the business rules refuse.
- Refunds are idempotent by key and capped at the item price.
- Validation costs well under a millisecond; it stopped 10 of 10 bad calls in the demo.

## Challenge (10 minutes)

Add a `cancel_order(order_id, idempotency_key)` tool: only `placed` orders can be cancelled, it sets the status to `cancelled`, and calling it twice with the same key returns the first result.

<details class="sdc-hint"><summary>Hint 1</summary>

Copy the shape of `process_refund`: a `cancellations` table with a UNIQUE `idempotency_key`, checked first, then the status rule, then the write.

</details>

<details class="sdc-hint"><summary>Hint 2</summary>

Register it with an argument schema that reuses `ORDER_ID` and the same key pattern, and a result schema with `order_id`, `status` and `duplicate`. Add a unit test that cancels a `placed` order twice and a `shipped` one once (expect `ToolExecutionError`).

</details>
