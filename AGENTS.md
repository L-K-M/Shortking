# Shortking agent and contributor notes

Shortking is a macOS diagnostic tool that inventories every keyboard shortcut on
the machine and answers "who ate my shortcut?" via guided investigation. Read
[PLAN.md](PLAN.md) for the full design; [README.md](README.md) for building,
permissions, and distribution.

## Current status

- The app is a working SwiftUI GUI with a bundled CLI probe helper.
- Targets: `ShortkingKit` (library), `ShortkingApp` (executable / `@main`),
  `ShortkingProbe` (auxiliary CLI).
- Build: `scripts/build.sh` (or `make app`; the stub drives the Makefile).
- Test: `make test` (or `swift test`). Pure unit tests for model logic.
- CI runs `swift test` + `make app` on `macos-14` with Xcode 16.2 pinned, and asserts
  the assembled bundle's layout. See [CICD.md](CICD.md).

## Architecture invariants

- **The probe is always a separate process.** `shortking-probe` calls
  `RegisterEventHotKey` for thousands of combos and exits immediately. Every
  registration is released in `defer`. A watchdog timer (120 s hard cap) and
  signal handlers force-exit the process. Never move probing into the main app
  process.
- **Blackout always restores.** `CGSSetGlobalHotKeyOperatingMode` must be
  bracketed by four independent restoration paths: `defer`,
  `willTerminateNotification`, `deinit`, and a 30 s timer watchdog.
  Accessibility shortcuts are never disabled.
- **Private API symbols are optional.** Every `dlsym` from SkyLight is
  optional; missing symbols disable the feature with a Health warning, never a
  crash.
- **Never mutate user shortcuts.** This is a read-only diagnostic tool. Do not
  add any rebinding, remapping, or key-claim modification.
- **Shortcut data and prefs from other apps are read-only.** Config sniffing
  (Karabiner, skhd, VS Code, JetBrains, Hammerspoon, third-party pref domains)
  must never write back.
- **No sandbox.** The app explicitly opts out of the App Sandbox because it
  reads other apps' preference domains and uses private frameworks. It is
  distributed via Developer ID + notarization, never the Mac App Store.

## Security-sensitive areas

- **Event taps** in `Detective/SystemDefinedSniffer.swift` and `SandwichTaps`
  are listen-only, bounded (30 s default), and require Input Monitoring. Tear
  them down on exit.
- **Accessibility API** usage in `MenuBarScanner` is read-only; never activate
  menu items. Requires Accessibility grant.
- **Shell execution** runs `/usr/sbin/ioreg` and `nm -u` with fixed, safe
  arguments. Never pass user input to a shell command.
- **Persistence** in `~/Library/Application Support/Shortking/` uses atomic
  writes. Never store secrets, credentials, or raw keyboard events on disk.

## Build and verification

```bash
make build    # debug build (staged into .build/debug/)
make test     # SwiftPM XCTest suite
make app      # assemble .app bundle
make sign     # Developer ID signing
make notarize # notarytool submission
make dmg      # create distributable disk image
```

The `scripts/` stubs wrap those for the family-standard entry points:

```bash
scripts/build.sh [--clean] [--debug] [--run] [--install] [--zip] [--dmg]
scripts/release.sh [X.Y[.Z]] [--push]
```

Both are ~25-line stubs over the shared engines in
https://github.com/L-K-M/release-tool (install: clone + `./install.sh`). Keep them
stubs — repo-specific build logic belongs in the Makefile (which
`scripts/assemble-app.sh` invokes as the engine's `BUILD_SWIFTPM_ASSEMBLE`
command), and anything the engine itself lacks belongs upstream as a new kind.

`Resources/Info.plist` is the single source of truth for the version.
`scripts/release.sh` bumps `CFBundleShortVersionString`, auto-increments
`CFBundleVersion`, updates the README `<!-- version -->` marker, commits and tags —
never edit the plist version by hand, and never create a `v*` tag by hand: the
release workflow refuses a tag that disagrees with the committed version.

CI runs `swift test` and `make app` on a macOS runner. The release workflow packages
a `.dmg` and `.zip` and publishes them with SHA-256 sums. When the Developer ID
secrets are configured it signs, notarizes and staples; when none of them are, it
falls back to an ad-hoc signed build and says so in the release notes, the same as
Top Drawer and Zap. A *partial* configuration fails the release — that is a
misconfiguration, not a choice. Developer ID is what Shortking should ship under,
because an app that asks for Accessibility and Input Monitoring is a poor candidate
for a Gatekeeper warning; configure the secrets and the next tag upgrades itself.

## Repository automation

- `.github/workflows/zai-code-review.yml` reviews same-repository, non-draft
  pull requests when `ZAI_API_KEY` is configured. It intentionally does not run
  for fork pull requests because `pull_request_target` has access to secrets.
- Dependabot covers GitHub Actions updates weekly.
- `.github/workflows/ci.yml` tests and assembles the bundle on every PR and push
  to `main`; `.github/workflows/release.yml` builds, signs (Developer ID when the
  secrets are set, ad-hoc otherwise) and publishes on a `v*` tag. Both pin Xcode
  16.2 — bump the two together, and keep them in step with Top Drawer and Zap.
  [CICD.md](CICD.md) documents both, including the seven release secrets.

## Conventions

- Swift 5.9+, SwiftUI + AppKit, min target macOS 14.
- One primary type per file. Keep pure model logic unit-testable.
- The Makefile is the single entry point for building, signing, and packaging;
  keep its targets idempotent.
- Do not commit signing certificates, provisioning profiles, or environment
  files.
