"""A fake CommyPanel for the tests: just enough of the API to deploy. Plain http on a port given as argv[1].

MODE (environment): active (default), failed (the error text tries to inject workflow commands), conflict."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("MODE", "active")
NUMBER = 5
INJECTION = "boom ::error::pwned ::set-output name=hacked::yes ::add-mask::x"


def deployment(status, finished, succeeded, error=None):
    return {
        "number": NUMBER, "status": status, "stage": "done" if finished else "build", "finished": finished,
        "succeeded": succeeded, "commit": "abc123", "commit_message": "Fix", "strategy": "rolling",
        "is_rollback": False, "error": error, "created_at": None, "finished_at": None, "url": "u",
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        if self.headers.get("Authorization") != "Bearer " + os.environ["EXPECT_TOKEN"]:
            return self.send(401, {"error": "Unauthenticated."})
        if self.path in ("/api/v1/apps/shop/deployments", "/api/v1/apps/shop/apply"):
            if MODE == "conflict":
                return self.send(409, {"error": "A deployment is already in progress.", "deployment": deployment("building", False, False)})
            return self.send(202, {"data": deployment("queued", False, False)})
        self.send(404, {"error": "Not Found"})

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + os.environ["EXPECT_TOKEN"]:
            return self.send(401, {"error": "Unauthenticated."})
        if self.path == "/api/v1/apps/shop/deployments/%d" % NUMBER:
            if MODE == "failed":
                return self.send(200, {"data": deployment("failed", True, False, INJECTION)})
            return self.send(200, {"data": deployment("active", True, True)})
        self.send(404, {"error": "Not Found"})


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
