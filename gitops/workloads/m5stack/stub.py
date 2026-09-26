"""m5-stub: stands in for the M5Stack device so the adapter can run in the sandbox.

Implements exactly the fire-and-poll protocol in the framework's scripts/protocol.py:

    GET /api/{slug}/set?ask=<prompt>   start a turn (returns immediately)
    GET /api/{slug}/set?clear=1        reset
    GET /api/{slug}                    poll -> {connected, busy, done, timed_out, answer, route_taken}

The answer arrives over two polls - a partial, then the full text - so the
adapter's delta extraction and its streaming path are exercised, not just a
single happy-path poll. The answer names the slug and echoes the prompt's
length, never the prompt itself: nothing a client sends is reflected back.

route_taken is "stub-<slug>", so anything downstream (LiteLLM, a client) can
tell at a glance that no real device answered.

Standard library only: it runs on the stock python image with no pip install.
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SLUGS = ("llm", "route", "claude")
_lock = threading.Lock()
_state = {s: {"prompt_len": 0, "polls": 0, "active": False} for s in SLUGS}


def _reply(slug, prompt_len):
    return f"stub device ({slug}): received a {prompt_len}-character prompt."


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        if parts == ["healthz"]:
            return self._send(200, {"ok": True, "slugs": list(SLUGS)})
        if len(parts) < 2 or parts[0] != "api" or parts[1] not in SLUGS:
            return self._send(404, {"error": "unknown path"})
        slug, q = parts[1], parse_qs(url.query)

        with _lock:
            st = _state[slug]
            if len(parts) == 3 and parts[2] == "set":
                if "clear" in q:
                    st.update(prompt_len=0, polls=0, active=False)
                    return self._send(200, {"ok": True, "cleared": True})
                if "ask" in q:
                    st.update(prompt_len=len(q["ask"][0]), polls=0, active=True)
                    return self._send(200, {"ok": True, "accepted": True})
                return self._send(400, {"error": "set needs ask= or clear="})
            if len(parts) != 2:
                return self._send(404, {"error": "unknown path"})

            # Poll.
            base = {"connected": True, "timed_out": False, "route_taken": f"stub-{slug}"}
            if not st["active"]:
                return self._send(200, {**base, "busy": False, "done": False, "answer": ""})
            st["polls"] += 1
            full = _reply(slug, st["prompt_len"])
            if st["polls"] == 1:
                return self._send(200, {**base, "busy": True, "done": False,
                                        "answer": full[: len(full) // 2]})
            st["active"] = False
            return self._send(200, {**base, "busy": False, "done": True, "answer": full})

    def log_message(self, fmt, *args):  # one short line per request, no query strings
        print(f"{self.command} {urlparse(self.path).path} -> {args[1] if len(args) > 1 else ''}",
              flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
