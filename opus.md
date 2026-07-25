# Shortking — review

A full read of every source file, test, and build script in the repository at
`12dbe0f`, against the two questions the product exists to answer and against what
a paying user would expect a macOS app in 2026 to feel like.

**The design is genuinely good.** The layer model, the four-status honesty
contract, the negative-space probe, the "measure whether probing even works on this
machine" self-test, and the four independent blackout-restoration paths are all
correct, well-reasoned, and better than the prior art claims to be. The comments are
unusually load-bearing and mostly earn their keep.

**The execution has not met the design yet**, and the single biggest reason is
stated plainly in PR #1: *this codebase has never been compiled*. It was written on
Linux against a macOS-only API surface. Everything below is written with that in
mind — §1 is the set of things I believe will stop `swift build` outright or fail on
first launch, and it should be cleared before anything else is judged.

Findings carry stable IDs so they can be tracked, closed, and referenced from
commits. Line numbers are against `12dbe0f`.

---

## Contents

1. [Will not compile / will not work on first run](#1-will-not-compile--will-not-work-on-first-run)
2. [Correctness bugs](#2-correctness-bugs)
3. [Performance, stuttering, and responsiveness](#3-performance-stuttering-and-responsiveness)
4. [Architecture and code health](#4-architecture-and-code-health)
5. [Missing features](#5-missing-features)
6. [Visual and layout issues](#6-visual-and-layout-issues)
7. [Interaction design and macOS-native feel](#7-interaction-design-and-macos-native-feel)
8. [Aesthetics: from "mid Android app" to "high-value Mac app"](#8-aesthetics-from-mid-android-app-to-high-value-mac-app)
9. [Accessibility and internationalisation](#9-accessibility-and-internationalisation)
10. [Safety, security, and privacy](#10-safety-security-and-privacy)
11. [Build, packaging, and release](#11-build-packaging-and-release)
12. [Novel, delightful, and quirky ideas](#12-novel-delightful-and-quirky-ideas)
13. [What I am implementing now](#13-what-i-am-implementing-now)

---

## 1. Will not compile / will not work on first run

### C1 — Key paths into tuple elements (4 sites) **[blocker]**

`Sources/ShortkingApp/Views/Components.swift:34`
`Sources/ShortkingApp/Views/HomeView.swift:237, 262, 268`

```swift
ForEach(Array(combo.keycaps.enumerated()), id: \.offset) { _, cap in
ForEach(Array(state.appConflicts.prefix(5).enumerated()), id: \.element.id) { … }
```

`EnumeratedSequence.Element` is the tuple `(offset: Int, element: T)`, and Swift
does not permit key paths that address tuple components — `error: key path cannot
refer to tuple elements`. The author already knows this: `RootView.swift:111-115`
carries a comment explaining that `SidebarSection` is a struct rather than a tuple
*precisely because* "key paths into tuple elements are not expressible in Swift".
The `HomeView` and `Components` call sites contradict that comment.

Fix: index the collection directly (`Array(collection.enumerated())` →
`zip(collection.indices, collection)` with an explicit `Identifiable` shim, or
iterate `collection.indices`). The `.enumerated()` form is also wrong for a
`prefix()`-of-a-slice in principle; indices are clearer.

### C2 — `ShortkingApp` type shadows `ShortkingApp` module

`Package.swift:20` declares the executable target `ShortkingApp`, and
`Sources/ShortkingApp/ShortkingApp.swift:5` declares `struct ShortkingApp: App`
inside it. This is legal but is a known footgun: any future
`ShortkingApp.Something` reference inside the module resolves against the type, not
the module, and diagnostics become confusing. Rename the type to `ShortkingMainApp`
or the target to `ShortkingUI`. Low risk today, cheap to pre-empt.

### C3 — `CGSGetSymbolicHotKeyValue` argument widths are unverified

`Sources/ShortkingKit/Platform/SkyLight.swift:24-29` declares the modifier
out-parameter as `UnsafeMutablePointer<UInt64>`. The historical CGS signature uses a
32-bit `CGSModifierFlags`. Writing 8 bytes into a 4-byte caller slot is a stack
smash, not a wrong answer. `PLAN.md` §18 lists this as an open question; it is worth
promoting to a blocker, because it is silent memory corruption rather than a visible
failure. Mitigation: over-allocate deliberately and document it —

```swift
var modifiersStorage: (UInt64, UInt64) = (0, 0)   // deliberate slack
```

— or resolve the width by comparing against known-good IDs (64 = Spotlight) on
first run and disabling the live path if the value is implausible.

### C4 — Concurrency violations that are warnings in Swift 5 and errors in Swift 6

- `ScanCoordinator.swift:64-74` captures non-`Sendable` `ClaimSource` objects into
  `group.addTask`.
- `EventTapScanner.lastTaps` (`EventTapScanner.swift:70`) is written from a
  concurrent task and read from the main actor — an actual data race, not a
  formality.
- `ScanContext` is `@unchecked Sendable` (`ScanContext.swift:139`), which suppresses
  the diagnostic that would have caught the above.
- `ComboRecorder.startRecording` (`ComboRecorder.swift:101-107`) creates a bare
  `Task` from a non-isolated `View` method, so the timeout path calls
  `NSEvent.removeMonitor` and mutates `@State` **off the main thread**. AppKit event
  monitors are not thread-safe.

`Package.swift` pins `swiftLanguageVersions: [.v5]`, so these compile today. They
should still be fixed; C4d is a live crash risk.

---

## 2. Correctness bugs

### B1 — Input-source shortcuts are reported as a conflict with themselves **[user-visible false positive]**

`Sources/ShortkingKit/Scanners/ServicesScanner.swift:98-160`

`InputSourceScanner` reads symbolic hotkeys **60 and 61** and emits claims at
`layer: .inputSource` with owner `com.apple.HIToolbox`. `SymbolicHotKeyScanner`
sweeps IDs `0…300`, which *includes* 60 and 61, and emits claims at
`layer: .symbolic` with owner `com.apple.symbolichotkeys`. Different owner identity
⇒ different `Claim.identity` ⇒ both survive `ClaimMerger.merge`.

`ConflictAnalyzer.conflict(for:)` then sees two global claims at different layers
and reports a **`shadowed` conflict**: *"Input Sources holds ⌃Space at the Symbolic
layer … Input Sources claims it at the Input source layer, so it never fires."*

Every Mac with more than one input source enabled — which is most non-US users, and
anyone with an emoji-adjacent second layout — gets one or two fabricated conflicts
on the Conflicts screen and in the sidebar badge. It is the app accusing macOS of
fighting itself over a shortcut it owns once.

Fix: `InputSourceScanner` should not create claims for IDs the symbolic scanner
already covers. It should *enrich* those claims (attaching the input-source names as
evidence) or be limited to the case where the symbolic scanner is disabled.

### B2 — Menu shortcuts on shifted punctuation land in a different row from everything else

`Sources/ShortkingKit/Platform/AXBridge.swift:104-108` returns
`KeyCombo(keyCode: nil, character: char, …)` from `AXMenuItemCmdChar`. For an item
bound to ⇧⌘/ ("Help"), AX reports the character `?`. `KeyCodes.charToKeyCode` has no
entry for `?`, so `keyCode` stays `nil` and the grouping key is `"c?|m3"` — while the
probe, the symbolic scanner and every config adapter produce `"k44|m3"` for the same
physical shortcut.

Result: one shortcut, two rows, no conflict detected between them. The same applies
to `:` `<` `>` `~` `_` `+` `{` `}` `|` `"` and every other shifted glyph.

Fix: add a shifted-character → unshifted-character table to `KeyCodes` and consult
it in `KeyCombo.init` when the direct lookup fails.

### B3 — The whole key map is hard-coded to ANSI

`Sources/ShortkingKit/Model/KeyCodes.swift:12-21`

`charToKeyCode` and its inverse are a fixed US-ANSI table. On a German layout,
keycode `0x06` is `Y`, not `Z`; on AZERTY, `0x00` is `Q`, not `A`. Consequences:

- the inventory *displays the wrong key* for every character-derived combo;
- combos read as characters group under the wrong keycode, so real conflicts are
  missed and false ones are created.

Fix: build the table at runtime from the active layout via
`TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate`, falling back to the
ANSI table. This is the single highest-impact correctness fix for non-US users, and
it is invisible on the developer's own machine.

### B4 — `ClaimMerger` documents behaviour it does not implement

`Sources/ShortkingKit/Scan/ClaimMerger.swift:106-109`

```swift
// Restricted results are not conflicts, but they *are* answers: a shortcut
// that stopped working after the upgrade is explained by this, so it is
// recorded against the combination without ever becoming a claim.
return result
```

Nothing is recorded. `report.restricted` is used by `HealthChecker` and by
`AppState.verdict(for:)` (which recomputes the predicate itself), but never attached
to the combination. Either implement it or delete the claim in the comment — a
comment that describes absent behaviour is worse than no comment, because the next
reader will trust it.

### B5 — The sandwich taps silently die, in the app that exists to detect silently dying taps

`Sources/ShortkingKit/Detective/SandwichTaps.swift:284-287`

```swift
if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
    Log.detective.warning("Sandwich tap disabled by the system; it will be re-armed")
    return nil
}
```

Nothing re-arms it. The mask (`SandwichTaps.swift:95-97`) does not even subscribe to
those event types, so the callback will rarely see them; when it does, the tap stays
dead for the rest of the capture and the user is told "swallowed upstream" for a key
that was simply never observed. This is exactly the failure mode `HealthChecker.
deadTapCheck` exists to name in other people's apps.

Fix: add `tapDisabledByTimeout` / `tapDisabledByUserInput` to the mask and call
`CGEvent.tapEnable(tap:enable:true)` on receipt.

### B6 — `Shell.run`'s timeout cannot fire

`Sources/ShortkingKit/Platform/ProcessLookup.swift:72-82`

```swift
let data = pipe.fileHandleForReading.readDataToEndOfFile()   // blocks until EOF
let deadline = Date().addingTimeInterval(timeout)
while process.isRunning && Date() < deadline { usleep(20_000) }
```

`readDataToEndOfFile()` returns only when the child closes stdout, i.e. when it
exits. The polling loop below it runs *after* the blocking read, so the `timeout`
parameter is decorative. A wedged `nm` or `ioreg` hangs the calling task forever —
and both run inside scan sources whose "timeouts" also do not cancel (see P1).

Fix: read asynchronously (`readabilityHandler` + a `DispatchSemaphore` with a
deadline), or arm a `DispatchWorkItem` that terminates the process before reading.

### B7 — `ProbeRunner` can deadlock on a chatty helper

`Sources/ShortkingKit/Probe/ProbeRunner.swift:134-136` drains stdout to EOF, *then*
stderr. If the helper ever fills the 64 KB stderr pipe buffer while the parent is
blocked on stdout, both sides block forever. Today the helper writes little to
stderr, so this is latent rather than live — but `--help` and the watchdog message
both write there, and pipe-ordering deadlocks are the classic way this bites in
production. Read both concurrently.

### B8 — A single coincidental quit outranks "I don't know"

`Sources/ShortkingKit/Attribution/AttributionStore.swift:122-127`

```swift
let curve = 1 - exp(-0.45 * net)
return min(0.95, max(0.0, 0.3 + 0.65 * curve))
```

One `freedOnQuit` observation gives `net = 1` ⇒ confidence **0.535**, which exceeds
`probedClaimed`'s baseline of 0.5. So the first time you quit any app while a
combination happens to free up, Shortking replaces an honest "claimed, owner
unknown" with a *named* guess that the UI ranks *above* the honest state. The
confidence curve also has a discontinuity: it jumps from 0 straight to ≥0.53, so
there is no "weak hint" band at all.

The stated principle is "a wrong name is worse than no name". The curve should
require at least two independent observations before it crosses 0.5 — e.g. drop the
0.3 floor and start the curve at 0, or raise the minimum-confidence floor for
`inferredClaims` to 0.55 and let `net = 1` sit below it.

### B9 — "Clear caches" does not clear the caches

`Sources/ShortkingApp/AppState.swift:531-534`

```swift
func clearCaches() {
    MenuCache().clear()
    TriageCache().clear()
}
```

These construct *new* cache objects, whose `clear()` writes an empty JSON file. The
live `MenuBarScanner` and `BinaryTriage` instances inside `ScanCoordinator` still
hold their populated in-memory dictionaries and will overwrite the file on the next
`store(_:forKey:)`. The button appears to work and does nothing.

Fix: hold the cache instances on `AppState` (or expose `clearCaches()` on the
coordinator) and clear the ones actually in use.

### B10 — "Forget everything" leaves the inferred owners on screen

`Sources/ShortkingApp/AppState.swift:526-529` → `refreshInferences()` only *adds*
inferred claims to `result.claims`; it never removes ones that are no longer
supported. After resetting the attribution ledger the inventory keeps showing the
old inferred owners until the next full rescan. The destructive-action
confirmation promises "Owners it inferred will go back to 'unknown'"; they don't.

### B11 — Two dead settings

`Sources/ShortkingKit/Store/AppSettings.swift:14, 16`

- `rescanOnAppLifecycle` — declared, persisted, **never read anywhere**. The
  "rescan when apps launch or quit" behaviour does not exist.
- `disabledAdapters` — declared, persisted, never read. `AdapterRegistry.disabled`
  exists and is honoured (`AdapterRegistry.swift:94`), but nothing ever populates
  it, and the registry the UI reads (`AppState.adapterRegistry`) is a *different
  instance* from the one the coordinator scans with
  (`ScanCoordinator.defaultSources()`). Turning an adapter off is impossible, and
  the Settings screen offers no control for it either.

### B12 — `isScanning` can latch on forever

`Sources/ShortkingApp/AppState.swift:141-166`. If the scan task is ever cancelled,
`guard !Task.isCancelled else { return }` exits *before* `isScanning = false`, and
`rescan()`'s own `guard !isScanning` then blocks every future scan for the lifetime
of the process. Today the only `cancel()` call sits behind that same guard so it is
unreachable, but it is one added cancellation path away from being a hard hang.
Use `defer { isScanning = false }`.

### B13 — Duplicate ⌘R registration

`ShortkingApp.swift:23-24` (menu command) and `RootView.swift:33` (toolbar button)
both claim ⌘R. Two responders for one key equivalent, in an app whose entire purpose
is finding two responders for one key equivalent. Keep the menu command; give the
toolbar button `.help("Rescan (⌘R)")` and no shortcut.

### B14 — Duplicate `List` tags break selection in the grouped views

`Sources/ShortkingApp/Views/InventoryView.swift:194-210`. The by-owner and by-layer
lists flatten to *claims* but tag every row with `claim.combo.groupingKey`. Several
claims share a combination, so several rows carry the same tag; `List` selection
with duplicate tags highlights all of them and the detail pane's meaning becomes
ambiguous. Tag with the claim's own `id` and resolve the combo separately.

### B15 — `DetectiveSession.investigate` is not reachable when Detective is already open

`DetectiveView.swift:39-41` seeds its local `@State combo` in `.onAppear` only. Any
future call site that runs `state.investigate(combo:)` while Detective is already
the visible destination will update the session but not the recorder. Use
`.onChange(of: session.combo)` as well.

### B16 — The blackout result buttons work without a blackout

`DetectiveView.swift:129-136`. "It worked" / "Still broken" are always enabled, so a
user can record a high-confidence (0.85) finding about a test they never ran. Gate
them on a blackout having completed for the current combination.

### B17 — Minor / cosmetic correctness

- `Conflict.isIntermittent` (`Conflict.swift:61`) is dead code; `AppState` uses
  `kind == .contextual` directly.
- `ProbeSweep.claims(from:)` (`ProbeReport.swift:108`) is used only by tests;
  the live path is `ClaimMerger.applyProbeReport`.
- `AppState.unknownOwnerGroups` and `unattributedCount` compute the same filter
  twice (`AppState.swift:283, 439`).
- `Claim.symbolicID`'s setter (`SymbolicHotKeyScanner.swift:192-198`) can only
  write into evidence that already contains the key, so it is a no-op at every call
  site.
- `ConflictAnalyzer.shadowExplanation` says losers claim it "at the X layer or
  below" — in a model where *lower numbers win*, "below" reads as "wins", which is
  the opposite of what is meant.
- `Claim.identity` includes `label` (`Claim.swift:52-56`), so a menu item with a
  dynamic title ("Undo Typing" → "Undo Move") is a *new* claim every scan:
  `firstSeen` resets, `reconcile` never matches, and the persisted database grows
  without bound.
- `AttributionStore.inferences()` pins `ownerName` at first sight and never
  refreshes it, so a renamed app keeps its old name forever.
- `SecureInput.findHolder` (`SecureInput.swift:37`) runs `ioreg -d 1`, which limits
  output to the root node's own properties. `kCGSSessionSecureInputPID` normally
  lives under `IOConsoleUsers` on `IOResources`, one level deeper. Worth verifying
  on a real machine — if it is wrong, the "Held by X" line never appears and the
  check silently loses half its value.

---

## 3. Performance, stuttering, and responsiveness

### P1 — Per-source "timeouts" do not actually bound the scan

`Sources/ShortkingKit/Scan/ScanCoordinator.swift:149-196`

The pattern races the source against a `Task.sleep` inside a `withTaskGroup`, then
returns the timeout outcome. But **returning from a `withTaskGroup` body implicitly
awaits every remaining child task.** `group.cancelAll()` only sets the cancellation
flag; `MenuBarScanner`'s AX walk checks it once per *app*
(`MenuBarScanner.swift:48`), and `GenericPreferenceScanner` once per *plist*
(`GenericPreferenceScanner.swift:48`) — but the blocking work inside those
iterations is not interruptible at all.

So a scan that "timed out after 8 seconds" can still block for a minute, and the
user sees a spinner with no cancel button (see F1). The Health screen then reports
the source as failed and throws away every claim it *had* collected.

Two fixes, both needed:
1. Have sources return partial results rather than all-or-nothing on timeout.
2. Move blocking sources onto a `DispatchQueue` and detach them properly, so the
   coordinator's deadline is real.

### P2 — Blocking I/O on the cooperative thread pool

Every source runs as a `Task` on the shared cooperative pool, which is sized to the
core count. `MenuBarScanner` (synchronous AX IPC), `GenericPreferenceScanner`
(up to 1,500 synchronous `NSDictionary(contentsOfFile:)` reads),
`UserKeyEquivalentScanner` (one `CFPreferencesCopyValue` per installed bundle ID —
several hundred cfprefsd round-trips), and `BinaryTriage` (`nm` per app, 15 s each)
all block their thread outright. On an 8-core machine, four of these saturate half
the pool and starve every other `async` operation in the process, including
SwiftUI's own work. This is the structural cause of scan-time stutter.

### P3 — Cache write amplification is O(n²) **[the worst single perf bug]**

`Sources/ShortkingKit/Scanners/MenuBarScanner.swift:178-184`

```swift
public func store(_ entries: [MenuEntry], forKey key: String) {
    lock.lock()
    storage[key] = Entry(entries: entries, storedAt: Date())
    let snapshot = storage          // full copy
    lock.unlock()
    persistence?.save(snapshot)     // full JSON re-encode of EVERY app, to disk
}
```

Called **once per running app**. With 40 apps and a menu cache that reaches a few
megabytes, a cold scan performs 40 full serialisations and 40 atomic file
replacements of a growing document — quadratic in the number of apps.
`TriageCache.store` (`BinaryTriage.swift:124-130`) has the identical shape and is
called once per *installed* app, so ~300 full rewrites when binary triage is on.

Compounding it: `JSONStore.save` uses `.prettyPrinted` **and** `.sortedKeys`
(`JSONStore.swift:80`), which roughly doubles the byte count and adds a sort of
every key on every write, for a file no human reads.

Fix: mark the cache dirty and flush once at the end of a scan (or debounce), and
drop pretty-printing for the machine-read caches.

### P4 — Search re-filters and re-allocates on every keystroke, twice

`AppState.filteredGroups` (`AppState.swift:212-243`) is a computed property that
walks every group, and for a text query calls `claim.searchTokens` — which builds a
**fresh array of lowercased Strings** for every claim, on every evaluation
(`Claim.swift:63-73` → `KeyCombo.searchTokens`, `KeyCombo.swift:106-117`). With
~2,000 claims × ~8 tokens that is ~16,000 String allocations per pass.

`InventoryView` evaluates it **twice per render** — once for the row list
(`InventoryView.swift:181`) and once for the "N of M" counter
(`InventoryView.swift:121`) — and there is no debounce on the `TextField`. Typing
"raycast" is 7 renders × 2 passes × 16,000 allocations.

Fix: precompute a single lowercased search string per claim at construction time,
cache the filtered result keyed on the filter inputs, and debounce the query by
~150 ms.

### P5 — Health checks run synchronously on the main actor after every scan

`AppState.swift:149-153` calls `HealthChecker.run(...)` on the `@MainActor`. That
function performs, on the main thread:

- `AXBridge.canReadOwnMenuBar()` — an AX round trip with a **1-second** messaging
  timeout (`AXBridge.swift:39`);
- `CGEvent.tapCreate` — a TCC-mediated call;
- when secure input is on, a full `ioreg` subprocess whose timeout does not work
  (B6).

Every scan therefore ends with a main-thread stall of up to a second or more. It is
the most likely explanation for "the window freezes when it finishes scanning".

**Worse:** `OnboardingView`'s status poller (`OnboardingView.swift:52-57`) calls
`state.accessibilityWorks` — the same 1-second AX call — **once per second on the
main actor**, for as long as the sheet is open. The onboarding sheet can spend most
of its life blocked.

### P6 — Launch does a full decode + conflict analysis on the main thread

`AppState.init` (`AppState.swift:118-126`) synchronously loads `claims.json`,
JSON-decodes it, then runs `ClaimMerger.group` + `ConflictAnalyzer.analyze` over
every claim — all before the first frame. On a machine with a large accumulated
inventory this is a visible cold-start delay. It should be a `Task` that populates
the view after first paint, with a skeleton state in the meantime.

Related: `AppState` constructs its own `ClaimDatabase()` while `ScanCoordinator`
constructs another (`ScanCoordinator.swift:29`), so the file is parsed twice and
held in memory twice.

### P7 — `SettingsView` hits the filesystem on every body evaluation

`AppState.adapterStatuses` (`AppState.swift:447-449`) calls
`AdapterRegistry.statuses()`, which calls `detectedPaths()` on every adapter —
`FileManager.fileExists` plus two `contentsOfDirectory` walks (JetBrains, Hammerspoon).
It is read directly from `SettingsView.body` (`SettingsView.swift:89`), so **every
toggle flip re-stats the disk**. Compute once per scan and cache.

### P8 — Every settings change writes JSON to disk on the main thread

`AppState.swift:81-84`: `@Published var settings { didSet { settingsStore.update … } }`
and `SettingsStore.update` calls `store.save(settings)` synchronously. Each toggle,
each picker change, and every post-scan `probingVerified` update is a synchronous
pretty-printed write on the main actor.

### P9 — Differential learning re-probes on every app launch and quit, forever

`DifferentialEngine.handle(notification:)` (`DifferentialEngine.swift:100-129`)
debounces by 1.5 s and then spawns the probe helper to register/unregister **every
combo in the last report** (~490 at `common`, ~2,000 at `exhaustive`). There is no
minimum interval between re-probes, no cap on how many run per hour, and no
suspension on battery or Low Power Mode. On a machine where apps come and go all day
this is a continuous background cost, and every sweep is a window in which the
user's own keystrokes can be briefly swallowed by the probe.

### P10 — Smaller items

- `ComboRow` builds a `Set` and sorts it on every row render
  (`InventoryView.swift:248`).
- Five coloured `.shadow` modifiers on the Overview (four cards + hero) each force
  an offscreen pass; noticeable while scrolling on integrated GPUs.
- `AppState.runningApps` (`AppState.swift:443-445`) re-snapshots `NSWorkspace` and
  constructs a `Bundle` per running app on every access; it is a computed property,
  so any future use inside a view body would be pathological.
- `MenuCache` is never pruned, so entries for uninstalled apps persist forever.

---

## 4. Architecture and code health

### A1 — Sources are all-or-nothing on failure

`SourceOutcome` carries `claims: []` whenever a source throws or times out
(`ScanCoordinator.swift:159-187`). A scanner that read 900 of 1,000 preference
domains before its deadline contributes **nothing**. Given P1/P2, the heaviest and
most valuable sources are the ones most likely to be discarded. `SourceOutcome`
should carry partial claims alongside the error.

### A2 — `AppState` is doing four jobs

It is the view model, the scan orchestrator, the settings owner, the export
formatter, and the process-lifecycle manager (`relaunch`, `quit`, `openSettingsPane`).
577 lines with a computed `verdict(for:)` engine embedded in it. `Verdict` is
domain logic and belongs in `ShortkingKit` next to `ConflictAnalyzer`, where it can
be unit-tested — it currently has zero test coverage despite being the single most
user-visible piece of reasoning in the app.

### A3 — The `Claim.identity` string is doing structural work

`"\(layer.rawValue)|\(ownerPart)|\(combo.groupingKey)|\(labelPart)"` is parsed by
nothing and compared by everything. A `struct ClaimKey: Hashable` with typed fields
would make B17's label-churn problem obvious at the type level and remove a class of
delimiter-injection bugs (an owner named `a|b` collides with `a` + `b`).

### A4 — Test coverage has a shape-shaped hole

`AnalysisTests` is genuinely good — it pins the ⌥-hardening classification, the
session-tap-must-not-absorb-probe-evidence rule, and the confidence asymmetry.
But there is **no test at all** for:

- `AppState.verdict(for:)` (untestable where it lives — see A2);
- `ClaimMerger.reconcile` (the function that makes `firstSeen` meaningful);
- `Claim.merge` (the disabled-anywhere-means-disabled rule);
- `ComboGroup.winner` tie-breaking at equal layers;
- `JSONC.strip` against a real `keybindings.json` with `//` inside a string literal —
  the exact case the hand-written stripper exists for;
- `GenericPreferenceScanner.extract` against all three library signatures.

`AdapterTests.swift` covers the parsers; the merge/reconcile layer between them and
the UI is the part with no net.

### A5 — Logging is well-organised and under-used

`Log` has seven categories and is called ~15 times. There is no timing telemetry
(per-source durations exist in `SourceOutcome` but are never logged or surfaced), so
"why was that scan slow" is unanswerable from a bug report. Log the per-source
duration table at `.info` on every scan and show it in Health.

---

## 5. Missing features

Ordered by how much they'd change the product.

### F1 — No way to cancel a scan

The Rescan button disables itself while scanning (`RootView.swift:32`). With P1
meaning a scan can run far past its nominal deadline, there is no escape. A Cancel
affordance in the status bar is table stakes.

### F2 — No history, no diff, no "what changed" **[biggest missed opportunity]**

`ClaimDatabase` already persists the full inventory on every scan, and `firstSeen` /
`lastConfirmed` already exist on every claim. The app throws away the one thing that
would answer the actual user question — *"this worked yesterday"* — for free.

A **Changes** screen showing "since your last scan / since yesterday / since this
app updated: 3 claims appeared, 1 disappeared, Raycast took ⌘⇧Space" would be the
single most valuable feature in the product and is nearly already built.

### F3 — No auto-rescan, no staleness handling

`rescanOnAppLifecycle` is a dead setting (B11). The inventory silently ages; the
status bar shows a relative timestamp but nothing acts on it. At minimum: rescan on
app activation if the data is older than N minutes, and on app launch/quit when the
setting is on.

### F4 — Export is clipboard-only and Markdown-only

`PLAN.md` §3.8 promises "export inventory as JSON / Markdown / CSV". Reality:
`copyExportToPasteboard()` and nothing else — no save panel, no JSON, no CSV, no
share sheet. For a diagnostic tool whose output ends up in bug reports, "Save
diagnostic report…" (inventory + health + macOS version + resolved SkyLight symbols
+ per-source timings) is the obvious deliverable and does not exist.

### F5 — No row actions

`PLAN.md` §3.3 specifies a context menu: *Reveal config file*, *Open System Settings
pane*, *Copy as text*, *Investigate*, *Identify owner…*. None are implemented. The
evidence trail already carries the `path` detail for every config-derived claim, so
"Reveal in Finder" is a two-line addition that turns a diagnosis into an action.

### F6 — Per-adapter enable/disable is not wired up

See B11. The Settings screen shows adapter status read-only.

### F7 — No app icons anywhere

Owners are rendered as plain text. `NSWorkspace.shared.icon(forFile:)` on
`Owner.path` would make the inventory, the conflict list and the suspect list
instantly scannable, and is the single cheapest change with the largest perceived
quality delta.

### F8 — Nothing surfaces *disabled* symbolic hotkeys

`PLAN.md` §3.7 lists "Disabled symbolic hotkeys" as a health check. The data is read
(`SymbolicHotKeyScanner` carries `enabled`) but no check reports it, and "I turned
Spotlight off two years ago and forgot" is a real cause of "my ⌘Space does nothing".

### F9 — The probe never re-runs on demand

Probing happens only as part of a full scan. After Detective narrows a suspect set,
there is no "re-probe just this combination now" button, even though
`ProbeRunner.sweep(combos:)` exists precisely for that.

### F10 — No menu bar extra

For a tool you reach for *at the moment a shortcut misfires*, requiring a window to
be found and focused is the wrong shape. A menu bar item with "What just ate my
shortcut?" would match the moment of need.

---

## 6. Visual and layout issues

### V1 — The keycap column truncates long combinations

`HomeView.swift:339-340` and `InventoryView.swift:229-230` both wrap
`KeyComboBadge` in `.frame(width: 130-132, alignment: .leading)`. A badge with fn ⌃
⌥ ⇧ ⌘ and a wide key label ("PageDown", "Space") needs well over 130 pt; SwiftUI
proposes 130 anyway and the `HStack` of keycaps compresses, so the keycaps squash and
the key text truncates. The *combination* is the primary key of the entire UI — it
is the one thing that must never be clipped. Use a `minWidth` plus `.fixedSize()`.

### V2 — The blackout banner scrolls out of view

`DetectiveView.swift:26-28` puts the "Global hotkeys are disabled" banner inside the
`ScrollView`, as the first child. Scroll down and the countdown, the warning and the
**Restore now** button all disappear. `README.md` promises "A full-width banner with
a countdown and a Restore now button is visible the entire time." It is not. Given
this is the app's most dangerous state, it must be a `safeAreaInset(edge: .top)`.

### V3 — `FlowingChips` doesn't flow

`ConflictsView.swift:135-161` uses `ViewThatFits(in: .horizontal)` with an `HStack`
and a `VStack`. That is a binary choice, not a wrap: six claimant chips either fit
on one line or become six full-height rows. A real flow layout (a small `Layout`
conformance, ~30 lines) would wrap to two lines and look intentional.

### V4 — The Overview's fourth card is a grey hole

`HomeView.swift:192`: `[Color(nsColor: .darkGray), Color(nsColor: .black).opacity(0.8)]`
sits beside three saturated gradients. It is also the only non-adaptive colour pair
on the screen — `.darkGray` and `.black` are fixed, so in light appearance it is a
dark slab. Give it a neutral-but-alive slate gradient built from the same palette.

### V5 — Only one screen has a background

`Palette.canvas` is applied in `HomeView` only (`HomeView.swift:47`). Inventory,
Conflicts, Detective, Suspects, Health and Settings all use the default window
background, so navigating away from Overview looks like leaving the app and entering
a different, plainer one.

### V6 — Cards are 168 pt tall with a 60 × 20 pt tap target

`SummaryCard` (`Palette.swift:91-99`) puts a small "Review" capsule in the corner of
a large card; the card body itself is inert. Everything about the visual design says
"press me"; only 3 % of the pixels do anything.

### V7 — Onboarding clips at larger text sizes

`OnboardingView.swift:43, 48`: fixed `.frame(height: 400)` and `.frame(width: 640)`
with no `ScrollView`. At Accessibility text sizes — or in German — the intro pane's
three multi-line labels overflow and are silently cut off, including the third one
that explains what the app *cannot* do, which is the whole point of that pane.

### V8 — Keycaps look printed, not pressed

`KeyComboBadge` (`Components.swift:40-47`) is a flat `controlBackgroundColor` fill
with a 1 pt 18 %-alpha stroke. Real Mac keycaps in Apple's own UI have a subtle
vertical gradient, a lighter top edge and a soft bottom shadow. This one component
appears on every screen and sets the tone for the whole app; it deserves 15 more
lines.

### V9 — Nothing animates, ever

`withAnimation` and `.transition` appear zero times in the codebase. Sections appear
and vanish instantly when a scan lands, the verdict panel pops in, the conflict count
jumps. A single `.animation(.smooth, value: state.result.finishedAt)` on the Overview
and a `.transition(.opacity.combined(with: .move(edge: .top)))` on the verdict would
change the perceived quality more than any amount of colour work.

### V10 — The filter chip row hides half its controls

`InventoryView.swift:84-107` puts ~14 chips in a horizontal `ScrollView` with
`showsIndicators: false`. The eight layer filters are off-screen with no visual hint
that they exist. Wrap them, or move layer/status into a proper filter popover.

### V11 — Smaller items

- Conflict-kind chips show all four kinds even at count 0
  (`ConflictsView.swift:59-69`).
- The Health screen lists checks in construction order, so a red "Accessibility not
  granted" can sit below three green rows.
- `ComboDetailView`'s "Copy" gives no feedback that anything happened.
- No app icon (see §11), so the Dock shows the generic blank document.

---

## 7. Interaction design and macOS-native feel

### N1 — Settings is a sidebar item, not a Settings scene

`Destination.settings` lives in the sidebar. macOS apps put preferences behind
⌘, in a `Settings` scene. Today ⌘, does nothing at all — in an app about keyboard
shortcuts.

### N2 — Search is a hand-rolled rounded rectangle

`InventoryView.swift:48-73` builds a custom search field. `.searchable(text:)` gives
the native toolbar field, the standard clear button, ⌘F focus, and correct behaviour
under Reduce Transparency for free.

### N3 — No keyboard navigation, in a keyboard app

There is no ⌘F to focus search, no ⌘1…⌘7 for sidebar destinations, no ⌘⌥→ / ⌘⌥← to
move between screens, no `.focusable` on the recorder, no Return-to-investigate on a
selected row. This is the app's single most conspicuous irony.

### N4 — No Help menu, no About panel, no version anywhere in the UI

`CFBundleShortVersionString` is `0.1.0` and the user can never see it — which makes
bug reports worse for a tool whose entire output is bug-report material.

### N5 — Rescan lives in the View menu

`CommandGroup(after: .toolbar)` (`ShortkingApp.swift:22`) puts "Rescan", "Copy
inventory as Markdown" and "Reveal data folder" into **View**. They belong in File,
or in a dedicated Scan menu.

### N6 — The recorder's 6-second timeout is arbitrary and invisible

`ComboRecorder.swift:102`. No countdown, no progress ring — the field simply stops
listening and shows a paragraph of explanatory text. Either show the countdown or
listen until explicitly stopped.

### N7 — No way to re-open onboarding

Once `hasCompletedOnboarding` is set there is no path back, even though the
Accessibility pane is the best explanation of the permission model in the app.

---

## 8. Aesthetics: from "mid Android app" to "high-value Mac app"

The current design reads as *Material Design with SF Symbols*: saturated four-colour
gradient cards in an adaptive grid, coloured drop shadows, a hero banner with white
text on purple. That vocabulary signals "dashboard template". What signals "expensive
Mac app" is almost the opposite:

**Restraint over saturation.** One accent colour, used sparingly, plus a lot of
neutral. Apple's own pro tools (Console, Instruments, Disk Utility) are
overwhelmingly grey with tiny bursts of colour that *mean* something. Right now
Shortking's colour is decoration that happens to be documented as meaning.
Recommendation: keep the semantic mapping, drop the saturation by half, and let the
gradients live only on the hero.

**Materials over fills.** `Color(nsColor: .controlBackgroundColor).opacity(0.7)`
appears everywhere; `.regularMaterial` / `.thickMaterial` with a hairline
`.separator` border is what a native panel looks like in 2026, and it responds
correctly to Reduce Transparency and to the desktop behind the window.

**Typography as hierarchy.** Almost everything is `.callout` or `.caption` with
`.secondary`. There is no rhythm — no display weight, no monospaced numerals for
counts (`.monospacedDigit()` appears once, in the sidebar badge), no consistent
measure. Numbers that change (claim counts, conflict counts, countdowns) should all
be monospaced-digit so they don't jitter.

**Density that respects the data.** A diagnostic tool should feel like it has a lot
of information under control. Right now the Overview is four huge cards and a lot of
air, while the Conflicts screen is undifferentiated prose blocks. Invert it: tighter
Overview tiles, more structured conflict rows.

**Depth via elevation, not colour.** Replace the coloured `.shadow(color:)` calls
with a neutral, subtle two-layer shadow (a tight dark shadow plus a wide soft one)
and a 0.5 pt hairline. Coloured shadows are the single strongest "Android template"
tell in the current design.

**Iconography that is drawn, not picked.** SF Symbols everywhere is correct for
controls, but the four Overview cards each carry an 84 pt symbol at 18 % white as
decoration. A custom set of four small illustrations — or nothing at all — would read
as considered.

**Concrete list:**

- A1: halve palette saturation; keep gradients for the hero only.
- A2: replace `controlBackgroundColor` panels with `.regularMaterial` + hairline.
- A3: neutral two-layer elevation; delete every `.shadow(color: <hue>)`.
- A4: `.monospacedDigit()` on every changing number.
- A5: real keycap treatment for `KeyComboBadge` (V8).
- A6: a proper app icon (a crown keycap is right there).
- A7: motion — `.smooth` animations on data changes, `.transition` on verdicts.
- A8: a consistent 8 pt spacing scale; current values are 3, 4, 6, 8, 9, 10, 11,
  12, 14, 16, 18, 22, 26, 28 with no system.
- A9: consistent corner radii; currently 5, 7, 8, 9, 10, 12, 16, 18, 22.

---

## 9. Accessibility and internationalisation

- **X1** — `FilterChip` (`Components.swift:238-257`) is a `Button` with
  `.buttonStyle(.plain)` that carries no selection trait, so VoiceOver announces
  "Conflicts only, button" whether it is on or off. Add
  `.accessibilityAddTraits(isOn ? .isSelected : [])`, or make it a `Toggle` with a
  button style.
- **X2** — `SummaryCard`'s decorative glyph is correctly hidden, but the card is not
  grouped, so VoiceOver reads title, value and caption as three unrelated elements.
- **X3** — `KeyComboBadge`'s accessibility label is good work and should be the model
  for the rest.
- **X4** — Fixed-height onboarding (V7) breaks at large text sizes.
- **X5** — Every string is a hard-coded literal; there is no `Localizable.xcstrings`
  and no `String(localized:)` discipline. Retrofitting later is far more expensive.
- **X6** — Lazy pluralisation: `"process(es)"`, `"claim(s)"`, `"cycle(s)"`,
  `"source(s)"`, `"observation(s)"`, `"event tap(s)"` across seven files. This is the
  most visible "cheap software" tell in the entire UI — a user reading "1 claim(s)"
  has been told the developer didn't care. SwiftUI's automatic grammar agreement
  (`^[\(n) claim](inflect: true)`) or a two-line helper fixes all of them.
- **X7** — ANSI-only key map (B3) is an internationalisation bug with correctness
  consequences.

---

## 10. Safety, security, and privacy

This section is mostly praise; the dangerous paths are the best-engineered parts of
the codebase.

**Correct and worth keeping:**

- The probe runs in a separate short-lived process with `defer`-released
  registrations, signal handlers and a 120 s watchdog. This is the right call and
  `AGENTS.md` correctly enshrines it as an invariant.
- Blackout has four independent restoration paths and never disables Universal
  Access shortcuts. The `restore()` fallback that forces `.enabled` when the exact
  previous mode cannot be restored is exactly right — "wrong but enabled beats
  disabled".
- Every SkyLight symbol is optional with a Health warning on absence.
- `JSONStore` quarantines rather than deletes unreadable files.
- Shell-outs use absolute paths with fixed arguments and no user input.
- `zai-code-review.yml` correctly gates `pull_request_target` on
  `head.repo.full_name == github.repository`, with a pinned action SHA. That is the
  right way to use that trigger.

**Worth tightening:**

- **S1** — `signal(sig) { _ in exit(2) }` in `ShortkingProbe/main.swift:31-35` calls
  `exit()` from a signal handler. `exit()` runs `atexit` handlers and flushes stdio;
  it is not async-signal-safe. Use `_exit(2)`.
- **S2** — `HealthChecker.inputMonitoringCheck` creates a `CFMachPort` every run and
  disables but never invalidates it (`HealthCheck.swift:160-181`). Add
  `CFMachPortInvalidate(tap)`.
- **S3** — `AppState.relaunch()` builds a shell command by string interpolation of
  `Bundle.main.bundlePath` (`AppState.swift:506`). The path is not attacker-controlled
  in practice, but a bundle path containing `"` or `$` breaks it, and
  `NSWorkspace.openApplication(at:configuration:)` needs no shell at all.
- **S4** — `GenericPreferenceScanner` reads every preference domain in the user's
  home directory, including sandboxed containers. That is necessary and disclosed in
  the Settings copy, but the app should state explicitly — in the privacy copy and in
  onboarding — that **nothing leaves the machine**, because a tool that reads every
  app's preferences and every keystroke's routing needs to say so out loud.
- **S5** — `README.md` and `AGENTS.md` say raw keyboard events are never stored. That
  is true, but `AttributionObservation` stores `comboKey` (which shortcut) alongside
  an owner and a timestamp, indefinitely, up to 20,000 entries. That is a record of
  which shortcuts the user pressed and when. It is benign and local, but the docs
  should describe it accurately, and "forget everything" should be reachable from
  somewhere more obvious than the bottom of Settings.

---

## 11. Build, packaging, and release

*(PR #2 is open and adds `ci.yml`, `release.yml`, `scripts/` and `CICD.md`. Items
here are scoped to what that PR does not cover.)*

- **K1 — No app icon.** `Resources/` contains no `.icns`, `Info.plist` has no
  `CFBundleIconFile`, and the Makefile stages none. The Dock shows the generic
  blank-document icon. For an app arguing that it is high-value, this is the first
  and loudest signal to the contrary.
- **K2 — No `LSUIElement` decision documented.** `PLAN.md` §17 says
  "`LSUIElement=false`"; `Info.plist` simply omits the key. Same effect, but the plan
  and the artifact should agree.
- **K3 — `NSAppleEventsUsageDescription` is present with the text "Shortking does not
  send Apple Events."** Declaring a usage description for a capability you do not use
  invites a TCC prompt you do not want. Remove it.
- **K4 — Ad-hoc signing invalidates TCC grants on every build**, which the Makefile
  warns about in a comment. Worth surfacing in the Health screen too: "this build is
  ad-hoc signed, your permission grants will lapse on the next rebuild" is a
  first-day-of-development frustration the app is uniquely positioned to explain.
- **K5 — `make app` does not verify the helper actually landed.** (PR #2 adds this
  assertion in CI; a local `make app` check would catch it earlier.)

---

## 12. Novel, delightful, and quirky ideas

Ranked by (value × distinctiveness) ÷ effort.

### D1 — The Throne Room: a live keyboard heat map

Render an actual keyboard. Four modifier toggles (⌃⌥⇧⌘) across the top; as you flip
them, every key lights up by claim status — green free, amber claimed-unknown, red
conflicted, grey restricted. Hover a key for the owner.

This turns a 2,000-row table into a single glanceable image, is unlike anything the
prior art does, and every piece of data it needs already exists. It is also the
screenshot that sells the app.

### D2 — "Crown a new shortcut": the free-combination finder

The probe map is a *negative-space* map — the app already knows which combinations
are free. So let the user say "I want a shortcut for X" and have Shortking propose
combinations that are (a) provably unclaimed, (b) not ⌥-restricted, (c) ergonomically
sane, and (d) not shadowed by anything in the frontmost app. No other tool can do
this, because no other tool builds the negative-space map.

### D3 — Time machine: "it worked yesterday"

See F2. The database is already there. *"⌘⇧Space changed hands at 09:14 — it was
Spotlight, it is now Raycast (which launched at 09:12)."* This is the answer to the
question users actually arrive with, and it is nearly free.

### D4 — Dogfood the free-combination finder for Shortking's own hotkey

Shortking should have a global hotkey — and it should refuse to hard-code one.
On first launch it asks its own probe map for a free chord, proposes it, and says
why. An app about shortcut conflicts that shipped a conflicting default shortcut
would be the joke that writes itself; making a virtue of avoiding it is genuinely
charming, and it demonstrates D2 in the first thirty seconds.

### D5 — The layer ladder

`ComboDetailView` currently lists claims as cards. Draw them instead as the dispatch
chain, top to bottom, with the keystroke falling from Karabiner at layer 0 to the app
menu at layer 5 and being *caught* by the winner — the rest greyed out below the
catch point. One diagram teaches the entire mental model the app is built on, which
is currently explained in three separate paragraphs of prose.

### D6 — The "gotcha" moment

When live capture names the owner, that is the payoff of the entire product and it
currently appears as another grey row in a list. Give it the moment: the app's icon
animates, the finding lands with a spring, the named app's icon appears at full size.
Users tell other people about moments like that.

### D7 — Blame HUD

A floating, always-on-top panel the size of a Spotlight window. Press any shortcut
anywhere; it shows the verdict instantly. No window switching, no navigation — it is
the app collapsed to its single most useful gesture, and it is the natural home for
the menu bar extra (F10).

### D8 — The greediest app leaderboard

"Raycast holds 34 combinations. BetterTouchTool holds 61." Nobody knows this about
their own machine, everybody would want to. Trivial to compute from data already in
memory, and it makes the inventory feel like a discovery rather than a table.

### D9 — Shareable conflict card

One-click rendering of a conflict as a small image (the combination as keycaps, the
two contenders with icons, the layer ladder). Diagnostics that are pleasant to paste
into a GitHub issue get pasted into GitHub issues, and each one is an advertisement.

### D10 — Regnal voice, used once per screen

The app is called *Shortking* and has the personality of a compliance report. It does
not need jokes — but "Long live the king" as the all-clear state, "pretenders to the
throne" for competing claims, and a crown keycap as the app icon would give it a
character that costs nothing and is remembered. Restraint is essential: one flourish
per screen, never in an error message, never in a technical explanation.

### D11 — Health, honestly, on the first screen

A single-line "Shortking can currently see 6 of 9 sources" with a disclosure. The
project's whole differentiator is honesty about its own blind spots; that honesty is
currently buried on a screen most users will never open.

---

## 13. What I am implementing now

Chosen for high confidence in both *value* and *correctness*, given that no Swift
toolchain exists in this environment and nothing here can be compiled before it is
pushed. Each is a separate branch and PR, deliberately file-disjoint to minimise
conflicts.

| PR | Branch | Items |
|---|---|---|
| 1 | `claude/fix-foreach-tuple-keypaths` | C1, C4d, V1 (Overview), V9 (verdict transition) |
| 2 | `claude/fix-input-source-duplicate-claims` | B1, B4, F8 + tests |
| 3 | `claude/fix-inventory-perf-and-selection` | P4, P5, B9, B10, B12, B14, V1 (Inventory) |
| 4 | `claude/fix-cache-write-amplification` | P3 |
| 5 | `claude/fix-subprocess-timeouts` | B6, B7, S1 |
| 6 | `claude/fix-detective-safety-and-plurals` | B5, B16, V2, X6 |
| 7 | `claude/feat-owner-icons` | F7 (Suspects), V11 |

Deliberately **not** attempted here, and why:

- **B3 (layout-aware key map)** — needs `UCKeyTranslate` against a real HIToolbox and
  a Mac to verify against. Getting it wrong is worse than the current ANSI
  assumption. Belongs in a session with a compiler.
- **C3 (SkyLight argument widths)** — must be verified on a real machine; a guess
  here is a memory-safety change made blind.
- **P1/P2 (real scan cancellation, blocking work off the cooperative pool)** — a
  structural change to the scan pipeline. High value, but it needs to be built and
  run, not written and hoped for.
- **F2/D1/D2/D7 (Changes screen, keyboard map, free-combination finder, HUD)** — new
  surfaces, each several hundred lines of SwiftUI that cannot be previewed here.
  They are the right next work, with a build.
- **K1 (app icon)** — producing an `.icns` requires `iconutil`/`sips`, which are
  macOS-only.
- **N1/N2/N3 (Settings scene, `.searchable`, keyboard navigation)** — each is a
  small change but they interact with window and focus behaviour that has to be seen
  to be trusted.
