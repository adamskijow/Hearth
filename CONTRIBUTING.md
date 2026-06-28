<!-- SPDX-License-Identifier: MIT -->
# Contributing to Hearth

Thanks for your interest. Hearth is a small, focused tool: a macOS supervisor that
keeps a local LLM runner alive. It is an availability layer, not an inference
layer, and it stays that way.

## Building and testing

It is a plain Swift Package; no Xcode project.

```
make build        # debug build
make test         # the SupervisorCore unit suite
make ci           # what the pre-push hook and CI run: build (debug + release), tests, lint
```

Install the pre-push hook once so the gate runs before every push:

```
make hooks        # points core.hooksPath at the in-repo scripts/hooks
```

End-to-end checks (need a desktop session or a runner installed):

```
make smoke        # drives the agent against scripts/fake-runner.py
make validate     # drives the agent against a real `ollama serve`
```

There is no hosted-only step: the same `scripts/ci.sh` runs locally and on
GitHub Actions.

## Architecture rules

The split is the point. Keep it.

- **`SupervisorCore` is pure.** No AppKit, no SwiftUI, no real `sleep`, no direct
  process or socket calls. All I/O is behind protocols (`SupervisorClock`,
  `ProcessControlling`, `HTTPClient`, `Notifier`, `PowerManaging`,
  `MetricsProviding`). This is what makes the restart policy testable with fakes
  and no real time. New decision logic goes here, behind a seam if it needs I/O.
- **The `Hearth` executable does the I/O.** posix_spawn and process-group
  teardown, the control server, IOKit, SMAppService, the menubar and Preferences.
  Pure helpers that can be unit tested belong in `SupervisorCore` (see
  `StatusText`, `RunnerLocation`, `ConfigLoading`, `ConfigDiagnostics`).
- **Do not weaken or delete a test to make it pass.** Fix the code, or correct
  the test to match reality and say why.

## Style and conventions

- Every source file starts with `// SPDX-License-Identifier: MIT` (the
  `swift-tools-version` line comes first in `Package.swift`). `make ci` lints
  this.
- **No em dashes** anywhere: code, comments, docs, or commit messages. `make ci`
  lints this too.
- Match the surrounding code's naming and comment density. Comments explain why,
  not what.
- Commit messages: a short imperative subject, then a body that explains the why.

## Validation and honesty

Hearth's value is that it actually works against real runners. If you change the
supervision or process-control paths, run `make validate` against a real Ollama
and update [VALIDATION-REPORT.md](VALIDATION-REPORT.md) if the evidence changes.
Never fabricate a result; if something is unverified, say so.

## Releasing

Releasing is local and documented in the README's Releasing section:
`scripts/release.sh` signs (Developer ID), notarizes, and packages a DMG and a
zip. The Mac App Store is intentionally not a target, because the App Sandbox
forbids supervising another process.
