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
import struct
import subprocess
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler
from fixture_http import FixtureHTTPServer


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
    stream_release = threading.Event()
    wire_reply = b"HTTP/1.1 200 OK\r\nX-Preserve: MiXeD value\r\nTransfer-Encoding: chunked\r\n\r\n3\r\na\x00b\r\n0\r\nX-Trailer: exact\r\n\r\n"

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
            if self.path in ("/wire", "/wire-unknown"):
                response = wire_reply if self.path == "/wire" else wire_reply.replace(b"3\r\n", b"3;opaque=yes\r\n", 1)
                self.wfile.write(response)
                self.wfile.flush()
                return
            if self.path == "/stream":
                self.send_response(200)
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                try:
                    self.wfile.write(b"1\r\nx\r\n")
                    self.wfile.flush()
                    stream_release.wait(timeout=60)
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
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
                self.reply(200, {"response": "ok", "done": True, "eval_count": 1})

    server = FixtureHTTPServer(("127.0.0.1", 0), Handler)
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
                    # An idle pool is no longer a proxy deferral. Validate recovery
                    # while the very same client socket remains open and reusable.
                    runner.set_failure(False)
                    restored = wait_for(lambda s: s.get("healthy") is True
                                        and s["recovery"]["clientActivity"]["openConnections"] >= 1)
                    assert restored["inferenceDeferredByProxy"] is False
                    assert restored["recovery"]["clientActivity"]["activeRequests"] == 0
                    assert pooled.sock is not None
                    pooled.request("GET", "/api/version")
                    assert json.loads(pooled.getresponse().read())["version"] == "validation"
                    print("PASS: completed keep-alive requests allow validated recovery with the socket open", flush=True)

                    with socket.create_connection(("127.0.0.1", proxy_port), timeout=3) as wire:
                        wire.sendall(b"GET /wire HTTP/1.1\r\nHost: fixture\r\n\r\n" * 2)
                        wire.shutdown(socket.SHUT_WR)
                        chunks = []
                        while data := wire.recv(4096):
                            chunks.append(data)
                        assert b"".join(chunks) == wire_reply * 2, repr(b"".join(chunks))
                    wait_for(lambda s: s["recovery"]["clientActivity"]["activeRequests"] == 0
                             and not s["recovery"]["clientActivity"]["uncertain"])
                    print("PASS: pipelined chunked replies, trailers, binary body, and half-close relay byte for byte", flush=True)

                    # A streaming response with silent prefill remains active beyond
                    # the busy timeout, even if no new body bytes arrive.
                    pooled.request("GET", "/stream")
                    streaming = pooled.getresponse()
                    assert streaming.read(1) == b"x"
                    deferred = wait_for(lambda s: s["inference"].get("deferredReason") == "proxyRequests")
                    posts_before = runner.post_count()
                    deadline = time.monotonic() + 35
                    while time.monotonic() < deadline:
                        state = json.loads(read("status"))
                        assert state["restartCount"] == 0 and state["busy"] is False
                        assert state["recovery"]["clientActivity"]["activeRequests"] == 1
                        assert state["recovery"]["inferenceRestartEligible"] is False
                        time.sleep(0.5)
                    assert runner.post_count() == posts_before
                    stream_release.set()
                    assert streaming.read() == b""
                    wait_for(lambda s: runner.post_count() > posts_before and s.get("inferenceVerified") is True)
                    print("PASS: silent streaming work blocks probes beyond busy timeout; final framing releases it", flush=True)

                    stream_release.clear()
                    pooled.request("GET", "/stream")
                    streaming = pooled.getresponse()
                    assert streaming.read(1) == b"x"
                    wait_for(lambda s: s["recovery"]["clientActivity"]["activeRequests"] == 1)
                    # Force an actual reset, not a legal request-side half-close.
                    pooled.sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                    pooled.close()
                    streaming.close()
                    pooled = None
                    uncertain = wait_for(lambda s: s["recovery"]["clientActivity"]["uncertain"] is True)
                    assert uncertain["inference"]["deferredReason"] == "trafficUnknown"
                    assert b"hearth_proxy_activity_uncertain 1\n" in read("metrics")
                    assert uncertain["recovery"]["trafficVisibility"] == "partial"
                    stream_release.set()
                    with socket.create_connection(("127.0.0.1", proxy_port), timeout=3) as wire:
                        wire.sendall(b"GET /wire-unknown HTTP/1.1\r\nHost: fixture\r\n\r\n")
                        wire.shutdown(socket.SHUT_WR)
                        chunks = []
                        while data := wire.recv(4096):
                            chunks.append(data)
                        assert b"".join(chunks) == wire_reply.replace(b"3\r\n", b"3;opaque=yes\r\n", 1)
                    print("PASS: unsupported framing still forwards every byte unchanged", flush=True)
                    print("PASS: cancellation preserves unsettled activity; direct traffic remains explicitly partial", flush=True)
                finally:
                    stream_release.set()
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
