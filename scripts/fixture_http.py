# SPDX-License-Identifier: MIT
"""HTTP fixtures bind numeric addresses without startup-time reverse DNS."""
from http.server import ThreadingHTTPServer
from socketserver import TCPServer


class FixtureHTTPServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer.server_bind calls getfqdn before TCPServer calls listen.
        # A slow hosted DNS resolver would prevent an otherwise local fixture
        # from listening and make managed startup look like a runner failure.
        TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]
