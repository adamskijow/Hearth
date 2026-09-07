<!-- SPDX-License-Identifier: MIT -->
# Contributing to Hearth

Hearth is a focused macOS supervisor for local AI runners. Contributions should
improve availability, recovery, diagnostics, security, or their user experience.

Standalone Hearth Monitor is retired. Its source and tests remain for historical
reference; new Monitor features and App Store submissions are out of scope.
Full Hearth's attached monitoring mode remains supported. Current work is listed
in the [product plan](docs/product-plan.md).

## Building and testing

Hearth builds as a Swift Package.

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

GitHub Actions and local development use the same `scripts/ci.sh`.

## Architecture rules

The split is the point. Keep it.

- **`SupervisorCore` is pure.** No AppKit, no SwiftUI, no real `sleep`, no direct
  process or socket calls. All I/O is behind protocols (`SupervisorClock`,
  `ProcessControlling`, `HTTPClient`, `Notifier`, `PowerManaging`,
  `MetricsProviding`). These seams make restart policy testable with fakes and
  simulated time. New decision logic goes here.
- **The `Hearth` executable does the I/O.** posix_spawn and process-group
  teardown, the control server, IOKit, SMAppService, the menubar and Preferences.
  Pure helpers that can be unit tested belong in `SupervisorCore` (see
  `StatusText`, `RunnerLocation`, `ConfigLoading`, `ConfigDiagnostics`).
- **Preserve test intent.** Fix the code, or explain why reality requires a test
  correction.

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

The [development guide](docs/development.md#full-hearth-release) covers full
Hearth's Developer ID release path. Monitor publication scripts are disabled.
