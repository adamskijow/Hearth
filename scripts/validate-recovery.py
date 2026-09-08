#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Bounded managed recovery drills with a synthetic runner and private state.

No installed services, normal config, model cache, or global process-name signals
are used. This proves orchestration, not GPU failure behavior or job resumption.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def wait_for(predicate, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
            if result:
                return result
        except (OSError, ValueError, KeyError, IndexError):
            pass
        time.sleep(0.2)
    raise AssertionError("recovery drill condition timed out")


def gone(group):
    try:
        os.killpg(group, 0)
        return False
    except ProcessLookupError:
        return True


class Session:
    def __init__(self, binary, directory, crash=False):
        self.binary = binary
        self.work = Path(directory)
        self.config = self.work / "config.json"
        self.marker = self.work / "crash-marker"
        self.spawn_log = self.work / "spawns.jsonl"
        reservations = [socket.socket() for _ in range(3)]
        for sock in reservations:
            sock.bind(("127.0.0.1", 0))
        self.runner_port, self.control_port, self.proxy_port = [s.getsockname()[1] for s in reservations]
        self.token = "isolated-recovery-fixture"
        self.config.write_text(json.dumps({
            "mode": "managed", "host": "127.0.0.1", "port": self.runner_port,
            "ollamaBinaryPath": str(Path(__file__).resolve().with_name("fake-runner.py")),
            "runnerEnv": {"FAKE_CRASH_MARKER": str(self.marker), "FAKE_SPAWN_LOG": str(self.spawn_log)},
            "startupGraceSeconds": 2, "probeIntervalSeconds": 1, "probeTimeoutSeconds": 1,
            "probeModel": "fake-model:latest", "deepProbeIntervalSeconds": 5, "deepProbeTimeoutSeconds": 1,
            "initialBackoffSeconds": 0.5, "maxBackoffSeconds": 2,
            "crashLoopThreshold": 3, "crashLoopWindowSeconds": 30, "failingProbeIntervalSeconds": 5,
            "localNotifications": False, "controlEnabled": True, "controlHost": "127.0.0.1",
            "controlPort": self.control_port, "controlToken": self.token,
            "metricsProxyEnabled": True, "metricsProxyPort": self.proxy_port,
        }))
        self.env = dict(os.environ, HEARTH_CONFIG=str(self.config), HEARTH_DATA_DIR=str(self.work))
        self.log = (self.work / "hearth.log").open("w")
        self.groups = set()
        self.child = None
        if crash:
            self.marker.touch()
        for sock in reservations:
            sock.close()
        self.launch()

    def launch(self):
        self.child = subprocess.Popen([self.binary, "--headless"], env=self.env, stdout=self.log, stderr=self.log)

    def request(self, port, path, body=None, control=False):
        headers = {"Connection": "close"}
        if control:
            headers["Authorization"] = "Bearer " + self.token
        data = None if body is None else json.dumps(body).encode()
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, headers=headers)
        with urllib.request.urlopen(request, timeout=3) as response:
            data = response.read()
            return json.loads(data) if data else {}

    def status(self):
        assert self.child.poll() is None, "isolated Hearth exited"
        return self.request(self.control_port, "/status", control=True)

    def identity(self):
        records = json.loads((self.work / "runner-state.json").read_text())
        identity = records[-1]
        self.groups.update(record["pgid"] for record in records)
        return identity

    def verify(self):
        wait_for(lambda: self.status()["healthy"])
        self.identity()
        # Application retries are explicit. Hearth cannot resume a failed job.
        answer = wait_for(lambda: self.request(self.proxy_port, "/api/generate", {
            "model": "fake-model:latest", "prompt": "fixture", "stream": False}))
        assert answer["done"] and answer["eval_count"] > 0
        wait_for(lambda: self.status()["inferenceVerified"])

    def recovered(self, previous, started, name):
        wait_for(lambda: self.identity()["pid"] != previous["pid"])
        self.verify()
        wait_for(lambda: gone(previous["pgid"]))
        elapsed = time.monotonic() - started
        print(f"PASS: {name}; replacement, completed inference, old group gone ({elapsed:.1f}s)", flush=True)

    def close(self):
        if self.child and self.child.poll() is None:
            try:
                self.request(self.control_port, "/stop", {}, control=True)
            except OSError:
                pass
            self.child.terminate()
            try:
                self.child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=5)
        self.log.close()
        # Include fixtures that failed before a status/identity sample. Signals
        # require the same live leader and group, never just a historical PID.
        spawns = [json.loads(line) for line in self.spawn_log.read_text().splitlines()] if self.spawn_log.exists() else []
        fallback = []
        for spawn in spawns:
            self.groups.add(spawn["pgid"])
            if gone(spawn["pgid"]):
                continue
            live = subprocess.run(["/bin/ps", "-p", str(spawn["pid"]), "-o", "lstart="],
                                  capture_output=True, text=True, timeout=3)
            if live.returncode == 0 and live.stdout.strip() == spawn["started"]:
                try:
                    if os.getpgid(spawn["pid"]) == spawn["pgid"] == spawn["pid"]:
                        fallback.append(spawn["pgid"])
                        os.killpg(spawn["pgid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass
        wait_for(lambda: all(gone(group) for group in self.groups), timeout=10)
        assert not fallback, "Hearth teardown left fixture groups; emergency cleanup was required"


def run(binary):
    with tempfile.TemporaryDirectory(prefix="hearth-recovery-") as directory:
        session = Session(binary, directory)
        try:
            session.verify()
            prior = session.identity()
            started = time.monotonic()
            os.kill(prior["pid"], signal.SIGKILL)
            session.recovered(prior, started, "process exit")

            prior = session.identity()
            started = time.monotonic()
            os.kill(prior["pid"], signal.SIGUSR1)
            wait_for(lambda: session.status()["api"]["status"] == "unavailable")
            session.recovered(prior, started, "API wedge")

            prior = session.identity()
            started = time.monotonic()
            session.request(session.runner_port, "/__fake/inference-wedge/on")
            assert session.request(session.runner_port, "/api/version")["version"]
            wait_for(lambda: session.status()["inference"]["lastResult"] == "failed")
            session.recovered(prior, started, "inference-only wedge with responsive API")

            prior = session.identity()
            started = time.monotonic()
            session.child.kill()
            session.child.wait(timeout=5)
            assert not gone(prior["pgid"]), "fixture should survive abrupt supervisor exit"
            session.launch()
            session.recovered(prior, started, "supervisor crash and orphan sweep")
        finally:
            session.close()
        print("PASS: all captured managed groups absent after shutdown", flush=True)

    with tempfile.TemporaryDirectory(prefix="hearth-crash-loop-") as directory:
        session = Session(binary, directory, crash=True)
        try:
            wait_for(lambda: session.status()["phase"] == "failing")
            wait_for(lambda: session.spawn_log.exists() and len(session.spawn_log.read_text().splitlines()) >= 4)
            spawns = [json.loads(line) for line in session.spawn_log.read_text().splitlines()]
            intervals = [b["time"] - a["time"] for a, b in zip(spawns, spawns[1:])]
            assert intervals[2] >= 4.5, intervals
            assert intervals[2] > intervals[0] + 2, intervals
            session.marker.unlink()
            session.verify()
            print("PASS: crash loop enters failing, slows retries, then verifies inference after fault removal", flush=True)
        finally:
            session.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(Path(__file__).resolve().parents[1] / ".build/debug/Hearth"))
    args = parser.parse_args()
    run(str(Path(args.binary).resolve()))
