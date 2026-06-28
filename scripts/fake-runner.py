#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# A stand in for `ollama serve`, for trying Hearth without installing Ollama.
# It reads OLLAMA_HOST (host:port) the same way Ollama does, answers the two
# endpoints Hearth probes (/api/version and /api/ps), and runs until killed.
# It does no inference; it exists only to be supervised.
#
# Point a Hearth config at this file as the runner binary:
#   "ollamaBinaryPath": "/absolute/path/to/scripts/fake-runner.py"
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

host_port = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")
host, _, port = host_port.partition(":")
port = int(port or "11434")

sys.stderr.write(f"fake-runner: serving on {host}:{port} (argv={sys.argv[1:]})\n")
sys.stderr.flush()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/api/version":
            body = json.dumps({"version": "fake-0.1"}).encode()
        elif self.path == "/api/ps":
            body = json.dumps({
                "models": [{
                    "name": "fake-model:latest",
                    "model": "fake-model:latest",
                    "size": 1234567890,
                    "expires_at": "2026-06-27T13:00:00.000Z",
                }]
            }).encode()
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer((host, port), Handler).serve_forever()
