#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# A stand in for `ollama serve`, for trying Hearth without installing Ollama and
# for the wedge-recovery demo. It reads OLLAMA_HOST (host:port) the same way Ollama
# does, answers the two endpoints Hearth probes (/api/version and /api/ps), and
# runs until killed. It does no inference; it exists only to be supervised.
#
# Send it SIGUSR1 to WEDGE it: the process stays alive and the socket stays open,
# but it stops answering. That is the alive-but-wedged failure a liveness check
# (launchd KeepAlive, systemd) misses and Hearth's readiness probe catches. SIGUSR2
# un-wedges it (Hearth normally recovers by killing and respawning a fresh one).
#
# Point a Hearth config at this file as the runner binary:
#   "ollamaBinaryPath": "/absolute/path/to/scripts/fake-runner.py"
import json
import os
import signal
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

host_port = os.environ.get("OLLAMA_HOST", "127.0.0.1:11434")
host, _, port = host_port.partition(":")
port = int(port or "11434")

wedged = False


def _wedge(_signum, _frame):
    global wedged
    wedged = True
    sys.stderr.write("fake-runner: WEDGED (alive, no longer answering)\n")
    sys.stderr.flush()


def _unwedge(_signum, _frame):
    global wedged
    wedged = False
    sys.stderr.write("fake-runner: unwedged (answering again)\n")
    sys.stderr.flush()


signal.signal(signal.SIGUSR1, _wedge)
signal.signal(signal.SIGUSR2, _unwedge)

sys.stderr.write(f"fake-runner: serving on {host}:{port} (argv={sys.argv[1:]})\n")
sys.stderr.flush()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        # When wedged, hang well past any readiness timeout: the process is alive
        # and still accepting connections, but the probe never gets a response.
        if wedged:
            time.sleep(600)
            return
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
        elif self.path == "/api/tags":
            body = json.dumps({
                "models": [{
                    "name": "fake-model:latest",
                    "model": "fake-model:latest",
                    "size": 1234567890,
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

    def do_POST(self):
        # Inference endpoints. The "inference wedge" (FAKE_INFERENCE_WEDGE set, or a
        # full wedge) hangs here while /api/version keeps answering above, the exact
        # case a shallow readiness probe misses: the HTTP server is fine, but the
        # model runner is deadlocked.
        if wedged or os.environ.get("FAKE_INFERENCE_WEDGE"):
            time.sleep(600)
            return
        body = json.dumps({"model": "fake-model:latest", "response": "ok", "done": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


# Threaded so a wedged (hanging) request never blocks the accept loop: the process
# keeps accepting connections, it just never answers.
ThreadingHTTPServer((host, port), Handler).serve_forever()
