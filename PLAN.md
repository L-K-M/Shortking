# Shortking — UI & Implementation Plan

> **Shortking** — *the king of shortcuts*. A macOS diagnostic tool that answers two questions:
>
> 1. **What key combinations are currently claimed on this machine, by whom, and at what layer?**
> 2. **I just pressed ⌘⇧G and the wrong thing happened. Who ate it?**

Target: macOS 26 (Tahoe), Apple Silicon + Intel, Developer ID + notarization (**not** App Store —
per-pid event taps and cross-app preference reads are incompatible with App Sandbox).

This document is the build plan. It is derived from the research bootstrap document
(`macos-hotkey-inventory-design.md`) and turns it into concrete modules, types, screens and
milestones.

---

## Table of contents

1. [Product shape](#1-product-shape)
2. [Core principle: honest confidence](#2-core-principle-honest-confidence)
3. [UI design](#3-ui-design)
4. [Architecture](#4-architecture)
5. [Module inventory](#5-module-inventory)
6. [Data model](#6-data-model)
7. [The scan pipeline](#7-the-scan-pipeline)
8. [Probing (the negative-space map)](#8-probing-the-negative-space-map)
9. [Attribution](#9-attribution)
10. [Detective Mode](#10-detective-mode)
11. [Health checks](#11-health-checks)
12. [Persistence](#12-persistence)
13. [Private API strategy](#13-private-api-strategy)
14. [Packaging, permissions, distribution](#14-packaging-permissions-distribution)
15. [Testing strategy](#15-testing-strategy)
16. [Milestones](#16-milestones)
17. [Repository layout](#17-repository-layout)
18. [Open questions / de-risking](#18-open-questions--de-risking)

---

## 1. Product shape

Shortking is a **single-window SwiftUI app** plus a **short-lived privileged-free helper CLI**
(`shortking-probe`) that performs the hotkey probe sweep in a separate process so that a crash
mid-sweep cannot leave the user's keyboard hijacked.

It is a *diagnostic* tool, not a shortcut manager. It never rebinds anything on the user's behalf.
The only system state it mutates is transient and always restored:

- temporary `RegisterEventHotKey` registrations during a probe sweep (released immediately, in the
  helper process, with a signal handler and a watchdog);
- the global hotkey operating mode during a Blackout bisection (restored on `defer`, on signal, and
  on a hard watchdog timer).

Everything else is read-only.

### Non-goals

- Rebinding or editing shortcuts. (We link out to System Settings / the owning app.)
- A cheat-sheet overlay (KeyCue's job).
- Running under App Sandbox / shipping on the Mac App Store.
- Kernel extensions or a virtual HID driver (§5.8 "own the layer" — wrong trade for a diagnostic).

---

## 2. Core principle: honest confidence

Every binding Shortking shows carries an explicit **layer**, **status** and **confidence**, and the
UI never renders an inference as a fact. This is the single most important design constraint; it is
what separates Shortking from the prior art, which silently omits everything it cannot enumerate.

Four statuses, surfaced as first-class UI states with distinct colours and iconography:

| Status | Meaning | Confidence | UI treatment |
|---|---|---|---|
| `known` | Read directly from a config file, plist, or the Accessibility API. Exact. | 1.0 | Solid, named |
| `probedClaimed` | Registration was refused → *someone* holds this combo at the WindowServer layer, owner unknown. | 0.5 | Dashed border, "Unknown owner" + **Identify…** action |
| `inferred` | Attributed by differential observation or side-channel correlation. | 0.3 – 0.95, rising with observations | Named, with a confidence meter and an expandable evidence trail |
| `capability` | This process *can* intercept keystrokes (event tap installed / `RegisterEventHotKey` imported) but no specific binding is known. | 0.1 | Listed in **Suspects**, never in the combo table as an owner |

A row that says *"⌘⇧G — claimed at the WindowServer layer by an app I can't name. Want me to find
out? It'll take 4 app restarts."* is more useful than a row that isn't there.

---

## 3. UI design

### 3.1 Window shell

`NavigationSplitView` — a sidebar with six destinations, a detail pane, and a persistent bottom
status bar showing last-scan time, permission health dot, and a **Rescan** button.

```
┌────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   Shortking                                          [⌘R Rescan]     │
├──────────────┬─────────────────────────────────────────────────────────────┤
│              │                                                             │
│  INVENTORY   │                                                             │
│  ▸ All combos│                       (detail pane)                         │
│  ▸ Conflicts │                                                             │
│              │                                                             │
│  INVESTIGATE │                                                             │
│  ▸ Detective │                                                             │
│  ▸ Suspects  │                                                             │
│              │                                                             │
│  SYSTEM      │                                                             │
│  ▸ Health    │                                                             │
│  ▸ Settings  │                                                             │
│              │                                                             │
├──────────────┴─────────────────────────────────────────────────────────────┤
│ ✔ Accessibility  ✔ Input Monitoring   1,284 claims · 37 conflicts · 2m ago │
└────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 All combos (the inventory)

A **grouped-by-combo table**. The unit of the UI is the *key combination*, not the *claim* — because
the user's mental model is "what happens when I press this", and conflicts are only visible when
claims are collocated.

- **Left column**: the combo, rendered as a `KeyComboBadge` — real glyphs (⌃⌥⇧⌘) in canonical order,
  monospaced, with the keycap-styled key at the end.
- **Middle**: claimant summary. One owner → name + icon. Several → "3 claimants" with a stacked
  layer strip showing which layers are involved.
- **Right**: a status chip — `OK`, `Conflict`, `Shadowed`, `Unknown owner`, `Disabled`.

Controls above the table:

- **Search field** that accepts *both* text (`"Spotlight"`, `"Raycast"`, `"Go to Folder"`) and a
  literal key combo. A **record button** in the field lets the user press the actual keys — this is
  the fastest path from "⌘⇧G did the wrong thing" to the answer.
- **Filter chips**: Layer (Virtual HID / HID tap / Session tap / WindowServer / Symbolic / App menu /
  Service / Input source), Status, Owner, "Conflicts only", "Enabled only".
- **Group-by** toggle: by Combo (default) / by Owner / by Layer.

Expanding a row reveals each individual `Claim`: owner, label, layer badge, status, confidence
meter, enabled toggle state, and a disclosure with the full **evidence trail** (`config file at
~/.skhdrc line 42`, `AX menu path File ▸ Go to Folder…`, `probe returned -9878`, `freed when Raycast
quit, 7/7 observations`).

Row actions (context menu): *Reveal config file*, *Open System Settings pane*, *Copy as text*,
*Investigate in Detective Mode*, *Identify owner…*.

### 3.3 Conflicts

The same table filtered and sorted by severity, with conflicts classified:

- **Definite** — two global claims on the same combo. The lower layer wins; we say which and why.
- **Contextual** — a global claim vs. an app-local menu equivalent. Only bites when that app is
  frontmost; we name the app.
- **Shadowed** — a stack where a strictly lower layer wins outright, with the losers listed.
- **Unattributed** — probe says taken, nobody claims it. Offers the **Identify owner…** flow.

Each conflict carries a plain-language explanation sentence generated from the layer comparison, and
a **suggested resolution** that is always advisory (never automatic): *"Raycast holds ⌘Space at the
WindowServer layer, ahead of Spotlight's symbolic hotkey 64. Disable Spotlight's binding in System
Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Spotlight, or rebind Raycast."*

### 3.4 Detective

The screen for question 2. A guided, stateful investigation of a *single* combo.

```
   ┌──────────────────────────────────────────────────────────┐
   │  Which shortcut misbehaved?                               │
   │                                                           │
   │            ┌──────────────────────────┐                   │
   │            │      ⌘  ⇧  G             │  [Record]         │
   │            └──────────────────────────┘                   │
   │                                                           │
   │  What we already know                                     │
   │   • Probe: CLAIMED (eventHotKeyExistsErr, -9878)          │
   │   • No configured claim matches this combo                │
   │   • 3 processes have active session taps                  │
   │                                                           │
   │  ▸ Run live capture      (needs Input Monitoring)         │
   │  ▸ Run blackout test     (disables global hotkeys ~5s)    │
   │  ▸ Identify by restart   (4 apps · ~2 min)                │
   └──────────────────────────────────────────────────────────┘
```

Three techniques, each a card that can be run independently, each streaming results into a shared
**verdict panel**:

1. **Live capture** — arms the sandwich taps (§5.4) *and* the per-pid `systemDefined` sniffer (§5.3),
   then asks the user to press the combo. Reports, in order of decisiveness:
   - a named pid from the sniffer (*"Raycast received hotkey `0x600002a1c4e0`"*), or
   - a swallow classification from the sandwich (*"seen at session tap, gone by annotated tap →
     swallowed between the two: a filtering tap or a WindowServer hotkey"*), or
   - a delivery target (*"delivered to Finder"*).
2. **Blackout test** — flips `CGSSetGlobalHotKeyOperatingMode` to disable-all for a bounded window,
   asks the user to retry, and branches: *works now* → layer 3 Carbon hotkey; *still broken* → event
   tap, Karabiner remap, secure input, or the app itself. A large, unmissable banner shows that
   hotkeys are currently disabled, with a countdown and a **Restore now** button.
3. **Identify by restart** — the differential binary search (§5.2). Presents the candidate set,
   estimates the number of quit/relaunch cycles (log₂ n), and walks the user through them one at a
   time with live progress. Never quits anything itself — it asks, and detects.

Below the cards, a **side-channel** strip (§5.6) that is always on during a live capture: within
~200 ms of the press it lists CPU-spiking processes, newly created windows, and activation changes,
cross-referenced against the `CGGetEventTapList` suspect set. This is the only technique that works
against event-tap claimants, so it runs unconditionally as a fallback.

### 3.5 Suspects

The `CGGetEventTapList` panel — *"these 6 processes can intercept keystrokes."* One row per tap:
process name + icon, tap point (HID / session / annotated / per-pid), active-filter vs. listen-only,
the decoded event mask (as chips: `keyDown`, `flagsChanged`, `systemDefined`, …), enabled flag, and
latency stats. Disabled taps are flagged — a tap whose `enabled` is false is a *cause*, and a common
one after an app re-sign.

A second section, **Capability triage**, lists installed apps whose binaries import
`RegisterEventHotKey` / `CGEventTapCreate` / `CGSSetHotKey*` (static `nm -u` scan, cached by path +
mtime). This narrows ~300 installed apps to the ~20 worth investigating, and covers apps that are not
running.

### 3.6 Health

The non-conflict failure modes from §9 of the research doc, each as a check with a status, an
explanation, and a fix action:

| Check | Detection |
|---|---|
| Accessibility grant | `AXIsProcessTrusted()` + a functional probe (walk our own menu bar) |
| Input Monitoring grant | attempt a listen-only tap; treat "created but never fires" as failure |
| Secure input mode stuck on | `IsSecureEventInputEnabled()`; culprit via `ioreg -l -w 0 \| grep SecureInput` |
| Option-only restriction | probe ⌥-only and ⌥⇧-only combos, match `-9868` |
| Dead event taps | `CGGetEventTapList` `enabled == false` for taps we've seen enabled before |
| Disabled symbolic hotkeys | `enabled: false` in `AppleSymbolicHotKeys` / `CGSIsSymbolicHotKeyEnabled` |
| Our own tap health | heartbeat; re-arm on `tapDisabledByTimeout` / `…ByUserInput` |
| Private-symbol availability | which SkyLight symbols resolved on this OS build |

The functional probe matters: `AXIsProcessTrusted()` can return `true` when launched from a terminal
that holds Accessibility, and event taps can silently die after a re-sign while TCC still reports
granted. We verify by *doing*, not by asking.

### 3.7 Settings

- Scan scope: which sources are enabled (menus are the slow one — a toggle and a "menus only for
  frontmost app" mode).
- Probe: on/off, sweep breadth (Common ~600 / Wide ~2,000 / Exhaustive), interval, and whether to
  probe with exclusion.
- Differential learning: on/off, confidence decay, "forget everything" button.
- Data: store location, export inventory as JSON / Markdown / CSV, reset attribution DB.
- Adapters: the list of config adapters with per-adapter enable and detected-path status.

### 3.8 Onboarding

A three-pane flow shown on first launch and re-entered from Health when a grant lapses:

1. What Shortking does and, explicitly, what it *cannot* know (sets expectations for the
   "unknown owner" state before the user meets it).
2. Accessibility grant — with a live status dot that flips when the grant lands, and a note that a
   relaunch may be needed.
3. Input Monitoring grant — framed as optional, unlocking Detective Mode only.

### 3.9 Visual language

- `KeyComboBadge`: keycap-styled, canonical modifier order ⌃⌥⇧⌘, glyph rendering for arrows,
  Return/Tab/Escape/Delete, and the F-keys.
- `LayerBadge`: eight fixed colours, always in the same order, always with the layer number — the
  number is what makes "lower layer wins" legible.
- `ConfidenceMeter`: a 5-segment bar; anything below 1.0 is visually distinct from a solid read.
- Dark mode and Increase Contrast supported; every colour-coded state also carries a glyph and text,
  never colour alone.

---

## 4. Architecture

Three targets in one Swift package:

```
ShortkingKit  (library)     — model, sources, probe, attribution, detective, analysis, store
ShortkingApp  (executable)  — SwiftUI app, @main, views, AppState
ShortkingProbe(executable)  — short-lived CLI helper; performs the sweep, prints JSON, exits
```

Splitting the probe into its own process is a correctness requirement, not tidiness: a successful
`RegisterEventHotKey` that is never released hijacks that combo for the lifetime of the process. A
helper that exits after ~2 seconds gives us guaranteed OS-level cleanup even if it crashes.

Data flow:

```
       ┌──────────────┐
       │ ScanCoordinator                                     │
       └──────┬───────┘
              │ fan-out (async let / TaskGroup), per-source timeouts
   ┌──────────┼───────────────────────────────────────────────┐
   │          │            │           │          │           │
 MenuBar  Symbolic   UserKeyEquiv   Services  InputSource  EventTap
 Scanner  Scanner      Scanner       Scanner    Scanner    Scanner
   │          │            │           │          │           │
   └──────────┴─────┬──────┴───────────┴──────────┴───────────┘
                    │                        ┌─────────────────┐
              AdapterRegistry ───────────────┤ config adapters │
                    │                        └─────────────────┘
                    ▼
              ClaimMerger  ◄──── ProbeSweep (helper process)
                    │       ◄──── AttributionStore (differential inferences)
                    ▼
              ClaimDatabase ──► ConflictAnalyzer ──► AppState ──► SwiftUI
```

Concurrency: sources are `async` and run concurrently in a `TaskGroup` with a per-source timeout, so
one hung AX call (a beachballed app) cannot stall a scan. `AppState` is `@MainActor`; everything
below it is actor-isolated or value-typed.

Failure policy: a source that throws or times out degrades to a warning surfaced in the status bar
and Health, never an empty inventory and never a crash. This applies doubly to private symbols — a
missing `CGSGetSymbolicHotKeyValue` on a future OS disables the live symbolic path and falls back to
the plist, silently and correctly.

---

## 5. Module inventory

| Module | Responsibility | Research §|
|---|---|---|
| `Model/` | `KeyCombo`, `Modifiers`, `KeyCodes`, `ClaimLayer`, `Owner`, `Evidence`, `Claim`, `Conflict` | 11 |
| `Platform/SkyLight` | `dlopen`/`dlsym` bridge for CGS/SLS private symbols, version-gated, graceful | 3.1, 8 |
| `Platform/CarbonHotKey` | `RegisterEventHotKey` wrapper, error-code taxonomy | 5.1 |
| `Platform/AX` | `AXUIElement` helpers, messaging timeouts, attribute reads | 4.1 |
| `Platform/SecureInput` | `IsSecureEventInputEnabled` + culprit lookup | 3.6, 9 |
| `Scanners/MenuBarScanner` | AX menu walk of running apps, cached by (bundleID, version) | 4.1 |
| `Scanners/SymbolicHotKeyScanner` | plist + live CGS iteration over IDs 0…300, labelled | 4.2 |
| `Scanners/UserKeyEquivalentScanner` | `NSUserKeyEquivalents` across domains + `.GlobalPreferences` | 4.3 |
| `Scanners/ServicesScanner` | `pbs.plist` → `NSServicesStatus` → `key_equivalent` | 4.4 |
| `Scanners/InputSourceScanner` | `com.apple.HIToolbox` input-source switching | 4.5 |
| `Scanners/EventTapScanner` | `CGGetEventTapList` → suspect list + capability claims | 4.6 |
| `Scanners/BinaryTriage` | `nm -u` symbol scan of installed apps, cached | 4.8 |
| `Adapters/` | Karabiner, skhd, Hammerspoon, VS Code/Cursor, JetBrains, Rectangle | 4.7 |
| `Adapters/GenericPrefs` | MASShortcut / ShortcutRecorder / `KeyboardShortcuts` signatures | 4.7, 5.7 |
| `Probe/` | probe space, sweep runner, helper-process driver, result decoding | 5.1 |
| `Attribution/Differential` | launch/quit observation, diffing, confidence accumulation | 5.2 |
| `Attribution/SideChannel` | rusage / window / activation correlation | 5.6 |
| `Detective/Sniffer` | per-pid listen-only `systemDefined` taps | 5.3 |
| `Detective/Sandwich` | session + annotated tap pair, swallow classification | 5.4 |
| `Detective/Blackout` | global hotkey operating mode toggle with hard restore guarantees | 5.5 |
| `Analysis/ConflictAnalyzer` | grouping, winner determination, conflict classification | 9 |
| `Analysis/HealthCheck` | the §9 failure modes | 9 |
| `Store/` | Codable JSON database, atomic writes, migration | 11 |

---

## 6. Data model

Close to the research doc's sketch, with two deliberate deviations.

**Evidence is a struct, not an enum with associated values.** Enums with associated values are
painful to encode/decode stably and impossible to extend without breaking persisted data. Shortking
uses `Evidence { kind: Kind, summary: String, detail: [String: String], observedAt: Date }` — same
information, forward-compatible, and it renders directly as a key/value disclosure in the UI.

**`KeyCombo` carries both a keycode and a character**, normalising between them at construction via
an ANSI layout table, and hashes on a `groupingKey` that prefers the keycode. Sources disagree about
which they can provide (AX gives a character *or* a virtual key *or* a glyph; skhd gives a name;
symbolic hotkeys give a keycode); grouping has to work across all of them.

```swift
struct Modifiers: OptionSet          // command, shift, option, control, function
struct KeyCombo                      // keyCode: UInt16?, character: String?, modifiers
enum  ClaimLayer: Int, Comparable    // 0 virtualHID … 7 inputSource; lower wins
enum  ClaimStatus: String            // known, probedClaimed, inferred, capability
struct Owner                         // bundleID, name, path, pid, kind
struct Evidence                      // kind, summary, detail, observedAt
struct Claim                         // id, combo, layer, status, owner?, label?, enabled,
                                     // evidence[], confidence, firstSeen, lastConfirmed
struct ComboGroup                    // combo + [Claim] + resolved winner + conflict?
struct Conflict                      // kind (.definite/.contextual/.shadowed/.unattributed),
                                     // combo, winner?, losers[], explanation, severity
```

`Claim.identity` — a stable string derived from `(layer, owner.bundleID, combo.groupingKey, label)` —
is what lets a rescan *update* `lastConfirmed` and merge new evidence into an existing record instead
of duplicating it, which is what makes differential confidence accumulate across sessions.

---

## 7. The scan pipeline

1. **Enumerate context**: running apps (`NSWorkspace.runningApplications`), installed app bundles
   (`/Applications`, `~/Applications`, `/System/Applications`), and the preference-domain list.
2. **Fan out** to every enabled `ClaimSource` in a `TaskGroup`, each with its own timeout
   (menus: 10 s total, 250 ms per app-menu-bar AX call; others: 5 s).
3. **Merge** by `Claim.identity`: union evidence, take max confidence, refresh `lastConfirmed`,
   preserve `firstSeen`.
4. **Overlay probe results**: for each combo the probe reports as claimed, if no `known` claim at the
   WindowServer layer exists, synthesise a `probedClaimed` claim with no owner. If a `known` claim
   *does* exist, the probe result becomes corroborating evidence on it instead (confidence stays 1.0,
   and the probe evidence explains *why* the combo also shows as taken).
5. **Overlay attribution**: fold in `inferred` claims from the attribution store, with confidence
   from the observation count.
6. **Analyse**: group by combo, resolve winners by layer, classify conflicts.
7. **Publish** to `AppState`, persist to disk.

Caching: the menu walk is the expensive step. Cache per `(bundleID, shortVersion, buildVersion)` with
a 24-hour TTL, invalidated on app version change. Never expand menus by pressing them — read
attributes only, or dynamic items (Recent Files, Window lists) churn the cache every scan.

---

## 8. Probing (the negative-space map)

The sweep runs in `shortking-probe`, which:

1. Builds the probe space: ~130 interesting keycodes × ~15 modifier sets, filtered by mode
   (Common / Wide / Exhaustive).
2. For each `(keyCode, modifiers)`: `RegisterEventHotKey` → on `noErr`, record `.free` and
   `UnregisterEventHotKey` **immediately in a `defer`**; on failure, record `.claimed` with the
   `OSStatus`.
3. Classifies error codes: `-9878` (`eventHotKeyExistsErr`) = genuinely taken; `-9868`
   (`eventInternalErr`) on ⌥-only / ⌥⇧-only = the Sequoia hardening, **not** a conflict — emitted as
   `.restricted` so it never becomes a false-positive conflict; anything else → `.unknown` with the
   raw code, logged for later triage.
4. Installs `SIGINT`/`SIGTERM`/`SIGSEGV` handlers and a wall-clock watchdog that unregister
   everything and exit, so a hang or crash cannot leave combos held.
5. Prints a JSON `ProbeReport` on stdout and exits.

The app drives it with `Process`, a hard timeout, and JSON decoding. If the helper is missing or
fails, probing degrades to "unavailable" in Health rather than failing the scan.

Open question resolved at runtime, not compile time: whether cross-process conflict surfaces
distinguishably (Experiment A, §18). The probe records the raw `OSStatus` for every cell precisely so
that a self-test — register a combo in-process, then probe it — can *measure* the machine's actual
behaviour on first run and disable the probe feature with an explanation if duplicate registration
turns out to be permitted. This self-test ships as part of the first-run flow.

---

## 9. Attribution

**Differential (§5.2).** A background observer subscribes to `NSWorkspace`
`didLaunchApplicationNotification` / `didTerminateApplicationNotification`. On each transition
(debounced ~1.5 s to let lazy registration settle) it re-probes *only the currently-interesting
subset* — the claimed set plus recently-changed cells — and diffs:

- combo became **free** when app X quit → evidence for X owning it;
- combo became **claimed** when app X launched → evidence for X owning it;
- contradicting observation → evidence against, decrementing confidence.

Confidence from observations, saturating and asymmetric (one contradiction costs more than one
confirmation gains):

```
confidence = clamp(0.3 + 0.65 · (1 − exp(−0.45 · (supporting − 2 · contradicting))), 0.0, 0.95)
```

Never reaches 1.0 — an inference is never a direct read. A single observation lands at ~0.30
("hypothesis"); seven consistent observations reach ~0.90.

Ambiguity is handled honestly: if two apps launched within the debounce window, the observation is
recorded against *both* with halved weight and flagged `ambiguous`, rather than being attributed to
whichever notification arrived first.

**Guided identification.** The "Identify owner…" flow binary-searches the candidate set rather than
linear-scanning: partition the running suspects, ask the user to quit half, re-probe, recurse.
log₂(n) restarts instead of n. Note that `SIGSTOP` does **not** release WindowServer registrations
(the connection holds them, not the thread), so suspension is not a substitute for termination —
this is flagged in the UI so users don't try it.

**Side channel (§5.6).** Within a ~200 ms window after a press: `proc_pid_rusage` deltas across all
processes, `CGWindowListCopyWindowInfo` diffs for new windows, and
`didActivateApplicationNotification`. Cross-referenced against the tap suspect list, this converges
in one or two presses and is the *only* technique that works against event-tap claimants, which have
nothing to enumerate and nothing to probe.

---

## 10. Detective Mode

**Sniffer (§5.3).** Listen-only per-pid taps masked on `NX_SYSDEFINED` (14) across the suspect set
(tap-list processes ∪ binary-triage hits ∪ frontmost app), *not* every running process — N taps for N
apps is too heavy for anything but a bounded, on-demand capture. In the callback, `NSEvent(cgEvent:)`
→ `subtype == 6` (key down) / `9` (key up), `data1` = the hotkey identifier. Because `data1` is the
malloc'd `HotButtonData` pointer, it is a stable per-registration identity within that process's
lifetime, so we can tell "Raycast has three hotkeys" from "Raycast has one".

Capture sessions are bounded (default 30 s), tear down every tap on exit, and are the only place the
app installs taps.

**Sandwich (§5.4).** Two listen-only taps — A at `kCGSessionEventTap` head-insert, B at
`kCGAnnotatedSessionEventTap` tail-append, both masked on `keyDown` — with events correlated by
`(keycode, flags, timestamp)` inside a short window:

| A | B | Conclusion |
|---|---|---|
| ✅ | ✅ | Delivered — target read from `kCGEventTargetUnixProcessID` |
| ✅ | ❌ | Swallowed between the two: filtering tap or WindowServer hotkey |
| ❌ | ❌ | Swallowed upstream: HID-level tap or virtual HID remap (Karabiner) |

HID-level taps require root; Shortking does not ship a privileged helper for this. The session/
annotated pair covers the cases that matter, and the ❌/❌ row already tells the user to look at
Karabiner.

**Blackout (§5.5).** `CGSSetGlobalHotKeyOperatingMode(cid, .disableAllButUniversalAccess)` for a
bounded window. Safety is non-negotiable: the previous mode is captured first, restored on `defer`,
on `SIGINT`/`SIGTERM`, on app termination (`NSApplicationWillTerminate`), and by an independent
watchdog timer that fires even if the UI is wedged. A full-width banner with a countdown and a
**Restore now** button is visible the entire time. Leaving a user's hotkeys globally disabled is a
catastrophic bug and is treated as one.

---

## 11. Health checks

Implemented as independent `HealthCheck` values, each returning `.ok` / `.warning` / `.failing` /
`.unknown` with a message, a detail string, and an optional action (open a System Settings pane,
reveal a file, copy a diagnostic). Run on launch, on every scan, and on window focus. See the table
in §3.6.

---

## 12. Persistence

`~/Library/Application Support/Shortking/`:

```
claims.json            latest merged inventory (for instant cold start)
attribution.json       differential observation ledger, the long-lived asset
probe-history.json     recent probe reports (bounded ring, 20 entries)
menu-cache.json        AX menu results keyed by bundleID + version
triage-cache.json      nm results keyed by path + mtime + size
settings.json          user preferences
```

All writes are atomic (write to a temp file, `replaceItemAt`). Every file carries a `schemaVersion`;
a version we don't recognise is moved aside rather than parsed, so a downgrade cannot corrupt the
attribution ledger. `firstSeen` / `lastConfirmed` persist so confidence accumulates across launches —
the attribution ledger is the thing that gets more valuable the longer Shortking is installed, and it
is the file we protect hardest.

---

## 13. Private API strategy

All private symbols go through **one file** (`Platform/SkyLight.swift`) that `dlopen`s
`/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight` and `dlsym`s each symbol, trying the
`SLS*` name first and falling back to the `CGS*` alias. Every symbol is optional; every call site
checks availability and degrades:

| Symbol | Used for | Fallback if missing |
|---|---|---|
| `SLSMainConnectionID` | connection for symbolic/blackout calls | disable both features |
| `CGSGetSymbolicHotKeyValue` | live symbolic hotkey enumeration | `com.apple.symbolichotkeys.plist` only |
| `CGSIsSymbolicHotKeyEnabled` | live enabled state | plist `enabled` flag |
| `CGSGetGlobalHotKeyOperatingMode` | capture state before blackout | disable blackout |
| `CGSSetGlobalHotKeyOperatingMode` | blackout | disable blackout |

A missing symbol is a Health warning naming the symbol and the disabled feature, never a crash, and
never silent. The resolved/unresolved table is visible in Health so a bug report says exactly which
symbols this OS build has.

---

## 14. Packaging, permissions, distribution

Swift Package Manager, no `.xcodeproj`. `make app` assembles a real `.app` bundle from the SPM build
products (the app binary, the probe helper in `Contents/MacOS/`, `Info.plist`, entitlements), because
TCC identity is bundle- and signature-based — running the bare executable from `.build/` will get you
lied to by `AXIsProcessTrusted()`.

| Capability | Requires | Feature it gates |
|---|---|---|
| AX menu walk | Accessibility | Menu inventory |
| Read other apps' prefs | no sandbox | `NSUserKeyEquivalents`, adapters, generic sniffing |
| `CGGetEventTapList` | nothing | Suspects |
| `RegisterEventHotKey` probe | nothing | Negative-space map |
| Listen-only session tap | Input Monitoring | Sandwich |
| Per-pid tap | Input Monitoring, no sandbox | Sniffer |
| CGS/SkyLight symbols | nothing technically | Symbolic live path, Blackout |

Hardened runtime, Developer ID signing, notarization, stapling. `make dmg` produces the shippable
artifact. The §7 verification experiments must be re-run against each new macOS major version — they
are shipped as the first-run self-test rather than living only in a lab.

---

## 15. Testing strategy

Unit tests cover everything that is pure logic and does not need a Mac's live state:

- `Modifiers` round-trips: Carbon mask ↔ Cocoa flags ↔ AX inverted mask ↔ `@$~^` strings.
- `KeyCombo` normalisation and grouping-key stability across sources that supply only a character,
  only a keycode, or only a glyph.
- Adapter parsers against fixture files: skhd, Karabiner JSON, VS Code JSONC (comments and trailing
  commas), JetBrains XML, Hammerspoon Lua, `KeyboardShortcuts` JSON blobs.
- `ConflictAnalyzer`: winner determination, contextual vs. definite vs. shadowed classification,
  and — importantly — that a `restricted` probe result never produces a conflict.
- Confidence accumulation: monotonic under confirmation, penalised under contradiction, capped
  below 1.0.
- `Evidence` / `Claim` Codable round-trips and schema-version handling.

The live-system paths (AX, taps, CGS, probe) are covered by the first-run self-test and by a
`--selftest` flag on the app, not by unit tests — they need a real WindowServer and real TCC grants.

---

## 16. Milestones

**M1 — Inventory (parity with the prior art).** Model, scan pipeline, AX menus, symbolic hotkeys,
`NSUserKeyEquivalents`, Services, input sources, the four core config adapters, grouped-by-combo UI
with conflict highlighting, persistence, health basics.

**M2 — The differentiator.** `CGGetEventTapList` Suspects panel, the probe sweep and the
`probedClaimed` state as a first-class UI citizen, generic MASShortcut / ShortcutRecorder /
`KeyboardShortcuts` domain sniffing, static `nm` triage.

**M3 — Attribution.** Differential learning across launch/quit, Detective Mode (sandwich taps,
per-pid sniffer, blackout), side-channel correlation, persistent attribution DB with confidence.

**M4 — Ship.** Onboarding, signing/notarization pipeline, export, adapter registry documented for
community PRs, crash-safety audit of every mutating path.

---

## 17. Repository layout

```
PLAN.md                        this document
README.md                      what it is, how to build, how to contribute an adapter
Makefile                       build / app bundle / sign / notarize / dmg
Package.swift
Resources/
  Info.plist                   bundle identity, LSUIElement=false, usage strings
  Shortking.entitlements       hardened runtime exceptions
Sources/
  ShortkingKit/
    Model/            KeyCombo, Modifiers, KeyCodes, ClaimLayer, Owner, Evidence, Claim, Conflict
    Platform/         SkyLight, CarbonHotKey, AXBridge, SecureInput, ProcessInfoUtil
    Scanners/         MenuBarScanner, SymbolicHotKeyScanner, UserKeyEquivalentScanner,
                      ServicesScanner, InputSourceScanner, EventTapScanner, BinaryTriage
    Adapters/         AdapterRegistry, Karabiner, Skhd, Hammerspoon, VSCode, JetBrains, GenericPrefs
    Probe/            ProbeSpace, ProbeReport, ProbeRunner, ProbeSweep
    Attribution/      DifferentialEngine, AttributionStore, SideChannelCorrelator
    Detective/        SystemDefinedSniffer, SandwichTaps, BlackoutController, DetectiveSession
    Analysis/         ConflictAnalyzer, HealthCheck
    Store/            ClaimDatabase, JSONStore, Settings
    Scan/             ScanCoordinator, ScanContext, ClaimSource
    Util/             Log, Debounce, Atomic
  ShortkingApp/       ShortkingApp, AppState, Views/…
  ShortkingProbe/     main.swift
Tests/ShortkingKitTests/
```

---

## 18. Open questions / de-risking

Two experiments from §7 of the research doc gate major capabilities. Both are implemented as
**runtime self-tests** rather than one-off lab work, so they re-verify on every macOS update:

**A — Is probing reliable on macOS 26?** Register a combo in-process, then attempt to register it
again. Distinguishable failure → the probe sweep and differential attribution both work with public
API only. Success (duplicate registration permitted) → the probe feature disables itself with an
explanation, and Shortking leans entirely on the sniffer, sandwich and side-channel. The self-test
also sweeps the modifier space to map exactly which masks the Sequoia hardening affects on this OS
build, which is what keeps `-9868` out of the conflict list.

**B — Do per-pid taps see hotkey delivery?** Register a hotkey in the app, attach a per-pid
listen-only tap to *ourselves* masked on system-defined events, synthesise the press, and check for
subtype 6 with our hotkey ID in `data1`. Yes → live, named, instant attribution, the feature that
makes the app. No → fall back to the annotated tap with `kCGEventTargetUnixProcessID`, and failing
that to differential + side-channel.

Both must be verified from a signed, notarized, hardened-runtime build launched from `/Applications`
— not from Xcode or a terminal, or TCC will lie.

Secondary unknowns, tracked but not gating: exact `CGSGetSymbolicHotKeyValue` argument widths on
Tahoe; whether `SIGSTOP` really does not release registrations; whether `log stream` on the SkyLight
subsystem exposes registration events cheaply.
