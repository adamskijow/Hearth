<!-- SPDX-License-Identifier: MIT -->
# Request activity and client setup

September 7, 2026. Source changes after v1.5.1; no new binary release.

## Decision and scope

Hearth now observes HTTP request/response framing inside its existing TCP relay.
An open keep-alive connection with completed requests no longer suppresses
inference checks. A request becomes active on its first byte and stays active
until its complete response is observed, including silent prefill and streaming.
This measures outstanding HTTP work, not token progress or whether a model is hung.

Ollama's [running-model endpoint](https://docs.ollama.com/api/ps) provides residency,
not authoritative per-request completion. Hearth therefore retains native
residency evidence for probe eligibility and uses passive framing for proxied
activity. Framing follows [HTTP/1.1 message rules](https://www.rfc-editor.org/rfc/rfc9112.html),
with a deliberately limited supported subset. No timeout or missing token is
used to declare a request finished.

Supported observation includes HTTP/1.0 and HTTP/1.1, fixed-length and ordinary
chunked bodies, trailers, FIFO pipelining, interim responses, HEAD/204/304 bodyless
responses, and close-delimited responses ending at clean upstream EOF. A client
write-half-close keeps the response relay alive. A real socket regression caught
connection-state failure arriving before buffered responses and EOF; the relay
now lets I/O callbacks drain those bytes. A single stream send context preserves
ordering through the final write-close, following Apple's
[send semantics](https://developer.apple.com/documentation/network/nwconnection/contentcontext/defaultstream). Header/trailer storage is capped
at 64 KiB per direction, individual lines at 8 KiB, and pending requests at 32 per
connection. Body bytes are not retained by the activity observer. The existing
throughput scanner remains best effort and now handles integer overflow safely.

Malformed or unsupported framing makes activity unknown. Examples include
ambiguous lengths, duplicate Content-Length, Transfer-Encoding plus Content-Length,
chunk extensions, unsupported transfer codings, CONNECT, upgrades, HTTP/2, and
TLS sent directly to the relay. This never rewrites or rejects the stream: bytes
continue unchanged while inference checks and automatic inference recovery defer.
The existing listener does not impose a global connection cap.

## Cancellation and process ownership

Disconnecting a client does not prove its server work stopped. Interrupted work
therefore remains uncertain after socket closure and across listener/config
reloads in the same Hearth process. Unrelated successful requests cannot clear it.

Managed requests belong to a process generation. Hearth synchronously cancels
old relays during teardown, records a process-group absence witness before
termination, and starts a separate generation before replacement spawn. Sending
SIGTERM, reaping only the leader, or a replacement child's failed bind is not
proof that the preceding server stopped. Every ended generation blocks until
its group is confirmed absent, including a previously idle server that could
still receive requests while the replacement starts. Confirmation clears only
that generation's uncertainty; it never discards the new runner's requests.

Work without known ownership or termination proof remains uncertain for the
Hearth session. Attached mode cannot clear this from an external restart it did
not observe. Retention is capped at 64 unresolved generations; overflow remains
conservatively unknown. Activity state is memory-only, so relaunch begins a new
observation session, not retrospective proof of earlier completion.

## Status and setup

`recovery.clientActivity` adds `available`, `openConnections`, `activeRequests`,
`uncertain`, and `observedRequest`. Counts describe the latest supervision
snapshot. `traffic` can be `observedRequests`; old enum values remain accepted.
`proxyRequests`, `trafficUnknown`, and `proxyUnavailable` distinguish deferrals.
The legacy `inferenceDeferredByProxy` summary now covers those conditions rather
than treating idle sockets as work. Optional `trafficNotice` is shared display
text. Metrics add `hearth_proxy_active_requests`, `hearth_proxy_open_connections`,
and `hearth_proxy_activity_uncertain`.

Visibility is always **partial**. Direct requests to the runner bypass Hearth,
and observing one client does not establish complete routing. Automatic inference
recovery still requires a managed runner, observed client requests, no known
active/uncertain traffic, native residency evidence, and confirmed inference
failure. Process/API recovery and explicit operator restart retain their existing
policies; routine maintenance draining remains bounded by `drainSeconds`.

Preferences now separates Runner, Health, Alerts, Access, and Advanced settings.
Health groups model selection, an explicit inference test, and the copyable
client endpoint. Choose the workload model; Hearth no longer automatically
selects the smallest catalog entry. The explicit test may load that model and
must validate a finished completion. Save endpoint changes before testing.
Scheduled checks still never cold-load an idle model.

The copied endpoint and generated `hearth proxy-setup` Caddy upstream use
`metricsProxyPort` when observation is enabled, otherwise the runner port.
Welcome distinguishes finding a binary from verifying health, explains attached
ownership, and opens Preferences as its primary action. Status notices wrap in
the menu instead of stretching it indefinitely. Control tokens are masked.

## Validation and remaining work

`python3 scripts/validate-inference.py`, also run by the shared CI gate, exercises
a temporary headless instance
with real HTTP clients: pooled reuse, a silent chunked stream beyond the busy
timeout, cancellation, pipelining, trailers, binary body bytes, half-close, and
unchanged forwarding of unsupported framing. Unit tests cover fragmented input,
malformed messages, stale-generation clearing, and a stopped real process whose
termination witness stays false until its group is gone.

Native offscreen renders were inspected at the Preferences window size in light
and dark appearances. Live keyboard/menu interaction could not be checked because
the development Mac was locked. The full clean-setup matrix, controlled workload
drills, and bounded 72-hour run remain the next milestones in the
[product plan](product-plan.md); no recruitment is required.
