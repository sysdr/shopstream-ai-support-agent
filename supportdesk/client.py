"""Tiny HTTP client for demos and checks (standard library)."""
import json
import os
import urllib.error
import urllib.request

BASE = f"http://127.0.0.1:{os.environ.get('SUPPORTDESK_PORT', '8090')}"


def call(method, path, data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(BASE + path, data=body, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}"), dict(e.headers)


def get(path):
    return call("GET", path)


def post(path, data):
    return call("POST", path, data)


def pct(values, p):
    v = sorted(values)
    return v[min(len(v) - 1, int(len(v) * p))] if v else 0.0
