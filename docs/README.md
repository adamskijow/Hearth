<!-- SPDX-License-Identifier: MIT -->
# Hearth documentation

Start with the guide that matches what you are trying to do.

## Install and operate Hearth

- [Ollama setup](ollama.md): choose managed or attached mode and avoid competing
  process managers.
- [Configuration reference](configuration.md): every setting, default, and full
  example.
- [Running headless](running-headless.md): launch at login or run before anyone
  logs in.
- [Troubleshooting](troubleshooting.md): diagnose installation, runner, health,
  and notification problems.
- [FAQ](faq.md): plain-language product and setup answers.

## Understand the product

- [Product plan](product-plan.md): recovery correctness, setup, and local
  validation milestones.
- [How Hearth works](how-it-works.md): readiness checks, deep probes, recovery,
  and architecture.
- [Keeping Ollama running on macOS](keep-ollama-running-on-macos.md): the problem
  Hearth addresses and alternatives to try.
- [Known limitations](limitations.md): intentional boundaries and unsupported
  cases.
- [Request activity and setup](request-activity.md): pooled connections, cancellation,
  process ownership, and the observed client endpoint.
- [Stability contract](stability.md): compatibility promises for configuration,
  commands, API responses, and logs.
- [Observability](observability-roadmap.md): metrics, model-state limits, and
  remaining work.

## Connect other systems

- [Remote control and local status](remote-control.md): authenticated status and
  control endpoints.
- [Reverse proxy](reverse-proxy.md): safely expose a runner or Hearth endpoint.
- [Integrating with Hearth](integrating.md): guidance and examples for apps that
  consume Hearth state.

## Development and maintenance

- [Development](development.md): build, test, dogfood, and release workflows.
