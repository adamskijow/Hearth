#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Exercise inference status and a pooled HTTP connection in an isolated Hearth.

Requires a built Hearth executable. Uses a fake runner, loopback ports, and
temporary configuration/data; never touches an installed runner or service.
"""

import argparse
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Runner:
    def __init__(self):
        self.lock = threading.Lock()
        self.failing = False
        self.posts = 0
        self.heartbeats = 0

    def set_failure(self, failing):
        with self.lock:
            self.failing = failing

    def post(self):
        with self.lock:
            self.posts += 1
            return self.failing

    def post_count(self):
        with self.lock:
            return self.posts

    def heartbeat(self):
        with self.lock:
            self.heartbeats += 1

    def heartbeat_count(self):
        with self.lock:
            return self.heartbeats


def run(binary):
    runner = Runner()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def reply(self, code, value):
            body = json.dumps(value).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/api/version":
                self.reply(200, {"version": "validation"})
            elif self.path == "/api/ps":
                self.reply(200, {"models": [{"name": "validation:tiny", "size": 42}]})
            elif self.path == "/heartbeat":
                runner.heartbeat()
                self.reply(200, {})
            else:
                self.reply(404, {})

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if runner.post():
                self.reply(500, {"error": "controlled inference failure"})
            else:
                self.reply(200, {"response": "ok", "done": True})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    reservations = [socket.socket() for _ in range(2)]
    for sock in reservations:
        sock.bind(("127.0.0.1", 0))
    control_port, proxy_port = [sock.getsockname()[1] for sock in reservations]
    child = None
    pooled = None
    token = "isolated-validation"

    def read(path):
        request = urllib.request.Request(
            f"http://127.0.0.1:{control_port}/{path}",
            headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(request, timeout=3) as response:
            return response.read()

    def wait_for(predicate, timeout=25):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise AssertionError("isolated Hearth exited unexpectedly")
            try:
                state = json.loads(read("status"))
                if predicate(state):
                    return state
            except (OSError, ValueError):
                pass
            time.sleep(0.2)
        raise AssertionError("expected inference state was not observed before the deadline")

    try:
        with tempfile.TemporaryDirectory(prefix="hearth-inference-") as directory:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({
                "mode": "attached", "host": "127.0.0.1", "port": server.server_port,
                "probeIntervalSeconds": 5, "probeTimeoutSeconds": 1,
                "probeModel": "validation:tiny", "deepProbeIntervalSeconds": 5,
                "deepProbeTimeoutSeconds": 1, "busyTimeoutSeconds": 30,
                "localNotifications": False, "controlEnabled": True,
                "controlHost": "127.0.0.1", "controlPort": control_port,
                "controlToken": token, "metricsProxyEnabled": True,
                "metricsProxyPort": proxy_port,
                "heartbeatURL": f"http://127.0.0.1:{server.server_port}/heartbeat",
                "heartbeatIntervalSeconds": 10,
            }))
            env = dict(os.environ, HEARTH_CONFIG=str(config), HEARTH_DATA_DIR=directory)
            for sock in reservations:
                sock.close()
            with (Path(directory) / "hearth.log").open("w") as log:
                child = subprocess.Popen([str(binary), "--headless"], env=env, stdout=log, stderr=log)
                try:
                    wait_for(lambda s: s.get("healthy") is True and runner.post_count() > 0
                             and runner.heartbeat_count() > 0)
                    runner.set_failure(True)
                    failed = wait_for(lambda s: s.get("inferenceRecoveryWithheld") is True)
                    assert failed["phase"] == "healthy" and failed["healthy"] is False
                    assert failed["headline"] == "Inference check failed"
                    assert b"hearth_healthy 0\n" in read("metrics")
                    cli = subprocess.check_output([str(binary), "status", "--json"], env=env, timeout=10)
                    assert json.loads(cli)["healthy"] is False
                    prose = subprocess.check_output([str(binary), "status"], env=env, timeout=10)
                    assert b"Inference check failed" in prose
                    print("PASS: API, CLI, and metrics retain the inference failure", flush=True)

                    pooled = http.client.HTTPConnection("127.0.0.1", proxy_port, timeout=3)
                    pooled.request("GET", "/api/version")
                    assert json.loads(pooled.getresponse().read())["version"] == "validation"
                    assert pooled.sock is not None  # complete response; connection remains open
                    deferred = wait_for(lambda s: s.get("inferenceDeferredByProxy") is True)
                    assert deferred["busy"] is False and deferred["healthy"] is False
                    runner.set_failure(False)
                    posts_before = runner.post_count()
                    heartbeats_before = runner.heartbeat_count()
                    # More than the configured busy timeout, with each poll deep-due.
                    deadline = time.monotonic() + 35
                    while time.monotonic() < deadline:
                        state = json.loads(read("status"))
                        assert state["restartCount"] == 0
                        assert state["inferenceRecoveryWithheld"] is True
                        assert state["busy"] is False
                        time.sleep(0.5)
                    assert runner.post_count() == posts_before
                    assert runner.heartbeat_count() == heartbeats_before
                    pooled.request("GET", "/api/version")
                    assert json.loads(pooled.getresponse().read())["version"] == "validation"
                    print("PASS: idle pooled HTTP connection defers checks without busy-timeout recovery", flush=True)
                    pooled.close()
                    pooled = None

                    restored = wait_for(lambda s: s.get("healthy") is True
                                        and runner.heartbeat_count() > heartbeats_before)
                    assert restored["inferenceRecoveryWithheld"] is False
                    assert restored["inferenceDeferredByProxy"] is False
                    assert runner.post_count() > posts_before
                    assert b"hearth_healthy 1\n" in read("metrics")
                    print("PASS: successful inference clears the incident after the connection closes", flush=True)
                    print("PASS: heartbeat pauses during the incident and resumes after inference succeeds", flush=True)
                finally:
                    if pooled is not None:
                        pooled.close()
                    child.terminate()
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=5)
    finally:
        for sock in reservations:
            sock.close()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=".build/debug/Hearth", type=Path)
    arguments = parser.parse_args()
    binary = arguments.binary.resolve()
    if not binary.is_file():
        parser.error("build Hearth first, or pass --binary")
    run(binary)
