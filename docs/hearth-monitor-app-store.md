<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor Mac App Store release

This is the distribution checklist for the separate `com.hearth.HearthMonitor`
product. It does not apply App Sandbox to full Hearth and must never replace the
full product's Developer ID release.

The public GitHub beta uses the same sandboxed Monitor target but is signed and
notarized with Developer ID through `scripts/release-monitor.sh`. Let that build
accumulate installation, setup, false-positive, missed-failure, and
accessibility feedback before public App Review. Private TestFlight proves
Apple's delivery path; it does not replace use by unfamiliar people.
Switching an existing beta installation to TestFlight or the Store can make
macOS request access to the existing sandbox container because the designated
code-signing requirement changes. Document that expected one-time prompt for
beta users rather than presenting it as a product failure.

Use [the listing draft](hearth-monitor-app-store-listing.md) for the description,
keywords, screenshot order, What's New text, and reviewer walkthrough.

## Product record

- Name: **Hearth Monitor**
- Bundle ID: `com.hearth.HearthMonitor` (explicit App ID)
- Primary category: **Utilities**
- Subtitle: **Health checks for local AI**
- Minimum system: macOS 14
- Architectures: universal `arm64` and `x86_64`
- Version/build: `CFBundleShortVersionString` and `CFBundleVersion` in
  `Sources/HearthMonitor/Resources/Info.plist`; Mac build numbers must always
  increase, including across marketing versions.
- Privacy policy URL:
  `https://github.com/adamskijow/Hearth/blob/main/PRIVACY.md`
- Support URL:
  `https://github.com/adamskijow/Hearth/issues`
- App privacy response: **Data Not Collected**. The Apple Intelligence canary is
  processed by the on-device system framework and immediately discarded. Runner
  requests travel directly between the user's Mac and addresses they configure;
  the developer receives nothing.
- Export compliance: the app uses system TLS/Keychain and SHA-256 fingerprinting,
  not non-exempt encryption; `ITSAppUsesNonExemptEncryption` is `false`.

Create the App Store Connect app record before the first upload. Register the
explicit App ID, create a **Mac App Store Connect** provisioning profile for it,
and install matching **Mac App Distribution** and **Mac Installer Distribution**
certificates. Apple Distribution can replace Mac App Distribution when that is
the certificate attached to the generated profile.

## Build and package

First run the complete release gate described below. Then set:

```sh
export HEARTH_MONITOR_APP_IDENTITY="Mac App Distribution: …"
export HEARTH_MONITOR_INSTALLER_IDENTITY="Mac Installer Distribution: …"
export HEARTH_MONITOR_PROFILE="$HOME/Downloads/Hearth_Monitor_Mac_App_Store.provisionprofile"
./scripts/package-monitor-app-store.sh
```

The script uses only Apple/Swift build and packaging tools. It verifies the
profile's App ID, embeds it, signs the single self-contained sandbox app, runs the
capability/privacy boundary audit, and creates
`dist/Hearth-Monitor-<version>-<build>.pkg`. Validate and upload that package
with an App Store Connect API key:

```sh
export HEARTH_ASC_KEY="$HOME/path/AuthKey_XXXX.p8"
export HEARTH_ASC_KEY_ID="XXXX"
export HEARTH_ASC_ISSUER="<issuer-uuid>"
./scripts/upload-monitor-app-store.sh
```

Set `HEARTH_ASC_VALIDATE_ONLY=1` to validate without uploading. The upload script
passes the private key to Apple's bundled uploader by path and never copies it
into the repository, app, or package. Transporter remains a supported graphical
alternative. Do not notarize or staple a Mac App Store package; App Store
Connect performs its own distribution processing.

The app and installer identities are account material and are intentionally not
stored in the repository. Without them, a local ad-hoc sandbox package remains a
meaningful implementation proof but is not an uploadable App Store build.

## Notes for App Review

Adapt this text to the live review fixture and include every non-obvious feature:

