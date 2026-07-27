"""
mitmproxy addon: logs only requests whose host mentions "boosteroid" to a
clean, append-only JSON-lines file, instead of the whole noisy capture
(Google Play services, telemetry, etc.). Loaded automatically by setup.sh via
`-s boosteroid_filter.py`.

Each line is one request/response pair:
  {"method", "url", "request_headers", "request_body", "status_code",
   "response_headers", "response_body"}

Run standalone (without setup.sh) with:
  CAPTURE_FILE=/path/to/out.jsonl mitmweb -s boosteroid_filter.py
"""
import json
import os

from mitmproxy import http

CAPTURE_FILE = os.environ.get(
    "CAPTURE_FILE",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "boosteroid-capture.jsonl"),
)


def _headers_dict(headers) -> dict:
    return {k: v for k, v in headers.items()}


def response(flow: http.HTTPFlow) -> None:
    host = (flow.request.pretty_host or "").lower()
    if "boosteroid" not in host:
        return

    try:
        request_body = flow.request.get_text(strict=False)
    except Exception:
        request_body = None
    try:
        response_body = flow.response.get_text(strict=False) if flow.response else None
    except Exception:
        response_body = None

    record = {
        "method": flow.request.method,
        "url": flow.request.pretty_url,
        "request_headers": _headers_dict(flow.request.headers),
        "request_body": request_body,
        "status_code": flow.response.status_code if flow.response else None,
        "response_headers": _headers_dict(flow.response.headers) if flow.response else None,
        "response_body": response_body,
    }

    with open(CAPTURE_FILE, "a") as f:
        f.write(json.dumps(record) + "\n")
