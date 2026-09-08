<!-- SPDX-License-Identifier: MIT -->
# Setup and controlled recovery

Maintainer-run checks on September 7, 2026, using temporary configuration, data,
ports, and owned process identities on the available Apple silicon Mac. These
checks do not establish independent usability results or sustained reliability.

## Verify an existing setup

`hearth setup` installs the login agent and checks the configured client endpoint.
It preserves existing executable paths and stops on invalid configuration,
failed persistence, failed agent loading, or an unavailable client endpoint.
Successful API reachability alone explicitly leaves inference untested.

```sh
hearth setup --check
hearth setup --check --model YOUR-WORKLOAD-MODEL
```

Check mode does not install an agent or rewrite configuration. The second command
deliberately performs inference, may load the selected model, and requires a
completed response. It uses the metrics proxy when enabled. It reports configured
managed or attached coverage and partial traffic visibility; use `hearth status`
for the active supervisor's ownership and recovery eligibility. Config loading
still hardens an existing config file's permissions.

Preferences retains edited values when writing fails. A successful write says
that reload was requested, then directs the user to the menu for runner status.
Native startup blocks while ownership is being checked. The result must belong
to the current reload before any services start.

## Setup evidence

| Case | Result |
| --- | --- |
| Malformed or semantically invalid configuration | Stops before installation; original bytes preserved |
| Missing configuration in check/proxy setup | Fails without creating a starter file |
| Failed starter or attached-mode save | Stops; no installation after failed persistence |
| Custom executable, missing binary | Custom path preserved; managed installation rejects a missing executable |
| Agent load failure or endpoint timeout | Nonzero result identifying the failed stage |
| Existing compatible manager | Decision tests cover fresh attached selection and existing managed conflict; attached inference verified |
| Recorded runner on port A, foreign listener on B | Real two-process socket test refuses ownership of B |
| Local wildcard listener, remote configured address | Remote endpoint cannot be attributed to a local PID |
| Unknown HTTP 200 or wrong client port | Not accepted as a compatible runner API |
| Invalid host or raw runner port with valid proxy port | Rejected before inference can use a fallback URL |
| Real Ollama, direct and observed client paths | Completed inference; unavailable model returns failure |
| Real MLX, managed startup model | Completed inference through metrics proxy; unknown residency correctly withholds automatic inference recovery |
| MLX without managed startup model | Managed configuration rejected; attached verification works without the startup field |
| Generated Caddy template | Actual server rejects missing/wrong tokens and forwards buffered and streamed Ollama inference |
| Copied Caddy commands | Explicit adapter, quoted paths including spaces/apostrophe, correct runner readiness path; token file mode 0600 |

The real Ollama check used the installed `qwen2.5:0.5b` model. The real MLX check
used cached `mlx-community/Qwen2.5-0.5B-Instruct-4bit`, Python 3.12, MLX-LM 0.31.3,
and MLX 0.32.2 in a temporary virtual environment. Caddy 2.11.4 came from its
official release, verified against its SHA512 checksum. Its generated template
was changed only to use an ephemeral loopback listener and disable the admin
endpoint. No tailnet routing or public TLS deployment was exercised.

An explicit real inference check took about 3.6 seconds for Ollama and 0.7 seconds
for MLX after the API was available. These are individual small-model checks,
not fresh-install timings or performance benchmarks.

## Controlled failure evidence

`python3 scripts/validate-recovery.py` launches only a synthetic managed runner.
Each restored service must complete a new client request and regain current
inference verification. Client retries are explicit: Hearth does not resume an
interrupted application job.

| Injection | Observed result |
| --- | --- |
| Kill the recorded runner process | Replacement, verified inference, old group absent; about 2.7 seconds |
| Wedge API while process lives | API failure, replacement, verified inference; about 9.9 seconds |
| Wedge inference while API responds | Confirmed failure after observed client traffic, replacement, verified inference; about 20.5 seconds |
| Kill Hearth while its runner lives | Relaunch sweeps the orphan, starts a replacement, verifies inference; about 1.3 seconds |
| Repeated immediate process exits | Enters failing state, increases retry interval, then verifies inference after removing the fault |

Times are single observations under deliberately short fixture settings, not
production recovery guarantees. Normal shutdown left no recorded fixture groups.
Emergency fixture cleanup fails the gate after cleaning up, so it cannot hide a
teardown regression. Worker-group cleanup is additionally covered by Swift process
integration tests; the runtime orphan drill uses a single fixture leader.

Run the repeatable checks with a built Hearth executable:

```sh
python3 scripts/validate-setup.py
python3 scripts/validate-recovery.py
```

Both use dedicated state and ports. Never substitute the older broad-cleanup
`validate-real.sh` or `smoke-test.sh` against a normal installation.

## Remaining evidence

The Mac remained locked, so live keyboard/menu checks could not run. Native
Preferences render tests passed, but rendering does not verify keyboard behavior.
Actual LaunchAgent installation is untested in this stage; tests inject that
operation to avoid replacing the normal login service. Signed packaging,
quit/relaunch of the GUI, the 72-hour workload, real GPU/OOM failure behavior,
and other hardware/macOS versions remain separate checks.
