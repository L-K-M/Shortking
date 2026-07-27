import AppKit
import ShortkingKit
import SwiftUI

/// The claimant's real application icon.
///
/// Names alone make the suspect list read like a log file — "universalaccessd",
/// "BetterTouchTool", "pid 4711" — and the eye has to parse every row to find the one
/// it recognises. An icon is what turns that list into something scannable, and it is
/// the cheapest change in the app with the largest effect on how considered it looks.
///
/// Processes without a bundle — daemons, helpers, anything `ProcessLookup` could only
/// name through `ps` — have no icon at all. Rather than leave a blank square, the
/// fallback glyph says what *kind* of thing it is, which is information the row did
/// not previously carry.
struct OwnerIcon: View {
    let owner: Owner
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = OwnerIconCache.shared.icon(for: owner) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        // Decorative: the owner's name is always adjacent, so announcing the icon
        // would just make VoiceOver read everything twice.
        .accessibilityHidden(true)
    }

    private var fallbackSymbol: String {
        switch owner.kind {
        case .system:      return "gearshape.fill"
        case .configTool:  return "wrench.and.screwdriver.fill"
        case .service:     return "gearshape.2.fill"
        case .inputMethod: return "globe"
        case .application: return "app.dashed"
        case .unknown:     return "questionmark.app.dashed"
        }
    }
}

/// Application icons, keyed by bundle path.
///
/// `NSWorkspace.icon(forFile:)` goes to the Launch Services database and is far too
/// slow to call from a SwiftUI body — which is to say, once per row, on every render,
/// on a list that can be hundreds of rows long.
@MainActor
final class OwnerIconCache {

    static let shared = OwnerIconCache()

    private var byPath: [String: NSImage] = [:]

    private init() {}

    func icon(for owner: Owner) -> NSImage? {
        guard let path = owner.path, !path.isEmpty else { return nil }
        if let cached = byPath[path] { return cached }
        // Without this, an uninstalled app gets the generic document icon rather
        // than the fallback glyph, which reads as "Shortking doesn't know what this
        // is" when in fact it does.
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let image = NSWorkspace.shared.icon(forFile: path)
        byPath[path] = image
        return image
    }
}
