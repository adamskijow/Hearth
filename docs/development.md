<!-- SPDX-License-Identifier: MIT -->
# Development

## Tests

```sh
make test
make ci
make hooks
```

`make test` runs Swift Testing through `scripts/test.sh`, which supports full
Xcode and Command Line Tools layouts. `make ci` builds debug and release, runs
the tests and isolated HTTP, setup, and recovery checks, then lints source
headers, whitespace, shell syntax, and the repository's no-em-dash rule.

The pre-push hook and GitHub Actions call the same CI script. Add `--smoke` for
the desktop fake-runner test or `--real` for the Ollama lifecycle gate.

The older smoke and real-runner scripts use broad process cleanup. Run them
only in a dedicated test environment. The Python gates use isolated state and
owned processes.

```sh
./scripts/smoke-test.sh       # fake runner; logged-in desktop required
./scripts/validate-real.sh    # real Ollama
python3 scripts/validate-inference.py  # HTTP relay and inference evidence
python3 scripts/validate-setup.py      # setup admission and copied commands
python3 scripts/validate-recovery.py   # process exit, wedges, crash loop, orphan cleanup
make demo                     # isolated narrated wedge recovery
```

The manual `real-ollama.yml` workflow runs the live Ollama gate on GitHub. Test
evidence lives in [VALIDATION-REPORT.md](../VALIDATION-REPORT.md). The
[product plan](product-plan.md) defines the next local validation milestones.

The inference gate uses temporary config/data and loopback ports. It checks
status agreement, inference checks over idle keep-alive connections, active
requests across the busy timeout, cancellation, and byte-preserving relay
behavior. Build first, or supply `--binary` with another Hearth executable.

## Hearth release

`scripts/release.sh` builds, Developer ID signs, notarizes, staples, and packages
the app as DMG and ZIP. Supply a signing identity plus either a Keychain profile:

```sh
export HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEARTH_NOTARY_PROFILE="HearthNotary"
./scripts/release.sh
```

or an App Store Connect API key:

```sh
export HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEARTH_NOTARY_KEY="$HOME/path/AuthKey_XXXX.p8"
export HEARTH_NOTARY_KEY_ID="XXXX"
export HEARTH_NOTARY_ISSUER="<issuer-uuid>"
./scripts/release.sh
```

Attach the DMG, ZIP, `SHA256SUMS`, and `RELEASE-PROVENANCE.txt` to the GitHub
release. The `adamskijow/homebrew-tap` sync workflow updates its cask from the
latest release.

Pushing a `v*` tag triggers `release.yml`. It verifies that the tag matches the
bundle version, points at the checked-out commit, and belongs to `origin/main`.
Configured signing secrets enable hosted publication; otherwise the workflow
runs only the release gate and artifacts must be published locally.
