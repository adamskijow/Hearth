<!-- SPDX-License-Identifier: MIT -->
# Hearth Monitor Mac App Store release

This is the distribution checklist for the separate `com.hearth.HearthMonitor`
product. It does not apply App Sandbox to full Hearth and must never replace the
full product's Developer ID release.

## Product record

- Name: **Hearth Monitor**
- Bundle ID: `com.hearth.HearthMonitor` (explicit App ID)
- Primary category: **Utilities**
- Minimum system: macOS 14
- Architectures: universal `arm64` and `x86_64`
- Version/build: `CFBundleShortVersionString` and `CFBundleVersion` in
  `Sources/HearthMonitor/Resources/Info.plist`; Mac build numbers must always
  increase, including across marketing versions.
- Privacy policy URL:
  `https://github.com/adamskijow/Hearth/blob/main/PRIVACY.md`
- Support URL:
  `https://github.com/adamskijow/Hearth/issues`
- App privacy response: **Data Not Collected**. Runner requests travel directly
  between the user's Mac and addresses they configure; the developer receives
  nothing.
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
`dist/Hearth-Monitor-<version>-<build>.pkg`. Validate and upload that package with
Xcode Organizer, Transporter, or `xcrun altool` using App Store Connect
credentials. Do not notarize or staple a Mac App Store package; App Store Connect
performs its own distribution processing.

The app and installer identities are account material and are intentionally not
stored in the repository. Without them, a local ad-hoc sandbox package remains a
meaningful implementation proof but is not an uploadable App Store build.

## Notes for App Review

Adapt this text to the live review fixture and include every non-obvious feature:

> Hearth Monitor is a menu-bar utility for AI runners already operated by the
> user. It requires no account and does not require the separate full Hearth app.
> It probes Ollama, LM Studio, mlx_lm, or Osaurus directly, shows multi-runner
> health and incident history, and can optionally request one token to distinguish
> working HTTP from wedged GPU/inference. It is intentionally attached-only and
> never starts, stops, installs, updates, or restarts another process.
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

Before submission, provide App Review a live compatible HTTPS test endpoint or
other concrete review resource and exact steps. Keep it available until review
finishes. Do not submit placeholder credentials or ask the reviewer to install
full Hearth. Screenshots must show configured live state, Details, History, and
the optional inference distinction, not only onboarding.

## Release gate

1. Run the whole Swift test suite through the installed Xcode toolchain so Swift
   Testing actually executes (the currently selected standalone Command Line
   Tools helper builds but runs zero tests on this machine).
2. Build both `Hearth` and `HearthMonitor` in release mode.
3. Package the ad-hoc signed app and run `scripts/audit-monitor-boundary.sh`.
4. Run the signed app's `--self-test-keychain` outside any enclosing automation
   sandbox; it writes, reads, and deletes one random private item.
5. Exercise a real compatible runner and an inference-only wedge through the
   signed app. Confirm the incident closes only after real inference succeeds.
6. Verify VoiceOver labels, keyboard-only setup, light/dark appearance, denied
   Local Network and Notifications paths, Login Items approval, sleep/wake,
   network loss, and launch after reboot on the oldest and current supported
   macOS releases.
7. Validate the distribution-signed `.pkg` before upload, then use TestFlight for
   the final signed build before submitting it for review.

Official references: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
[App Sandbox](https://developer.apple.com/documentation/security/app-sandbox),
[privacy manifests](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files),
and [uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).
