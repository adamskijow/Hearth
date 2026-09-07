<!-- SPDX-License-Identifier: MIT -->
# Stability contract

Hearth follows semantic versioning for the surfaces below. Removing or renaming a
stable item requires a major version. Deprecations retain compatibility for at
least one minor release with a `hearth doctor` warning.

## Config file

Config keys are stable. New keys may be added in minor releases; existing keys
keep their names, types, and defaults through 1.x.

Config files travel across versions:

- Unknown keys produce doctor and menu warnings.
- Unknown `runner` or `mode` values block activation.
- A missing key means its documented default.

## Command line

The subcommand names (`status`, `logs`, `events`, `metrics`, `doctor`,
`doctor-daemon`, `mode`, `wait-ready`, `update`, `proxy-setup`, `setup`,
`install-agent`, `uninstall-agent`) and their documented flags are stable. Exit
code 0 means success, 1 means an operational failure, and 2 means invalid usage
or a configuration that Hearth refused to apply.

CLI prose may change. Scripts should use `/status` or `hearth status --json`.

## Control API

`GET /status` field names are stable and additive-only: `phase`, `runner`, `mode`,
`busy`, `models`, `uptimeSeconds`, `restartCount`, `consecutiveFailures`,
`lastRestartReason`, `lastDownCategory`, `lastRestartCategory`,
`oversizedModels`, `deepProbeConfigured`, `thermal`, `memoryUsedPercent`,
`runnerResidentBytes`, `tokensPerSecond`, `generationTokensTotal`,
`recentEvents`, `rebootOnWedge`, `credentialAccess`, `healthy`, `headline`,
`inferenceRecoveryWithheld`, `inferenceDeferredByProxy`, `inferenceNotice`.
Optional fields may be absent (a field whose source is
off, such as throughput without the metrics proxy); present fields keep their
names and types. New fields may be added in minor releases, so consumers should
ignore keys they do not know.

The inference-status fields above are new in source after v1.5.1. `phase` remains
the supervisor lifecycle. `healthy` is false when that lifecycle is unhealthy or
a confirmed inference incident has recovery withheld. A true value does not
prove a recent generation. `inferenceDeferredByProxy` means an open connection
deferred the check; that connection may be idle. `headline` and optional
`inferenceNotice` are display text; automate against the typed fields.

The routes (`GET /healthz`, `GET /status`, `GET /metrics`, `POST /start`,
`POST /stop`, `POST /restart`), their authentication (bearer token, all tokens
checked in constant time), and their status codes are stable. A status-only
credential may read `/status` and `/metrics`; process commands return 403.

Prometheus metric names (the `hearth_` family) and their label names are stable
and additive-only.

Webhook payload field names and the event `kind` strings are stable and
additive-only.

## Event log

The event log's line grammar is stable: a `yyyy-MM-dd HH:mm:ss` timestamp, two
spaces, and the message. Four message phrases are frozen because
`hearth events --stats` parses them: lines starting `Down: `, the exact line
`Recovered`, lines starting `Failing:`, and the exact line
`Maintenance restart`. A round-trip test renders real events and re-parses
them, so rewording one of these fails CI. Other event descriptions are
human-facing and may be reworded in minor releases.

## Experimental

- `rebootViaHelper` and the hearth-reboot-helper socket protocol.
- The Osaurus runner integration, until its server surface settles.
- Anything explicitly marked experimental in its documentation.

Experimental features may change or be removed in a minor release. Leftover
config keys follow the unknown-key warning rule.
