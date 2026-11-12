"""Failure injection and retries.

FaultInjector makes the model call or a tool call fail with probability
FAULT_RATE: a timeout or a dropped connection before the call, or a lost
response AFTER the tool already ran (the nasty one: the refund happened but
we don't know). retry() retries transient errors with exponential backoff and
full jitter inside a total time budget.
"""
import os
import random
import time

TRANSIENT = (TimeoutError, ConnectionError)


class RetryBudgetExceeded(Exception):
    def __init__(self, last_error, attempts):
        super().__init__(f"gave up after {attempts} attempts: {last_error}")
        self.last_error, self.attempts = last_error, attempts


class FaultInjector:
    def __init__(self, rate=None, seed=None):
        self.rate = float(os.environ.get("FAULT_RATE", "0") if rate is None else rate)
        self.rng = random.Random(seed if seed is not None else int(os.environ.get("FAULT_SEED", "7")))
        self.injected = 0

    def roll(self):
        """None (no fault), "before" (timeout or refused) or "after" (response lost)."""
        if not self.rate or self.rng.random() >= self.rate:
            return None
        self.injected += 1
        return self.rng.choice(["before", "before", "after"])

    def maybe(self, where):
        """For the model call: fail before it with probability rate."""
        if self.roll():
            raise (TimeoutError if self.rng.random() < 0.5 else ConnectionError)(f"injected failure at {where}")


def retry(fn, attempts=4, base=0.02, cap=0.25, budget_s=2.0, rng=None, sleep=time.sleep, on_retry=None):
    """Call fn(); on a transient error wait random(0, min(cap, base * 2**n)) and try again."""
    rng = rng or random.Random()
    deadline = time.monotonic() + budget_s
    last = None
    for n in range(attempts):
        try:
            return fn()
        except TRANSIENT as e:
            last = e
            if n == attempts - 1:
                break
            delay = rng.uniform(0, min(cap, base * 2 ** n))
            if time.monotonic() + delay > deadline:
                break
            if on_retry:
                on_retry(e)
            sleep(delay)
    raise RetryBudgetExceeded(last, n + 1)
