import Foundation

/// Where Shortking keeps its data.
public enum StoreLocation {

    public static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let url = base.appendingPathComponent("Shortking", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    public static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }
}

/// An atomically written, schema-versioned JSON file.
///
/// Two properties matter here, and both exist to protect the attribution ledger —
/// the file that gets more valuable the longer Shortking is installed:
///
/// - **Atomic writes.** A crash mid-save leaves the previous version intact.
/// - **Version gating.** A file written by a newer build is moved aside rather than
///   parsed, so downgrading cannot corrupt it.
public final class JSONStore<Value: Codable>: @unchecked Sendable {

    /// Bumped only for breaking changes to a payload's shape.
    public static var currentSchemaVersion: Int { 1 }

    private struct Envelope: Codable {
        var schemaVersion: Int
        var writtenAt: Date
        var payload: Value
    }

    private let url: URL
    private let lock = NSLock()

    public init(filename: String) {
        self.url = StoreLocation.url(for: filename)
    }

    public init(url: URL) {
        self.url = url
    }

    public var fileURL: URL { url }

    public func load() -> Value? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion <= Self.currentSchemaVersion else {
                quarantine(reason: "schema \(envelope.schemaVersion) is newer than \(Self.currentSchemaVersion)")
                return nil
            }
            return envelope.payload
        } catch {
            Log.store.error("Failed to decode \(self.url.lastPathComponent): \(error.localizedDescription)")
            quarantine(reason: "decode failure")
            return nil
        }
    }

    @discardableResult
    public func save(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let envelope = Envelope(
            schemaVersion: Self.currentSchemaVersion,
            writtenAt: Date(),
            payload: value
        )

        do {
            let data = try encoder.encode(envelope)
            let temporary = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp")
            try data.write(to: temporary, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            return true
        } catch {
            Log.store.error("Failed to write \(self.url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    public func delete() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves an unreadable file aside instead of deleting it, so a user who hits a
    /// bug still has their data and we can ask for the file.
    private func quarantine(reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).quarantined-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: target)
        Log.store.warning("Quarantined \(self.url.lastPathComponent): \(reason)")
    }
}
