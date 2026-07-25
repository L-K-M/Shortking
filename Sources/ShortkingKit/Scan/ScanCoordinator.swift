import Foundation

/// Runs every source, folds the results together, and produces a ``ScanResult``.
///
/// Two policies matter here:
///
/// - **Concurrency with per-source timeouts.** One beachballed app must not stall a
///   scan, so each source runs in its own task with its own deadline.
/// - **Degrade, never fail.** A source that throws or times out becomes a warning in
///   the status bar and on the Health screen. An empty inventory is a bug; a partial
///   inventory with a visible explanation is correct behaviour.
public actor ScanCoordinator {

    private let sources: [ClaimSource]
    private let probeRunner: ProbeRunner
    private let attribution: AttributionStore
    private let database: ClaimDatabase

    /// Per-source deadline. Menus get longer because they legitimately take longer.
    private let defaultTimeout: TimeInterval = 8
    private let menuTimeout: TimeInterval = 20

    public private(set) var lastResult: ScanResult?

    public init(
        sources: [ClaimSource]? = nil,
        probeRunner: ProbeRunner = ProbeRunner(),
        attribution: AttributionStore = AttributionStore(),
        database: ClaimDatabase = ClaimDatabase()
    ) {
        self.sources = sources ?? ScanCoordinator.defaultSources()
        self.probeRunner = probeRunner
        self.attribution = attribution
        self.database = database
    }

    /// The standard source set.
    ///
    /// The two caches are parameters rather than defaults constructed in place so
    /// that a caller can hold on to them. "Clear caches" used to build *fresh*
    /// `MenuCache` and `TriageCache` objects and clear those, which wrote an empty
    /// file while the scanners kept their populated in-memory copies and overwrote
    /// it on the next store. The button appeared to work and did nothing.
    public static func defaultSources(
        menuCache: MenuCache = MenuCache(),
        triageCache: TriageCache = TriageCache()
    ) -> [ClaimSource] {
        [
            MenuBarScanner(cache: menuCache),
            SymbolicHotKeyScanner(),
            UserKeyEquivalentScanner(),
            ServicesScanner(),
            InputSourceScanner(),
            EventTapScanner(),
            AdapterRegistry(),
            GenericPreferenceScanner(),
            BinaryTriage(cache: triageCache),
        ]
    }

    /// The event tap scanner instance, so the UI can read the tap list it captured.
    private var eventTapScanner: EventTapScanner? {
        sources.compactMap { $0 as? EventTapScanner }.first
    }

    public func scan(context: ScanContext) async -> ScanResult {
        let startedAt = Date()
        Log.scan.info("Scan started")

        let enabled = sources.filter { $0.isEnabled(for: context.options) }

        var outcomes: [SourceOutcome] = []

        await withTaskGroup(of: SourceOutcome.self) { group in
            for source in enabled {
                let timeout = source.identifier == "menus" ? menuTimeout : defaultTimeout
                group.addTask {
                    await Self.run(source: source, context: context, timeout: timeout)
                }
            }
            for await outcome in group {
                outcomes.append(outcome)
            }
        }

        var claims = ClaimMerger.merge(outcomes.flatMap(\.claims))

        // Probe: the negative-space map. Runs after the sources so that a refusal on
        // a combination somebody already accounts for becomes corroboration rather
        // than a phantom second claim.
        var probeReport: ProbeReport?
        if context.options.includeProbe, probeRunner.isAvailable {
            do {
                let report = try await probeRunner.sweep(breadth: context.options.probeBreadth)
                probeReport = report
                claims = ClaimMerger.applyProbeReport(report, to: claims)
            } catch {
                outcomes.append(
                    SourceOutcome(
                        identifier: "probe",
                        displayName: "Hotkey probe",
                        claims: [],
                        duration: 0,
                        error: error.localizedDescription
                    )
                )
            }
        }

        // Attribution: fold in what differential learning has concluded, but only
        // for combinations nobody has named directly.
        let namedCombos = Set(
            claims.filter { $0.status == .known && $0.layer <= .symbolic }.map(\.combo)
        )
        let unattributed = claims
            .filter { $0.status == .probedClaimed && !namedCombos.contains($0.combo) }
            .map(\.combo)
        let inferred = attribution.inferredClaims(for: unattributed)
        if !inferred.isEmpty {
            claims = ClaimMerger.merge(claims + inferred)
        }

        // Carry forward firstSeen and historical evidence.
        let previous = database.load()
        claims = ClaimMerger.reconcile(new: claims, previous: previous)

        let groups = ConflictAnalyzer.analyze(ClaimMerger.group(claims))
        let conflicts = ConflictAnalyzer.conflicts(in: groups)

        let result = ScanResult(
            claims: claims,
            groups: groups,
            conflicts: conflicts,
            outcomes: outcomes.sorted { $0.displayName < $1.displayName },
            eventTaps: eventTapScanner?.lastTaps ?? [],
            probeReport: probeReport,
            startedAt: startedAt,
            finishedAt: Date()
        )

        database.save(claims)
        lastResult = result

        let summary = "\(claims.count) claims, \(conflicts.count) conflicts, "
            + "\(result.warnings.count) warnings, "
            + String(format: "%.2f", result.duration) + "s"
        Log.scan.info("Scan finished: \(summary, privacy: .public)")
        return result
    }

    /// Runs one source with a deadline, converting any failure into an outcome.
    private static func run(
        source: ClaimSource,
        context: ScanContext,
        timeout: TimeInterval
    ) async -> SourceOutcome {
        let startedAt = Date()

        return await withTaskGroup(of: SourceOutcome?.self) { group in
            group.addTask {
                do {
                    let claims = try await source.scan(context: context)
                    return SourceOutcome(
                        identifier: source.identifier,
                        displayName: source.displayName,
                        claims: claims,
                        duration: Date().timeIntervalSince(startedAt)
                    )
                } catch {
                    return SourceOutcome(
                        identifier: source.identifier,
                        displayName: source.displayName,
                        claims: [],
                        duration: Date().timeIntervalSince(startedAt),
                        error: error.localizedDescription
                    )
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }

            // Whichever finishes first wins; the loser is cancelled.
            for await outcome in group {
                group.cancelAll()
                if let outcome { return outcome }
                Log.scan.warning("Source \(source.identifier) timed out after \(timeout)s")
                return SourceOutcome(
                    identifier: source.identifier,
                    displayName: source.displayName,
                    claims: [],
                    duration: timeout,
                    error: "Timed out after \(Int(timeout)) seconds",
                    timedOut: true
                )
            }

            return SourceOutcome(
                identifier: source.identifier,
                displayName: source.displayName,
                claims: [],
                duration: Date().timeIntervalSince(startedAt)
            )
        }
    }
}

/// The persisted inventory, so a cold start shows data immediately instead of an
/// empty window while the first scan runs.
public final class ClaimDatabase: @unchecked Sendable {

    private let store: JSONStore<[Claim]>
    private let lock = NSLock()
    private var cached: [Claim]?

    public init(filename: String = "claims.json") {
        self.store = JSONStore(filename: filename)
    }

    public func load() -> [Claim] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = store.load() ?? []
        cached = loaded
        return loaded
    }

    public func save(_ claims: [Claim]) {
        lock.lock()
        cached = claims
        lock.unlock()
        store.save(claims)
    }

    public func clear() {
        lock.lock()
        cached = []
        lock.unlock()
        store.save([])
    }
}
