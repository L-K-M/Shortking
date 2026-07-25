# Shortking agent and contributor notes

Shortking is a macOS diagnostic tool that inventories every keyboard shortcut on
the machine and answers "who ate my shortcut?" via guided investigation. Read
[PLAN.md](PLAN.md) for the full design; [README.md](README.md) for building,
permissions, and distribution.

## Current status

- The app is a working SwiftUI GUI with a bundled CLI probe helper.
- Targets: `ShortkingKit` (library), `ShortkingApp` (executable / `@main`),
  `ShortkingProbe` (auxiliary CLI).
- Build: `make build` (or `swift build`; the Makefile wraps it).
- Test: `make test` (or `swift test`). Pure unit tests for model logic.
- No CI pipelines exist yet; macOS-only builds should gate on a macOS runner.

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

CI should run `swift build` and `swift test` on a macOS runner. Release
workflows should sign, notarize, staple, and package a `.dmg`, publishing it
with a SHA-256 checksum. Never publish an unsigned application bundle.

## Repository automation

- `.github/workflows/zai-code-review.yml` reviews same-repository, non-draft
  pull requests when `ZAI_API_KEY` is configured. It intentionally does not run
  for fork pull requests because `pull_request_target` has access to secrets.
- Dependabot covers GitHub Actions updates weekly.
- Add `ci.yml` and `release.yml` workflows once a macOS runner and signing
  secrets are available. The release workflow must sign, notarize, staple, and
  publish a checksummed DMG.

## Conventions

- Swift 5.9+, SwiftUI + AppKit, min target macOS 14.
- One primary type per file. Keep pure model logic unit-testable.
- The Makefile is the single entry point for building, signing, and packaging;
  keep its targets idempotent.
- Do not commit signing certificates, provisioning profiles, or environment
  files.
