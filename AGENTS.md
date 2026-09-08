# Shortking agent and contributor notes

Shortking is a macOS diagnostic tool that inventories every keyboard shortcut on
the machine and answers "who ate my shortcut?" via guided investigation. Read
[PLAN.md](PLAN.md) for the full design; [README.md](README.md) for building,
permissions, and distribution.

## Adding a config adapter

Adapters are a filter-list, not a release. Conform to `ConfigAdapter`, return the paths that exist
on disk and the bindings you parse out of them, and add it to
`AdapterRegistry.defaultAdapters()`:

```swift
public final class MyToolAdapter: ConfigAdapter {
    public let identifier = "mytool"
    public let displayName = "My Tool"
    public let layer: ClaimLayer = .sessionTap   // or .windowServer, .virtualHID…
    public let ownerName = "My Tool"
    public let ownerBundleID: String? = "com.example.mytool"

    public func detectedPaths() -> [String] {
        existing([Self.home(".config/mytool/config.json")])
    }

    public func parse(path: String) throws -> [ParsedBinding] { … }
}
```

Pick the layer honestly — it determines who wins a conflict, so a tool that pattern-matches in an
event tap is `.sessionTap`, not `.windowServer`, even though both feel "global".

## Project layout

```
PLAN.md                 the full UI and implementation plan
Sources/ShortkingKit/   model, sources, adapters, probe, attribution, detective, analysis
Sources/ShortkingApp/   the SwiftUI app
Sources/ShortkingProbe/ the short-lived probe helper
Tests/                  parser, conflict, confidence and classification tests
```

## Status

The inventory, conflict analysis, probing, suspects, health checks, differential attribution and
Detective Mode are implemented. Two behaviours are verified at runtime rather than assumed, because
they change between macOS releases:

- **Is duplicate hotkey registration refused?** Measured on every scan. If this machine permits it,
  the probe map is *hidden* rather than shown wrongly, and Health says so.
- **Do per-pid taps observe WindowServer hotkey delivery?** If live capture returns nothing,
  Shortking falls back to the sandwich taps, differential learning, and side-channel correlation.

Re-run both against every new macOS major version. See `PLAN.md` §18.


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

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Before editing, inspect the branch and working tree, fetch remote updates,
  and fast-forward where safe. Never overwrite existing work to update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch and open a PR against main.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Completion checklist

- The requested behavior is implemented without unrelated changes.
- Relevant checks pass for the latest code.
- Important review findings are addressed or rejected with reasons.
- Deferred suggestions, remaining risks, and validation gaps are disclosed.
- The final response accurately states whether work is committed, pushed,
  and merged.

<!-- shared-rules:end -->
