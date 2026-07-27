"""
mitmproxy addon: logs Boosteroid-related traffic to a clean, append-only
JSON-lines file, instead of the whole noisy capture (Google Play services,
telemetry, etc.). Loaded automatically by setup.sh via `-s boosteroid_filter.py`.
mitmproxy hot-reloads this file on change, so editing it while mitmweb is
already running (e.g. mid-capture-session) takes effect immediately —
no restart needed.

Two things it captures, because the QR-login mechanism could be either:
  1. A plain HTTP request/response (logged by `response()`) — one JSON line:
     {"kind":"http", "method", "url", "request_headers", "request_body",
      "status_code", "response_headers", "response_body"}
  2. A WebSocket message (logged by `websocket_message()`) — the web client
     for this same product carries a lot of its own protocol over a raw
     WebSocket rather than REST (confirmed elsewhere in this project), so
     the TV app's QR pairing may well do the same. One JSON line per
     message:
     {"kind":"websocket", "url", "from_client", "is_text", "content"}

ALSO writes every single flow's host (regardless of match) to
all-hosts.log — a lightweight one-line-per-request list of every host
contacted. If nothing shows up in the boosteroid-capture.jsonl file, check
this one: the real API host might not literally contain "boosteroid".

Run standalone (without setup.sh) with:
  CAPTURE_FILE=/path/to/out.jsonl mitmweb -s boosteroid_filter.py
"""
import json
import os

from mitmproxy import http

CAPTURE_DIR = os.path.dirname(os.path.abspath(__file__))
CAPTURE_FILE = os.environ.get("CAPTURE_FILE", os.path.join(CAPTURE_DIR, "boosteroid-capture.jsonl"))
ALL_HOSTS_LOG = os.path.join(CAPTURE_DIR, "all-hosts.log")

# Matched case-insensitively against the host. Broadened past just
# "boosteroid" in case the API lives on a differently-branded domain (a
# separate auth/identity host, a short CDN-style name, etc.).
HOST_KEYWORDS = ("boosteroid", "bstrd")


def _is_relevant(host: str) -> bool:
    host = (host or "").lower()
    return any(kw in host for kw in HOST_KEYWORDS)


def _headers_dict(headers) -> dict:
    return {k: v for k, v in headers.items()}


def _append(record: dict) -> None:
    with open(CAPTURE_FILE, "a") as f:
        f.write(json.dumps(record) + "\n")


def response(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host or ""

    # Lightweight, unconditional log of literally everything — the escape
    # hatch for "the real host isn't what I assumed".
    try:
        with open(ALL_HOSTS_LOG, "a") as f:
            status = flow.response.status_code if flow.response else "-"
            f.write(f"{flow.request.method} {host}{flow.request.path} -> {status}\n")
    except Exception:
        pass

    if not _is_relevant(host):
        return

    try:
        request_body = flow.request.get_text(strict=False)
    except Exception:
        request_body = None
    try:
        response_body = flow.response.get_text(strict=False) if flow.response else None
    except Exception:
        response_body = None

    _append({
        "kind": "http",
        "method": flow.request.method,
        "url": flow.request.pretty_url,
        "request_headers": _headers_dict(flow.request.headers),
        "request_body": request_body,
        "status_code": flow.response.status_code if flow.response else None,
        "response_headers": _headers_dict(flow.response.headers) if flow.response else None,
        "response_body": response_body,
    })


def websocket_message(flow: http.HTTPFlow) -> None:
    host = flow.request.pretty_host or ""
    if not _is_relevant(host):
        return
    assert flow.websocket is not None
    message = flow.websocket.messages[-1]

    try:
        content = message.text if message.is_text else repr(message.content)
    except Exception:
        content = repr(message.content)

    _append({
        "kind": "websocket",
        "url": flow.request.pretty_url,
        "from_client": message.from_client,
        "is_text": message.is_text,
        "content": content,
    })
