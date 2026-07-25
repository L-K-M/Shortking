# Security Policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private
[security advisory form](https://github.com/L-K-M/Shortking/security/advisories/new)
or contact the maintainer through the address on their GitHub profile.

Include the affected commit or version, reproducible steps, expected impact,
and sanitized diagnostics only. Do not attach binaries that could contain real
keyboard events, signing material, or private keys.

## Scope

Security-sensitive areas include:

- **Probe engine** (`ShortkingProbe`, `Sources/ShortkingKit/Probe/`): system-wide
  hotkey registration, cleanup guarantees, watchdog, and process isolation.
- **Blackout** (`Sources/ShortkingKit/Detective/BlackoutController.swift`): global
  hotkey operating mode toggle, restoration guarantees, accessibility shortcut
  exclusion.
- **Event taps** (`Sources/ShortkingKit/Detective/SystemDefinedSniffer.swift`,
  `SandwichTaps.swift`): listen-only key interception, tap lifecycle, permission
  model.
- **Private API** (`Sources/ShortkingKit/Platform/SkyLight.swift`): `dlopen` /
  `dlsym` of private frameworks, symbol resilience, gracefulness on missing
  symbols.
- **Accessibility API** (`Sources/ShortkingKit/Scanners/MenuBarScanner.swift`):
  read-only menu bar traversal.
- **Cross-app config reading** (`Sources/ShortkingKit/Adapters/`): reading other
  applications' preference domains without writing back.
- **Shell execution** (`Sources/ShortkingKit/Platform/SecureInput.swift`,
  `Sources/ShortkingKit/Scanners/BinaryTriage.swift`): fixed-argument invocations
  of `/usr/sbin/ioreg` and `nm -u`.
- **Persistence** (`Sources/ShortkingKit/Store/JSONStore.swift`): atomic writes,
  schema versioning, absence of stored secrets or raw events.
- **Signing and distribution**: Developer ID signing, notarization, DMG packaging,
  checksums.

## Security and privacy baseline

- Shortking is a **read-only** diagnostic tool. It never modifies the user's
  keyboard shortcuts, other applications' configuration, or system behavior
  beyond the bounded, documented detective probes.
- Every system mutation (probe hotkeys, blackout) has multiple independent
  restoration paths and bounded timeouts. The probe runs in a separate
  short-lived process so the OS cleans up even on a crash.
- Event taps are listen-only, time-bounded, and torn down on exit.
- Cross-application data reads are passive, through public or documented
  mechanisms.
- Shell subprocesses receive only fixed, safe arguments; user input never
  reaches a shell.
- No keyboard events, credentials, or signing material are persisted to disk or
  included in diagnostics.
- Release artifacts must be signed, notarized, stapled, and published with a
  SHA-256 checksum. Unsigned application bundles are not release artifacts.

The full design, adapter model, and permission table are maintained in
[PLAN.md](PLAN.md) and [README.md](README.md).
