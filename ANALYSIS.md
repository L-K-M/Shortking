# Shortking — outstanding work

The living backlog. Every finding carries a stable ID so a commit can close one by
name; line numbers are against `12dbe0f` unless a later commit is noted.

Derived from a full read of every source file, test and build script. What has since
been fixed lives in [§0](#0-shipped) as a one-line ledger rather than being deleted,
so a reader can tell "already handled" from "never noticed".

Read alongside [PLAN.md](PLAN.md) — the design — and [AGENTS.md](AGENTS.md) — the
invariants that must survive any change here.

**The single most important fact about this codebase:** as of PR #1 it had never been
compiled. It was written on Linux against a macOS-only API surface. §1 collects what
is most likely to stop a build or corrupt memory on first run; clear it before
judging anything else.

---

## Contents

0. [Shipped](#0-shipped)
1. [Blockers: compile and first-run](#1-blockers-compile-and-first-run)
2. [Correctness](#2-correctness)
3. [Performance and responsiveness](#3-performance-and-responsiveness)
4. [Architecture and code health](#4-architecture-and-code-health)
5. [Missing features](#5-missing-features)
6. [Visual and layout](#6-visual-and-layout)
7. [macOS-native interaction](#7-macos-native-interaction)
8. [Aesthetics](#8-aesthetics)
9. [Accessibility and internationalisation](#9-accessibility-and-internationalisation)
10. [Safety, security, privacy](#10-safety-security-privacy)
11. [Build and packaging](#11-build-and-packaging)
12. [Product ideas](#12-product-ideas)
13. [Suggested order of work](#13-suggested-order-of-work)

---

## 0. Shipped

| ID | What | Where |
|---|---|---|
| C1 | `ForEach` key paths into tuple elements (4 sites) — could not compile | #3 |
| C4d | Recorder timeout ran off the main thread, touching `NSEvent` and `@State` | #3 |
| V1 | Keycap column truncated long combinations (Overview and Inventory) | #3, #5 |
| B1 | Input-source switching reported as a conflict with itself | #4 |
| B4 | `ClaimMerger` documented restricted-result handling it did not implement | #4 |
| P3 | Cache persisted in full once per app — quadratic writes per scan | #6 |
| P4 | Inventory refiltered and reallocated on every keystroke, twice per render | #5 |
| P5 | Health checks (AX round trip, tap creation, `ioreg`) ran on the main actor | #5 |
| B5 | Sandwich taps died silently; the "will be re-armed" comment was fiction | #8 |
| B6 | `Shell.run`'s timeout could never fire | #7 |
| B7 | `ProbeRunner` drained its two pipes sequentially — latent deadlock | #7 |
| B9 | "Clear caches" cleared fresh objects, not the ones in use | #5 |
| B10 | "Forget everything" left inferred owners on screen | #5 |
| B12 | A cancelled scan latched `isScanning` and wedged every future scan | #5 |
| B14 | Grouped lists used duplicate `List` tags; several rows highlighted at once | #5 |
| B16 | Blackout result buttons recorded 0.85-confidence findings with no blackout | #8 |
| S1 | Probe helper's signal handler called `exit` rather than `_exit` | #7 |
| V2 | Blackout banner scrolled out of view | #8 |
| X6 | "1 claim(s)" across seven files | #8 |
| F7 | Owner icons — **Suspects only**; inventory and conflicts still text-only | #9 |
| V9 | Animation — **Overview only**; every other screen still snaps | #3 |

---

## 1. Blockers: compile and first-run

### C2 — `ShortkingApp` type shadows the `ShortkingApp` module

`Package.swift:20` declares the target; `Sources/ShortkingApp/ShortkingApp.swift:5`
declares `struct ShortkingApp: App` inside it. Legal, but any future
`ShortkingApp.Something` reference resolves against the type rather than the module
and the diagnostics become confusing. Rename the type to `ShortkingMainApp`, or the
target to `ShortkingUI`. Cheap now, annoying later.

### C3 — `CGSGetSymbolicHotKeyValue` argument widths are unverified **[memory safety]**

`Platform/SkyLight.swift:24-29` declares the modifier out-parameter as
`UnsafeMutablePointer<UInt64>`. The historical CGS signature uses a 32-bit
`CGSModifierFlags`. Writing eight bytes into a four-byte caller slot is a stack
smash, not a wrong answer.

`PLAN.md` §18 lists this as a secondary unknown. It belongs here instead: silent
memory corruption outranks a feature that might not work. Either over-allocate
deliberately —

```swift
var modifiersStorage: (UInt64, UInt64) = (0, 0)   // deliberate slack
```

— or sanity-check the value against a known ID (64 = Spotlight) on first run and
disable the live path when it is implausible. **Verify on a real machine before
changing anything here; a guess is worse than the status quo.**

### C4 — Concurrency violations, warnings today and errors under Swift 6

`Package.swift` pins `swiftLanguageVersions: [.v5]`, so these compile.

- `Scan/ScanCoordinator.swift:64-74` captures non-`Sendable` `ClaimSource` objects
  into `group.addTask`.
- `Scanners/EventTapScanner.swift:70` — `lastTaps` is written from a concurrent task
  and read from the main actor. An actual data race, not a formality.
- `Scan/ScanContext.swift:139` is `@unchecked Sendable`, which suppresses the
  diagnostic that would have caught both.

---

## 2. Correctness

### B2 — Shifted punctuation lands in a different row from everything else

`Platform/AXBridge.swift:104-108` returns `KeyCombo(keyCode: nil, character: char, …)`
from `AXMenuItemCmdChar`. For ⇧⌘/ ("Help"), AX reports `?`; `KeyCodes.charToKeyCode`
has no entry for it, so `keyCode` stays `nil` and the grouping key is `"c?|m3"` —
while the probe, the symbolic scanner and every config adapter produce `"k44|m3"` for
the same physical shortcut.

One shortcut, two rows, and no conflict detected between them. Same for
`:` `<` `>` `~` `_` `+` `{` `}` `|` `"` and every other shifted glyph.

Fix: a shifted → unshifted table in `KeyCodes`, consulted from `KeyCombo.init` when
the direct lookup fails.

### B3 — The key map is hard-coded to ANSI **[highest-impact correctness item]**

`Model/KeyCodes.swift:12-21`. On a German layout keycode `0x06` is `Y`, not `Z`; on
AZERTY `0x00` is `Q`, not `A`. So on any non-US layout Shortking **displays the wrong
key** for every character-derived combo, and groups those combos under the wrong
keycode — missing real conflicts and inventing false ones.

Fix: build the table at runtime from the active layout via
`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate`, falling back to the
ANSI table. Needs a Mac to verify; invisible on a US developer's own machine, which
is exactly why it survived this long.

### B8 — A single coincidental quit outranks "I don't know"

`Attribution/AttributionStore.swift:122-127`:

```swift
let curve = 1 - exp(-0.45 * net)
return min(0.95, max(0.0, 0.3 + 0.65 * curve))
```

One `freedOnQuit` observation gives `net = 1` ⇒ confidence **0.535**, above
`probedClaimed`'s baseline of 0.5. So the first time an app happens to quit while a
combination frees up, an honest "claimed, owner unknown" is replaced by a *named
guess that the UI ranks higher*. The curve is also discontinuous — it jumps from 0
straight to ≥0.53, so there is no weak-hint band at all.

The stated principle is "a wrong name is worse than no name". Require at least two
independent observations before crossing 0.5: drop the 0.3 floor and start the curve
at 0, or raise `inferredClaims`' minimum to 0.55 and let `net = 1` sit below it.
`AnalysisTests.testInferenceRequiresMinimumConfidence` currently pins the *old*
behaviour and will need updating with it.

### B11 — Two dead settings

`Store/AppSettings.swift:14, 16`.

- `rescanOnAppLifecycle` — declared, persisted, **never read**. The "rescan when apps
  launch or quit" behaviour does not exist. See F3.
- `disabledAdapters` — declared, persisted, never read. `AdapterRegistry.disabled`
  exists and is honoured (`Adapters/AdapterRegistry.swift:94`) but nothing populates
  it, and the registry the UI reads (`AppState.adapterRegistry`) is a *different
  instance* from the one the coordinator scans with. Turning an adapter off is
  impossible, and Settings offers no control for it. See F6.

### B13 — Duplicate ⌘R registration

`ShortkingApp.swift:23-24` (menu command) and `Views/RootView.swift:33` (toolbar
button) both claim ⌘R. Two responders for one key equivalent, in the app whose
purpose is finding two responders for one key equivalent. Keep the menu command; give
the toolbar button `.help("Rescan (⌘R)")` and no shortcut.

### B15 — `DetectiveSession.investigate` and the recorder can drift

Partly addressed in #8, which syncs `session.combo` → local `combo` with a guard
against looping. Worth a second look once there is more than one call site: the loop
risk is real, because the recorder's own `onChange` calls back into `investigate`,
which calls `reset()`, which nils the session's combo.

### B17 — Minor and cosmetic

- `Model/Conflict.swift:61` — `isIntermittent` is dead code; `AppState` tests
  `kind == .contextual` directly.
- `Probe/ProbeReport.swift:108` — `ProbeSweep.claims(from:)` is used only by tests;
  the live path is `ClaimMerger.applyProbeReport`.
- `AppState.unknownOwnerGroups` and `unattributedCount` compute the same filter twice.
- `Scanners/SymbolicHotKeyScanner.swift:192-198` — `Claim.symbolicID`'s setter can
  only write into evidence that already carries the key, so it is a no-op at every
  call site.
- `Analysis/ConflictAnalyzer.swift` — `shadowExplanation` says losers claim it "at
  the X layer or below". In a model where *lower numbers win*, "below" reads as
  "wins", the opposite of what is meant.
- `Model/Claim.swift:52-56` — `identity` includes `label`, so a menu item with a
  dynamic title ("Undo Typing" → "Undo Move") is a **new claim every scan**:
  `firstSeen` resets, `reconcile` never matches, and the persisted database grows
  without bound. The menu cache masks this until its TTL expires.
- `Attribution/AttributionStore.swift` — `inferences()` pins `ownerName` at first
  sight and never refreshes it, so a renamed app keeps its old name forever.
- `Platform/SecureInput.swift:37` — `ioreg -d 1` limits output to the root node's own
  properties, but `kCGSSessionSecureInputPID` normally lives under `IOConsoleUsers` on
  `IOResources`, one level deeper. **Verify on a real machine**: if it is wrong, the
  "Held by X" line never appears and the check silently loses half its value.

---

## 3. Performance and responsiveness

### P1 — Per-source "timeouts" do not bound the scan **[structural]**

`Scan/ScanCoordinator.swift:149-196` races the source against a `Task.sleep` inside a
`withTaskGroup` and returns the timeout outcome. But **returning from a
`withTaskGroup` body implicitly awaits every remaining child task.** `cancelAll()`
only sets a flag; `MenuBarScanner` checks it once per *app*, `GenericPreferenceScanner`
once per *plist*, and the blocking work inside those iterations is not interruptible
at all.

So a scan that "timed out after 8 seconds" can still block for a minute, and the user
sees a spinner with no cancel button (F1). The Health screen then reports the source
as failed and throws away every claim it *had* collected (A1).

Needs two things together: sources returning partial results, and blocking sources
detached onto a `DispatchQueue` so the deadline is real.

### P2 — Blocking I/O on the cooperative thread pool

Every source runs as a `Task` on the shared pool, sized to the core count.
`MenuBarScanner` (synchronous AX IPC), `GenericPreferenceScanner` (up to 1,500
synchronous `NSDictionary(contentsOfFile:)` reads), `UserKeyEquivalentScanner` (one
`CFPreferencesCopyValue` per installed bundle ID — hundreds of cfprefsd round trips)
and `BinaryTriage` (`nm` per app) all block their thread outright. On an eight-core
machine four of these saturate half the pool and starve every other `async` operation
in the process, SwiftUI's own work included. This is the structural cause of
scan-time stutter, and it is the same fix as P1.

### P6 — Launch decodes and analyses the whole inventory on the main thread

`AppState.init` (`AppState.swift:118-126` at `12dbe0f`) synchronously loads
`claims.json`, decodes it, then runs `ClaimMerger.group` + `ConflictAnalyzer.analyze`
over every claim — all before the first frame. Should be a `Task` that populates the
view after first paint, with a skeleton in the meantime.

Related: `AppState` and `ScanCoordinator` each construct their own `ClaimDatabase`,
so the file is parsed twice and held in memory twice. (#5 fixed the equivalent
problem for the two scan caches; the claims database still has it.)

### P7 — `SettingsView` hits the filesystem on every body evaluation

`AppState.adapterStatuses` calls `AdapterRegistry.statuses()`, which calls
`detectedPaths()` on every adapter — `fileExists` plus two `contentsOfDirectory`
walks. It is read directly from `SettingsView.body`, so **every toggle flip re-stats
the disk**. Compute once per scan and cache.

### P8 — Every settings change writes JSON synchronously on the main thread

`@Published var settings { didSet { settingsStore.update … } }` and
`SettingsStore.update` calls `store.save(settings)` inline. Each toggle, each picker
change and every post-scan `probingVerified` update is a synchronous write on the
main actor.

### P9 — Differential learning re-probes on every app launch and quit, forever

`Attribution/DifferentialEngine.swift:100-129` debounces 1.5 s and then spawns the
probe helper to register and unregister **every combo in the last report** (~490 at
`common`, ~2,000 at `exhaustive`). No minimum interval, no cap per hour, no
suspension on battery or Low Power Mode. On a machine where apps come and go all day
this is continuous background cost — and each sweep is a window in which the user's
own keystrokes can be briefly swallowed by the probe.

### P10 — Smaller

- `claims.json` is still written `.prettyPrinted` + `.sortedKeys` (#6 turned this off
  only for the two caches). It is the largest file the app writes.
- `Views/InventoryView.swift` — `ComboRow` builds a `Set` and sorts it on every row
  render.
- Five coloured `.shadow` modifiers on the Overview each force an offscreen pass;
  visible while scrolling on integrated GPUs.
- `AppState.runningApps` re-snapshots `NSWorkspace` and constructs a `Bundle` per
  running app on every access — it is a computed property, so any future use inside a
  view body would be pathological.

---

## 4. Architecture and code health

### A1 — Sources are all-or-nothing on failure

`SourceOutcome` carries `claims: []` whenever a source throws or times out. A scanner
that read 900 of 1,000 preference domains before its deadline contributes **nothing**
— and given P1/P2, the heaviest and most valuable sources are the likeliest to be
discarded. `SourceOutcome` should carry partial claims alongside the error.

### A2 — `AppState` is doing four jobs

View model, scan orchestrator, settings owner, export formatter, process-lifecycle
manager. `Verdict` in particular is domain logic and belongs in `ShortkingKit` beside
`ConflictAnalyzer`, where it can be tested — it is the single most user-visible piece
of reasoning in the app and has **zero test coverage**.

### A3 — `Claim.identity` is a string doing structural work

`"\(layer.rawValue)|\(ownerPart)|\(combo.groupingKey)|\(labelPart)"` is parsed by
nothing and compared by everything. A `struct ClaimKey: Hashable` with typed fields
would make B17's label-churn obvious at the type level and remove a class of
delimiter-collision bugs (an owner named `a|b` collides with `a` plus `b`).

### A4 — The test suite has a shape-shaped hole

`AnalysisTests` is good work — it pins the ⌥-hardening classification, the
session-tap-must-not-absorb-probe-evidence rule, the confidence asymmetry. But
nothing covers:

- `AppState.verdict(for:)` — untestable where it lives (A2);
- `ClaimMerger.reconcile` — the function that makes `firstSeen` mean anything;
- `Claim.merge` — the disabled-anywhere-means-disabled rule;
- `ComboGroup.winner` tie-breaking at equal layers;
- `JSONC.strip` against a real `keybindings.json` with `//` inside a string literal —
  the exact case the hand-written stripper exists for;
- `GenericPreferenceScanner.extract` against all three library signatures.

The parsers are covered; the merge layer between them and the UI is not.

### A5 — Logging is well-organised and under-used

Seven categories, ~15 call sites. `SourceOutcome.duration` exists and is never logged
or surfaced, so "why was that scan slow" is unanswerable from a bug report. Log the
per-source duration table on every scan and show it in Health.

---

## 5. Missing features

### F1 — No way to cancel a scan

Rescan disables itself while scanning. With P1 meaning a scan can run far past its
nominal deadline, there is no escape. A Cancel affordance in the status bar is table
stakes.

### F2 — No history, no diff, no "what changed" **[biggest missed opportunity]**

`ClaimDatabase` already persists the full inventory on every scan, and `firstSeen` /
`lastConfirmed` already exist on every claim. The app throws away the one thing that
answers the question users actually arrive with — *"this worked yesterday"* — for
free.

A **Changes** screen: "since your last scan / since yesterday / since this app
updated: 3 claims appeared, 1 disappeared, Raycast took ⌘⇧Space." Most of it is
already built.

### F3 — No auto-rescan, no staleness handling

`rescanOnAppLifecycle` is a dead setting (B11). The inventory silently ages; the
status bar shows a relative timestamp and nothing acts on it. Minimum: rescan on app
activation when the data is older than N minutes, and on app launch/quit when the
setting is on.

### F4 — Export is clipboard-only and Markdown-only

`PLAN.md` §3.8 promises JSON / Markdown / CSV. Reality: `copyExportToPasteboard()`
and nothing else — no save panel, no JSON, no CSV, no share sheet. For a diagnostic
whose output ends up in bug reports, **"Save diagnostic report…"** (inventory +
health + macOS version + resolved SkyLight symbols + per-source timings) is the
obvious deliverable and does not exist.

### F5 — No row actions

`PLAN.md` §3.3 specifies a context menu: *Reveal config file*, *Open System Settings
pane*, *Copy as text*, *Investigate*, *Identify owner…*. None are implemented. The
evidence trail already carries `path` for every config-derived claim, so "Reveal in
Finder" is two lines and turns a diagnosis into an action. (#9 added it for Suspects;
the inventory is where it matters most.)

### F6 — Per-adapter enable/disable is not wired up

See B11. Settings shows adapter status read-only.

### F7b — Owner icons everywhere else

#9 shipped `OwnerIcon` and adopted it in Suspects. The inventory, the conflict list
and the claim cards all want it, and it is the cheapest change in the app with the
largest perceived-quality delta.

### F8 — Nothing surfaces *disabled* symbolic hotkeys

`PLAN.md` §3.7 lists "Disabled symbolic hotkeys" as a health check. The data is read
(`SymbolicHotKeyScanner` carries `enabled`) but no check reports it — and "I turned
Spotlight off two years ago and forgot" is a real cause of "my ⌘Space does nothing".

### F9 — The probe never re-runs on demand

Probing happens only as part of a full scan. After Detective narrows a suspect set
there is no "re-probe just this combination now" button, though
`ProbeRunner.sweep(combos:)` exists for exactly that.

### F10 — No menu bar extra

For a tool you reach for *at the moment a shortcut misfires*, requiring a window to
be found and focused is the wrong shape. See D7.

---

## 6. Visual and layout

### V3 — `FlowingChips` does not flow

`Views/ConflictsView.swift:135-161` uses `ViewThatFits(in: .horizontal)` with an
`HStack` and a `VStack`. That is a binary choice, not a wrap: six claimant chips
either fit on one line or become six full-height rows. A small `Layout` conformance
(~30 lines) would wrap to two lines and look intentional.

### V4 — The Overview's fourth card is a grey hole

`Views/HomeView.swift:192` —
`[Color(nsColor: .darkGray), Color(nsColor: .black).opacity(0.8)]` beside three
saturated gradients. It is also the only non-adaptive colour pair on the screen, so
in light appearance it is a dark slab. Give it a neutral-but-alive slate built from
the same palette.

### V5 — Only one screen has a background

`Palette.canvas` is applied in `HomeView` only. Inventory, Conflicts, Detective,
Suspects, Health and Settings use the default window background, so navigating away
from Overview looks like leaving the app for a plainer one.

### V6 — 168 pt cards with a 60 × 20 pt tap target

`Views/Palette.swift:91-99` puts a small "Review" capsule in the corner of a large
card; the card body is inert. Everything about the visual design says "press me";
about three per cent of the pixels do anything.

### V7 — Onboarding clips at larger text sizes

`Views/OnboardingView.swift:43, 48` — fixed `.frame(height: 400)` and
`.frame(width: 640)`, no `ScrollView`. At Accessibility text sizes, or in German, the
intro pane's three multi-line labels overflow and are silently cut off — including
the third, which explains what the app *cannot* do and is the entire point of that
pane.

### V8 — Keycaps look printed, not pressed

`Views/Components.swift` — a flat `controlBackgroundColor` fill with a 1 pt 18 %-alpha
stroke. Real Mac keycaps in Apple's own UI have a subtle vertical gradient, a lighter
top edge and a soft bottom shadow. This component appears on every screen and sets
the tone for the app; it deserves fifteen more lines.

### V9b — Animation beyond the Overview

#3 animated the Overview and the verdict panel. Everywhere else still snaps: the
conflict count jumps, sections appear instantly, list contents replace themselves
mid-scroll.

### V10 — The filter chip row hides half its controls

`Views/InventoryView.swift:84-107` puts ~14 chips in a horizontal `ScrollView` with
`showsIndicators: false`. The eight layer filters are off-screen with no hint they
exist. Wrap them, or move layer and status into a filter popover.

### V11 — Smaller

- Conflict-kind chips show all four kinds even at count 0.
- Health lists checks in construction order, so a red "Accessibility not granted" can
  sit below three green rows. Sort problems first.
- `ComboDetailView`'s "Copy" gives no feedback that anything happened.
- No app icon — see K1.

---

## 7. macOS-native interaction

### N1 — Settings is a sidebar item, not a `Settings` scene

⌘, does nothing at all, in an app about keyboard shortcuts.

### N2 — Search is a hand-rolled rounded rectangle

`Views/InventoryView.swift:48-73`. `.searchable(text:)` gives the native toolbar
field, the standard clear button, ⌘F focus and correct behaviour under Reduce
Transparency for free.

### N3 — No keyboard navigation, in a keyboard app **[most conspicuous irony]**

No ⌘F to focus search, no ⌘1…⌘7 for destinations, no ⌘⌥→ / ⌘⌥← between screens, no
`.focusable` on the recorder, no Return-to-investigate on a selected row.

### N4 — No Help menu, no About panel, no version anywhere in the UI

`CFBundleShortVersionString` is `0.1.0` and the user can never see it — which makes
bug reports worse for a tool whose entire output is bug-report material.

### N5 — Rescan lives in the View menu

`CommandGroup(after: .toolbar)` puts "Rescan", "Copy inventory as Markdown" and
"Reveal data folder" into **View**. They belong in File, or a dedicated Scan menu.

### N6 — The recorder's timeout is invisible

#3 raised it to 10 s and documented that Escape cancels, but there is still no
countdown or progress ring — the field simply stops listening.

### N7 — No way to re-open onboarding

Once `hasCompletedOnboarding` is set there is no path back, though the Accessibility
pane is the best explanation of the permission model in the app.

---

## 8. Aesthetics

The current design reads as *Material Design with SF Symbols*: saturated four-colour
gradient cards in an adaptive grid, coloured drop shadows, a hero banner with white
text on purple. That vocabulary signals "dashboard template". What signals "expensive
Mac app" is close to the opposite.

**Restraint over saturation.** One accent colour used sparingly, plus a lot of
neutral. Apple's own pro tools — Console, Instruments, Disk Utility — are
overwhelmingly grey with small bursts of colour that *mean* something. Shortking's
colour is currently decoration that happens to be documented as meaning. Keep the
semantic mapping, halve the saturation, let gradients live only on the hero.

**Materials over fills.** `Color(nsColor: .controlBackgroundColor).opacity(0.7)` is
everywhere; `.regularMaterial` with a hairline `.separator` border is what a native
panel looks like, and it responds correctly to Reduce Transparency and to the desktop
behind the window.

**Typography as hierarchy.** Almost everything is `.callout` or `.caption` with
`.secondary`. No display weight, no rhythm, and `.monospacedDigit()` appears once in
the whole app — so every changing number jitters.

**Density that respects the data.** A diagnostic should feel like it has a lot of
information under control. The Overview is four huge cards and a lot of air while
Conflicts is undifferentiated prose blocks. Invert it.

**Depth via elevation, not colour.** Replace the coloured `.shadow(color:)` calls
with a neutral two-layer shadow plus a 0.5 pt hairline. Coloured shadows are the
single strongest "Android template" tell in the current design.

Concrete:

- **A1** halve palette saturation; gradients on the hero only.
- **A2** `.regularMaterial` + hairline in place of `controlBackgroundColor` panels.
- **A3** neutral two-layer elevation; delete every `.shadow(color: <hue>)`.
- **A4** `.monospacedDigit()` on every changing number.
- **A5** real keycap treatment (V8).
- **A6** an app icon — a crown keycap is right there (K1).
- **A7** motion beyond the Overview (V9b).
- **A8** an 8 pt spacing scale. Current values: 3, 4, 6, 8, 9, 10, 11, 12, 14, 16,
  18, 22, 26, 28, with no system.
- **A9** a corner-radius scale. Currently 5, 7, 8, 9, 10, 12, 16, 18, 22.

---

## 9. Accessibility and internationalisation

- **X1** — `FilterChip` (`Views/Components.swift`) is a `Button` with
  `.buttonStyle(.plain)` carrying no selection trait, so VoiceOver announces
  "Conflicts only, button" whether it is on or off. Add
  `.accessibilityAddTraits(isOn ? .isSelected : [])`, or make it a `Toggle`.
- **X2** — `SummaryCard` correctly hides its decorative glyph but is not grouped, so
  VoiceOver reads title, value and caption as three unrelated elements.
- **X3** — `KeyComboBadge`'s spelled-out accessibility label is good work and should
  be the model for the rest.
- **X4** — Fixed-height onboarding breaks at large text sizes (V7).
- **X5** — Every string is a hard-coded literal. No `Localizable.xcstrings`, no
  `String(localized:)` discipline. Retrofitting later is far more expensive; `Plural`
  (added in #8) is shaped so its call sites survive the change.
- **X7** — The ANSI-only key map (B3) is an internationalisation bug with correctness
  consequences.

---

## 10. Safety, security, privacy

The dangerous paths are the best-engineered parts of this codebase. Worth stating so
nobody "simplifies" them:

- The probe runs in a separate short-lived process with `defer`-released
  registrations, signal handlers and a 120 s watchdog.
- Blackout has four independent restoration paths and never disables Universal Access
  shortcuts. The fallback that forces `.enabled` when the exact previous mode cannot
  be restored is exactly right — wrong-but-enabled beats disabled.
- Every SkyLight symbol is optional with a Health warning on absence.
- `JSONStore` quarantines unreadable files rather than deleting them.
- Shell-outs use absolute paths with fixed arguments and no user input.
- `zai-code-review.yml` gates `pull_request_target` on
  `head.repo.full_name == github.repository` with a pinned action SHA — the right way
  to use that trigger.

Outstanding:

- **S2** — `Analysis/HealthCheck.swift:160-181` creates a `CFMachPort` every run and
  disables but never invalidates it. Add `CFMachPortInvalidate(tap)`.
- **S3** — `AppState.relaunch()` builds a shell command by interpolating
  `Bundle.main.bundlePath`. Not attacker-controlled in practice, but a path
  containing `"` or `$` breaks it, and
  `NSWorkspace.openApplication(at:configuration:)` needs no shell at all.
- **S4** — `GenericPreferenceScanner` reads every preference domain in the user's
  home directory, including sandboxed containers. Necessary, and disclosed in the
  Settings copy — but onboarding should say plainly that **nothing leaves the
  machine**. A tool that reads every app's preferences and every keystroke's routing
  needs to say so out loud.
- **S5** — `README.md` and `AGENTS.md` say raw keyboard events are never stored. True,
  but `AttributionObservation` stores `comboKey` — *which* shortcut — with an owner
  and a timestamp, indefinitely, up to 20,000 entries. That is a record of which
  shortcuts were pressed and when. Benign and local, but the docs should describe it
  accurately, and "forget everything" should be reachable from somewhere more obvious
  than the bottom of Settings.

---

## 11. Build and packaging

*(#2 adds `ci.yml`, `release.yml`, `scripts/` and `CICD.md`. Scoped to what that does
not cover.)*

- **K1 — No app icon.** `Resources/` has no `.icns`, `Info.plist` has no
  `CFBundleIconFile`, the Makefile stages none. The Dock shows the generic
  blank-document icon. For an app arguing that it is high-value, this is the first
  and loudest signal to the contrary. Needs `iconutil`/`sips`, so it needs a Mac.
- **K2** — `PLAN.md` §17 says `LSUIElement=false`; `Info.plist` omits the key. Same
  effect, but the plan and the artifact should agree.
- **K3** — `NSAppleEventsUsageDescription` is present with the text "Shortking does
  not send Apple Events." Declaring a usage description for a capability you do not
  use invites a TCC prompt you do not want. Remove it.
- **K4** — Ad-hoc signing invalidates TCC grants on every build, which the Makefile
  warns about in a comment. Worth surfacing in Health too: "this build is ad-hoc
  signed, your permission grants will lapse on the next rebuild" is a
  first-day-of-development frustration the app is uniquely placed to explain.
- **K5 — No macOS runner is available, so `ci.yml` has never built anything.**
  **[blocks everything in §1]**

  `Test & assemble` fails in three to four seconds with no steps recorded and:

  ```
  labels:      ["macos-14"]
  runner_id:   0
  runner_name: ""
  ```

  No runner is ever assigned. A re-run an hour later behaved identically, so this
  is not transient queue exhaustion. The repository is **private**, where
  GitHub-hosted macOS runners bill at a **10× minute multiplier** — a job that
  never starts, on a private repo, with a `macos-*` label, is the standard
  signature of the Actions spending limit being reached.

  This is the single most consequential item in this document, because it is what
  stands between the project and knowing whether *any* of its code compiles. #2
  added CI on the explicit expectation that "the first CI run will be red, and the
  failures it reports are the useful output". It has reported nothing.

  Options, cheapest first: raise the Actions spending limit; make the repository
  public (macOS minutes are free for public repos); or attach a self-hosted macOS
  runner. Until one of them happens, `make app` on a Mac is the only way to find
  out what the compiler thinks.

- **K6** — `Review PR with GLM 5.2` fails on every pull request, including ones
  that predate this work, in about four seconds — the third-party action errors at
  startup. The workflow's skip step only guards the *absence* of `ZAI_API_KEY`, so
  an action failure goes red with no explanation. `continue-on-error: true` on the
  review step would make an advisory reviewer advisory again, instead of leaving
  every PR on the board looking broken.

---

## 12. Product ideas

Ranked by (value × distinctiveness) ÷ effort.

### D1 — The Throne Room: a live keyboard heat map

Render an actual keyboard. Four modifier toggles (⌃⌥⇧⌘) across the top; as they flip,
every key lights by claim status — green free, amber claimed-unknown, red conflicted,
grey restricted. Hover for the owner.

Turns a 2,000-row table into one glanceable image, is unlike anything the prior art
does, and every piece of data it needs already exists. It is also the screenshot that
sells the app.

### D2 — "Crown a new shortcut": the free-combination finder

The probe map is a *negative-space* map — the app already knows which combinations
are free. So let the user say "I want a shortcut for X" and have Shortking propose
combinations that are provably unclaimed, not ⌥-restricted, ergonomically sane, and
not shadowed by anything in the frontmost app. No other tool can do this, because no
other tool builds the negative-space map.

### D3 — Time machine: "it worked yesterday"

See F2. *"⌘⇧Space changed hands at 09:14 — it was Spotlight, it is now Raycast, which
launched at 09:12."* The answer to the question users actually arrive with, and
nearly free.

### D4 — Dogfood the free-combination finder for Shortking's own hotkey

Shortking should have a global hotkey, and should refuse to hard-code one. On first
launch it asks its own probe map for a free chord, proposes it, and says why. An app
about shortcut conflicts shipping a conflicting default would be the joke that writes
itself; making a virtue of avoiding it is genuinely charming, and it demonstrates D2
in the first thirty seconds.

### D5 — The layer ladder

`ComboDetailView` lists claims as cards. Draw them instead as the dispatch chain, top
to bottom, with the keystroke falling from Karabiner at layer 0 to the app menu at
layer 5 and being *caught* by the winner — the rest greyed below the catch point. One
diagram teaches the entire mental model the app is built on, currently explained in
three separate paragraphs of prose.

### D6 — The "gotcha" moment

When live capture names the owner, that is the payoff of the whole product, and it
currently appears as another grey row in a list. Give it the moment: the finding
lands with a spring, the named app's icon appears at full size. People tell other
people about moments like that.

### D7 — Blame HUD

A floating, always-on-top panel the size of a Spotlight window. Press any shortcut
anywhere; it shows the verdict instantly. The app collapsed to its single most useful
gesture, and the natural home for the menu bar extra (F10).

### D8 — The greediest app leaderboard

"Raycast holds 34 combinations. BetterTouchTool holds 61." Nobody knows this about
their own machine and everybody would want to. Trivial to compute from data already
in memory, and it makes the inventory feel like a discovery rather than a table.

### D9 — Shareable conflict card

One-click rendering of a conflict as a small image — the combination as keycaps, the
two contenders with icons, the layer ladder. Diagnostics that are pleasant to paste
into a GitHub issue get pasted into GitHub issues, and each one is an advertisement.

### D10 — Regnal voice, used once per screen

The app is called *Shortking* and has the personality of a compliance report. It does
not need jokes — but "Long live the king" as the all-clear state, "pretenders to the
throne" for competing claims, and a crown keycap as the icon would give it a
character that costs nothing and is remembered. Restraint is essential: one flourish
per screen, never in an error message, never in a technical explanation.

### D11 — Health, honestly, on the first screen

A single line — "Shortking can currently see 6 of 9 sources" — with a disclosure. The
project's whole differentiator is honesty about its own blind spots, and that honesty
is currently buried on a screen most users will never open.

---

## 13. Suggested order of work

**Needs a Mac with a toolchain, and nothing else should be judged until it is done:**

1. Build it. Clear whatever C1's siblings turn out to be.
2. **C3** — verify the SkyLight argument widths. Memory safety outranks everything
   below.
3. **B3** — the layout-aware key map. Every non-US user currently sees wrong keys and
   wrong groupings.

**Then the structural fix that unblocks the rest:**

4. **P1 + P2 + A1** together — real cancellation, blocking work off the cooperative
   pool, partial results on timeout. This is one change, and F1 (cancel a scan)
   falls out of it.

**Then the features that change what the product is:**

5. **F2 / D3** — the Changes screen. The data is already persisted.
6. **D1** — the keyboard heat map. The screenshot that sells the app.
7. **D2 / D4** — the free-combination finder, dogfooded for Shortking's own hotkey.

**Then the polish, which is cheap and compounds:**

8. **F7b** — owner icons everywhere (`OwnerIcon` already exists).
9. **A1–A9** — the aesthetic pass. Mostly deletion.
10. **N1–N5** — Settings scene, `.searchable`, keyboard navigation, menu placement.
11. **X5** — localisation groundwork, before the string count doubles again.
