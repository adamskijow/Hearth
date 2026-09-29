<!-- SPDX-License-Identifier: MIT -->
# Contributing to Hearth

Hearth supervises Ollama on macOS. Contributions should improve availability,
recovery, diagnostics, security, or their user experience.

Current work is listed in the [product plan](docs/product-plan.md).

## Building and testing

Hearth builds as a Swift Package.

```
make build        # debug build
make test         # core and app tests
make ci           # debug/release builds, tests, HTTP/setup/recovery checks, lint
```

Install the pre-push hook once so the gate runs before every push:

```
make hooks        # points core.hooksPath at the in-repo scripts/hooks
```

The following older checks use broad process cleanup. Run them only in a
dedicated test environment, with a desktop session or Ollama installed:

```
make smoke        # drives the agent against scripts/fake-runner.py
make validate     # drives the agent against a real `ollama serve`
```

GitHub Actions and local development use the same `scripts/ci.sh`.

## Architecture rules

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

For supervision or process-control changes, run the isolated recovery checks
and verify the affected behavior against real Ollama using separate config,
data, ports, and owned processes. Run `make validate` only in a dedicated test
environment. Update [VALIDATION-REPORT.md](VALIDATION-REPORT.md) when the evidence
changes, and record anything left unverified.

## Releasing

The [development guide](docs/development.md#hearth-release) covers Developer ID
signing and notarization.
