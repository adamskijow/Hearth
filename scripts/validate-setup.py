#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check CLI setup admission against isolated HTTP fixtures; never install agents."""
import argparse
import json
import os
from pathlib import Path
import socket
import shlex
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler
from fixture_http import FixtureHTTPServer


def run(binary):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.respond(200, {"version": "fixture"} if self.path == "/api/version" else {})

        def do_POST(self):
            data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if data.get("model") == "missing":
                self.respond(404, {"error": "missing model"})
            else:
                self.respond(200, {"done": True, "eval_count": 1})

    def unexpected_lookup(*_args):
        raise AssertionError("A numeric loopback fixture must not depend on reverse DNS")

    lookup = socket.getfqdn
    socket.getfqdn = unexpected_lookup
    try:
        server = FixtureHTTPServer(("127.0.0.1", 0), Handler)
    finally:
        socket.getfqdn = lookup
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    wrong = socket.socket()
    wrong.bind(("127.0.0.1", 0))  # Reserved but deliberately not listening.
    try:
        with tempfile.TemporaryDirectory(prefix="hearth-setup-") as directory:
            work = Path(directory)
            config = work / "config.json"
            env = dict(os.environ, HEARTH_CONFIG=str(config), HEARTH_DATA_DIR=str(work))

            def check(value, expected, phrase, extra=()):
                if value is None:
                    config.unlink(missing_ok=True)
                else:
                    config.write_text(value if isinstance(value, str) else json.dumps(value))
                before = config.read_bytes() if config.exists() else None
                result = subprocess.run([binary, "setup", "--check", *extra], env=env, text=True,
                                        capture_output=True, timeout=15)
                assert result.returncode == expected, result.stdout + result.stderr
                assert phrase in result.stdout + result.stderr, result.stdout + result.stderr
                assert (config.read_bytes() if config.exists() else None) == before

            base = {"mode": "attached", "host": "127.0.0.1", "port": server.server_port}
            check(None, 1, "No configuration exists")
            check("{broken", 1, "Setup stopped")
            check(dict(base, host="localhost/path"), 1, "not a valid hostname")
            check(dict(base, port=wrong.getsockname()[1]), 1, "not answering")
            check(dict(base, runner="mlx", mode="managed"), 1, "requires mlxModel")
            check(dict(base, ollamaBinaryPath="/missing/executable"), 0, "attached observation",
                  ("--model", "fixture"))
            check(base, 0, "Inference has not been tested")
            check(base, 1, "404", ("--model", "missing"))
            check(dict(base, metricsProxyEnabled=True, metricsProxyPort=wrong.getsockname()[1]),
                  1, "client endpoint")
            print("PASS: missing/malformed config, invalid host, wrong client port, MLX model admission, attached inference, unavailable model, and unchanged config bytes", flush=True)

            # Unknown HTTP 200 is not proof of a compatible runner API.
            original = Handler.do_GET
            Handler.do_GET = lambda self: self.respond(200, {})
            try:
                check(base, 1, "not answering")
            finally:
                Handler.do_GET = original

            config.write_text("{broken")
            result = subprocess.run([binary, "proxy-setup", "--output", directory], env=env,
                                    text=True, capture_output=True, timeout=10)
            assert result.returncode == 1 and not (work / "Caddyfile.hearth").exists()
            assert config.read_text() == "{broken"
            config.unlink()
            result = subprocess.run([binary, "proxy-setup", "--output", directory], env=env,
                                    text=True, capture_output=True, timeout=10)
            assert result.returncode == 1 and not config.exists()
            print("PASS: unrelated HTTP 200 rejected; proxy setup preserves malformed/missing config", flush=True)
            output = work / "a folder's configs"
            output.mkdir()
            output.chmod(0o755)
            config.write_text(json.dumps(dict(base, runner="mlx", mode="attached")))
            generated = subprocess.run([binary, "proxy-setup", "--output", str(output)], env=env,
                                       text=True, capture_output=True, timeout=10)
            assert generated.returncode == 0, generated.stderr
            assert "/v1/models" in generated.stdout
            for line in generated.stdout.splitlines():
                if line.strip().startswith(("caddy validate", "caddy run")):
                    assert shlex.split(line)[-1] == str(output / "Caddyfile.hearth"), line
            assert (output / "Caddyfile.hearth").stat().st_mode & 0o777 == 0o600
            assert output.stat().st_mode & 0o777 == 0o755
            print("PASS: generated commands quote paths, use selected adapter endpoint, and protect the token file", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        wrong.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=str(Path(__file__).resolve().parents[1] / ".build/debug/Hearth"))
    run(str(Path(parser.parse_args().binary).resolve()))