> Hearth Monitor is a private menu-bar health monitor with two independent modes.
> Apple Intelligence mode uses Apple's public Foundation Models framework to
> report availability and, with explicit in-app consent, periodically request one
> tiny fixed on-device response. The response is discarded; only status, timing,
> and confirmed incidents remain locally. Two failures are required before an
> incident. A timed-out request is retained and no second request is stacked
> behind it. The app may recreate its own session but cannot restart Apple's
> system model service.
>
> Local AI Runners mode requires no separate Hearth installation. It probes
> user-operated Ollama, LM Studio, mlx_lm, or Osaurus endpoints, shows
> multi-runner health and incident history, and can optionally request one token
> to distinguish working HTTP from wedged GPU/inference. This mode is attached-
> only and never starts, stops, installs, updates, or restarts another process.
>
> Notifications and Open at Login are off until the reviewer enables them.
> Declining either does not block monitoring. The Local Network purpose string is
> used only to reach endpoints the reviewer configures.
>
> Optional full Hearth pairing is read-only and not needed for core operation.
> A status-only bearer is stored in Keychain and used solely for exact-address
> `GET /status`; source and binary audits reject recovery commands. Full Hearth
> remains a separately distributed unsandboxed product because its process/GPU-
> wedge recovery cannot exist inside App Sandbox.

Apple Intelligence mode is independently reviewable on an eligible macOS 26
review Mac with Apple Intelligence enabled and should be the first review path.
Also provide a live compatible HTTPS runner fixture and exact secondary-mode
steps; keep it available until review finishes. Do not submit placeholder
credentials or ask the reviewer to install full Hearth. Screenshots must show
Apple health, the two-mode onboarding, configured runner state, Details,
History, and the optional inference distinction.

## Current candidate evidence

Private TestFlight build **0.2.0 (5)** completed its bounded passive dogfood run
on July 25, 2026:

- 372 consecutive Apple on-device model canaries passed over 93.7 hours.
- Median latency was 1.47 seconds, p95 was 3.07 seconds, and the maximum was
  5.86 seconds.
- Scheduler diagnostics remained empty.
- A 58-minute gap straddled a real shutdown and reboot; the per-user scheduler
  resumed after the next logged-in session and subsequent canaries passed.
- The scheduler was then intentionally removed. Raw logs remain local and are
  not release assets.

Candidate **0.2.0 (6)** was validated, uploaded, processed as valid, installed
through private TestFlight, and launched on July 28, 2026. On the exact
TestFlight-delivered binary:

- The private Keychain write/read/delete self-test passed.
- A real Apple on-device model response completed in 0.56 seconds.
- The isolated production-transport runner gate passed healthy inference, one
  provisional timeout, a confirmed inference incident with actionable alert
  content, and inference-verified recovery.
- The complete 466-test suite, both product builds, Store capability boundary
  audit, and release-sized light/dark/empty/narrow UI renders passed before
  upload.

This closes the passive Foundation Models success path, current-Mac relaunch,
isolated runner-incident logic, package validation, and private TestFlight
delivery evidence. It does **not** prove notification presentation, a live
VoiceOver and keyboard-only traversal, denied-permission behavior, a real
third-party runner wedge, or the oldest supported macOS matrix. Those remain
explicit release-gate work below.

## Release gate

1. Run the whole Swift test suite through the installed Xcode toolchain so Swift
   Testing actually executes (the currently selected standalone Command Line
   Tools helper builds but runs zero tests on this machine).
2. Build both `Hearth` and `HearthMonitor` in release mode.
3. Package the ad-hoc signed app and run `scripts/audit-monitor-boundary.sh`.
4. Run the signed app's `--self-test-keychain` outside any enclosing automation
   sandbox; it writes, reads, and deletes one random private item.
5. On an eligible Mac, run the signed app's `--self-test-apple-model` and require
   a completed real response. Exercise the injected timeout-containment test and
   confirm a timed-out canary cannot stack another request.
6. Exercise a real compatible runner and an inference-only wedge through the
   signed app. The isolated fake-runner gate must prove the complete incident
   path through the production URL transport; confirm separately against a real
   compatible runner before App Review.
7. Verify VoiceOver labels, keyboard-only setup, light/dark appearance, disabled
   Apple Intelligence, model-not-ready, ineligible/old Mac, Low Power Mode,
   thermal pause, denied
   Local Network and Notifications paths, Login Items approval, sleep/wake,
   network loss, and launch after reboot on the oldest and current supported
   macOS releases.
8. Validate the distribution-signed `.pkg` before upload, then use TestFlight for
   the final signed build before submitting it for review.

Official references: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
[App Sandbox](https://developer.apple.com/documentation/security/app-sandbox),
[privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files),
and [uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).
