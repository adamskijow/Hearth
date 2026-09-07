<!-- SPDX-License-Identifier: MIT -->
# Hearth privacy policy

Updated September 7, 2026 to describe full Hearth and the retirement of
standalone Hearth Monitor.

## Full Hearth

Hearth has no developer account, analytics, advertising, or tracking service.
It stores configuration, process identity, event history, system metrics, and
runner logs locally. Configuration can contain notification addresses and
control tokens. Runner logs may contain paths, model names, and request text
produced by the runner.

Default data locations are:

```text
~/Library/Application Support/Hearth
~/Library/Logs/Hearth
```

Headless root installations use their configured paths, including
`/etc/hearth/config.json` and `/var/log/hearth.out.log` and
`/var/log/hearth.err.log`. `HEARTH_CONFIG` and `HEARTH_DATA_DIR` can override
user-instance locations.

Hearth sends health, model-list, and optional fixed inference requests to the
runner you configure. The optional metrics proxy relays client requests and
responses to that runner and reads runner-reported timing and token counts.
The proxy does not save request or response bodies. A remote runner receives
traffic at the address you choose; its data handling is outside Hearth.

## Optional connections and sharing

- Configured ntfy and webhook destinations receive status alerts. The default
  ntfy server is public `ntfy.sh`; ntfy remains disabled until a topic is set.
- `alertsIncludeLogTail` is off by default. Enabling it adds up to five sanitized
  runner-log lines to failure alerts sent through configured notification
  channels. These lines can contain paths, model names, or request fragments.
- A configured heartbeat URL receives periodic requests while the supervisor
  reports healthy.
- The optional control endpoint shares status and metrics with authenticated
  clients. Full-control tokens also authorize process commands. Status can
  include model names and recent events; Prometheus labels omit model names.
- The `hearth update` command invokes Homebrew when requested. Runner startup
  may download models according to that runner's configuration.

Connections go directly to the selected services; the developer does not relay
them. Those services can observe requests and network addresses. Review copied
diagnostics and logs before sharing them through GitHub or another service.

## Retired Hearth Monitor

Standalone Hearth Monitor was retired on September 7, 2026. This description
remains applicable to the historical beta.

The beta has no analytics, advertising, tracking, developer account, or
crash-reporting service. Its sandbox stores settings, runner addresses, check
timing, recent latency samples, and up to 500 confirmed incidents. Runner
credentials and optional full Hearth status tokens use separate Keychain items.

Monitor connects directly to configured runner and full Hearth endpoints for
health, model-list, optional fixed inference, and authenticated status requests.
Redirects are refused. Copied diagnostics and incident history exclude
credentials, prompts, model responses, and response bodies.

Apple on-device functional checks request one fixed response through Foundation
Models when enabled by the user. The prompt and response are discarded. Retained
data is limited to timing, health, broad failure categories, and incidents.
Checks pause during sleep, Low Power Mode, and serious thermal pressure.

## Delete data

For full Hearth, stop supervision and remove any installed agent or daemon before
removing its configuration and logs. See [uninstallation](docs/faq.md#how-do-i-uninstall-it)
and [headless operation](docs/running-headless.md). Runner applications and their
model data are managed separately.

For Monitor, remove configured runners and connections to delete associated
Keychain items, disable Open at Login, then quit the app and delete:

```text
~/Library/Containers/com.hearth.HearthMonitor
```

Full instructions are in [Monitor retirement and removal](docs/hearth-monitor.md#remove-monitor).

## Contact

Privacy questions can be filed through the
[support tracker](https://github.com/adamskijow/Hearth/issues). Report sensitive
security information through [private reporting](SECURITY.md#reporting-a-vulnerability).
Material changes to this policy will update this page and its date.
