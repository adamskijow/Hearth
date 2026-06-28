<!-- SPDX-License-Identifier: MIT -->
# Exposing the runner or the control endpoint

Hearth keeps a local LLM runner alive; it does not terminate TLS or authenticate
clients beyond the control endpoint's bearer token. To reach the runner or the
control endpoint from another machine, put it behind a private network and, if
you want HTTPS, a reverse proxy. None of this is required for local use.

## The short version

- Bind the runner (`host`/`port`) and the control endpoint (`controlHost`/
  `controlPort`) to `127.0.0.1` or a [Tailscale](https://tailscale.com) address,
  never `0.0.0.0` on the open internet.
- Over Tailscale, you often need no proxy at all: reach
  `http://<tailscale-ip>:11434` (runner) or `:11435` (control) directly. When
  Hearth detects a Tailscale address it shows the control URL in the menu.
- Add a reverse proxy only if you want TLS, a hostname, or to fold several
  services behind one port.

## Caddy

Caddy gets a certificate automatically. To serve the runner over HTTPS on your
tailnet (Caddy and Tailscale integrate, or use any hostname you control):

```caddyfile
ollama.your-tailnet.ts.net {
    reverse_proxy 127.0.0.1:11434
}

# The control endpoint. Caddy can add Basic Auth on top of Hearth's bearer token.
hearth.your-tailnet.ts.net {
    reverse_proxy 127.0.0.1:11435
}
```

## nginx

```nginx
server {
    listen 443 ssl;
    server_name ollama.example.internal;

    ssl_certificate     /etc/ssl/ollama.crt;
    ssl_certificate_key /etc/ssl/ollama.key;

    location / {
        proxy_pass http://127.0.0.1:11434;
        proxy_set_header Host $host;
        # Streaming responses: do not buffer.
        proxy_buffering off;
    }
}
```

For the control endpoint, proxy to `127.0.0.1:11435` the same way. The bearer
token still applies, so requests must carry `Authorization: Bearer <token>`.

## Liveness checks

Point an uptime monitor at the unauthenticated `GET /healthz` on the control
endpoint. It returns `200 {"status":"ok"}` when Hearth is up and reveals nothing
about the runner, so it is safe to expose to a monitor without the token:

```
curl https://hearth.your-tailnet.ts.net/healthz
```

## What not to do

- Do not bind the control endpoint to `0.0.0.0` and forward a port from your
  router. The bearer token is a control surface, not a hardened public API.
- Do not put the runner itself on the public internet. Local LLM servers are not
  built to be exposed; keep them behind the VPN and proxy.
