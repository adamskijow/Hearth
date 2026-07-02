<!-- SPDX-License-Identifier: MIT -->
# Stability contract

Hearth aims to follow semantic versioning, and a version number only means
something if it says what is covered. This page declares which surfaces are
stable for the 1.x series, what "stable" means for each, and what carries no
promise. Tests pin the load-bearing pieces, so an accidental break fails CI
rather than shipping.

The policy: removing or renaming anything listed as stable requires a major
version. Deprecations get at least one minor release during which the old form
still works and `hearth doctor` warns about it.

## Config file

Config keys are stable. New keys may be added in minor releases; existing keys
keep their names, types, and defaults through 1.x.

Loading is lenient by design, so config files travel across versions:

- An unknown key (from a newer Hearth, or a typo) is ignored with a doctor and
  menu warning, never an error.
- An unrecognized value for `runner` or `mode` falls back to the default with a
  doctor warning.
- A missing key means its documented default.

## Command line

The subcommand names (`status`, `logs`, `events`, `metrics`, `doctor`,
`doctor-daemon`, `mode`, `wait-ready`, `update`, `proxy-setup`, `setup`,
`install-agent`, `uninstall-agent`) and their documented flags are stable, as
are the exit codes: 0 for success, 1 for failure.

CLI output text is written for people and is NOT a stable interface; wording
may improve in any release. A script that needs machine-readable state should
call the control API's `/status`, not parse CLI output.

## Control API

`GET /status` field names are stable and additive-only: `phase`, `busy`,
`models`, `uptimeSeconds`, `restartCount`, `consecutiveFailures`,
`lastRestartReason`, `lastDownCategory`, `deepProbeConfigured`, `thermal`,
`memoryUsedPercent`, `runnerResidentBytes`, `tokensPerSecond`,
`generationTokensTotal`. Optional fields may be absent (a field whose source is
off, such as throughput without the metrics proxy); present fields keep their
names and types. New fields may be added in minor releases, so consumers should
ignore keys they do not know.

The routes (`GET /healthz`, `GET /status`, `GET /metrics`, `POST /start`,
`POST /stop`, `POST /restart`), their authentication (bearer token, all tokens
checked in constant time), and their status codes are stable.

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

## No promise (experimental)

- `rebootViaHelper` and the hearth-reboot-helper socket protocol.
- The Osaurus runner integration, until its server surface settles.
- Anything explicitly marked experimental in its documentation.

Experimental features may change or be removed in a minor release; their config
keys still follow the unknown-key rule (a leftover key warns, nothing breaks).
