<!-- SPDX-License-Identifier: MIT -->
# Network access

Keep runner and control ports on localhost, a trusted LAN, or a VPN. Use a reverse
proxy when you need TLS, authentication, or a hostname.

Tailscale clients can usually connect directly:

```text
http://<tailscale-ip>:11434  # runner
http://<tailscale-ip>:11435  # Hearth control
```

The control endpoint requires its bearer token. Runner authentication depends on
the runner or proxy. The runner must bind to the private interface being used;
a localhost-only listener is not reachable at the Mac's Tailscale address.

## Caddy

For bearer-authenticated runner access, start with
[`deploy/Caddyfile.example`](../deploy/Caddyfile.example) or `hearth proxy-setup`.
The generated file uses explicit HTTP and binds its listener to the chosen
Tailscale address. A site hostname alone is a request matcher, not an interface
restriction; Caddy needs [`bind`](https://caddyserver.com/docs/caddyfile/directives/bind)
for that. The HTTP example relies on Tailscale encryption. Configure HTTPS for
other networks so the bearer token is encrypted in transit.

Use `caddy validate --adapter caddyfile --config Caddyfile.hearth` before starting
it. The explicit adapter is needed for this generated filename. The printed
commands quote the output path and select the runner's readiness endpoint.

The hostname examples below assume access is already restricted to a trusted
private network; they do not add runner authentication.

```caddyfile
ollama.your-tailnet.ts.net {
    reverse_proxy 127.0.0.1:11434
}

hearth.your-tailnet.ts.net {
    reverse_proxy 127.0.0.1:11435
}
```

## nginx

```nginx
server {
    listen 443 ssl;
    server_name ollama.example.internal;
    ssl_certificate /etc/ssl/ollama.crt;
    ssl_certificate_key /etc/ssl/ollama.key;

    location / {
        proxy_pass http://127.0.0.1:11434;
        proxy_buffering off;
    }
}
```

Proxy the control endpoint to `127.0.0.1:11435` and retain the bearer header.
Uptime monitors can query `GET /healthz`; it reports Hearth liveness without
runner details.

For traffic visibility through Hearth's metrics proxy, enable it and direct the
runner reverse proxy upstream to `127.0.0.1:11436` (or your configured
`metricsProxyPort`). In source after v1.5.1, `hearth proxy-setup` selects that
upstream automatically when enabled; v1.5.1 requires editing it manually. Verify
a request through the complete client path. See [recovery limits](limitations.md).

Avoid router port forwarding and public `0.0.0.0` binds. Local runner APIs and
Hearth's control server are private-network services.
