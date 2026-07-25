import ShortkingKit
import SwiftUI

/// An element paired with its position in a collection.
///
/// `ForEach(Array(items.enumerated()), id: \.element.id)` is the shape everyone
/// reaches for when a row needs to know whether to draw a leading divider — and it
/// does not compile. `EnumeratedSequence.Element` is a tuple, and Swift has no key
/// paths into tuple elements; it is the same constraint that makes
/// `RootView.SidebarSection` a struct rather than a tuple. This is the version that
/// compiles, and it keeps the intent legible at the call site.
struct Positioned<Element>: Identifiable {
    let index: Int
    let element: Element
    let id: AnyHashable

    /// True for every element except the first — the divider test, named.
    var needsSeparator: Bool { index > 0 }
}

extension Sequence where Element: Identifiable {
    /// Pairs each element with its position, borrowing the element's own identity.
    func positioned() -> [Positioned<Element>] {
        enumerated().map {
            Positioned(index: $0.offset, element: $0.element, id: AnyHashable($0.element.id))
        }
    }
}

/// A key combination rendered as keycaps.
///
/// Modifiers always appear in the canonical macOS order (⌃⌥⇧⌘) regardless of the
/// order the source reported them, so the same shortcut looks the same everywhere.
struct KeyComboBadge: View {
    let combo: KeyCombo
    var size: Size = .regular

    enum Size {
        case small, regular, large

        var font: Font {
            switch self {
            case .small:   return .system(size: 11, weight: .medium, design: .rounded)
            case .regular: return .system(size: 13, weight: .medium, design: .rounded)
            case .large:   return .system(size: 22, weight: .semibold, design: .rounded)
            }
        }

        var padding: CGFloat {
            switch self {
            case .small:   return 3
            case .regular: return 5
            case .large:   return 9
            }
        }
    }

    /// The glyphs, each with a stable position-based identity.
    ///
    /// Position rather than glyph, because a combination can legitimately repeat one
    /// — and a `ForEach` keyed on the glyph itself would silently drop the duplicate.
    private var keycaps: [Keycap] {
        combo.keycaps.enumerated().map { Keycap(id: $0.offset, glyph: $0.element) }
    }

    private struct Keycap: Identifiable {
        let id: Int
        let glyph: String
    }

    var body: some View {
        HStack(spacing: size == .large ? 6 : 3) {
            ForEach(keycaps) { cap in
                Text(cap.glyph)
                    .font(size.font)
                    .padding(.horizontal, size.padding + 2)
                    .padding(.vertical, size.padding - 1)
                    .frame(minWidth: size == .large ? 34 : 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                    )
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityDescription))
    }

    /// Spelled out for VoiceOver — the glyphs alone read as gibberish.
    private var accessibilityDescription: String {
        var parts: [String] = []
        if combo.modifiers.contains(.function) { parts.append("Function") }
        if combo.modifiers.contains(.control)  { parts.append("Control") }
        if combo.modifiers.contains(.option)   { parts.append("Option") }
        if combo.modifiers.contains(.shift)    { parts.append("Shift") }
        if combo.modifiers.contains(.command)  { parts.append("Command") }
        parts.append(combo.keyDisplay)
        return parts.joined(separator: " ")
    }
}

/// The dispatch layer, always with its number — the number is what makes
/// "lower layer wins" legible at a glance.
struct LayerBadge: View {
    let layer: ClaimLayer
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Text("\(layer.rawValue)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.25)))
            if !compact {
                Text(layer.displayName)
                    .font(.caption)
            }
        }
        .foregroundStyle(color)
        .help(layer.explanation)
    }

    private var color: Color {
        switch layer {
        case .virtualHID:   return .purple
        case .hidTap:       return .pink
        case .sessionTap:   return .red
        case .windowServer: return .orange
        case .symbolic:     return .blue
        case .appMenu:      return .green
        case .service:      return .teal
        case .inputSource:  return .indigo
        }
    }
}

/// A status chip. Every state carries a glyph and text as well as a colour, so it
/// still reads correctly without colour perception.
struct StatusChip: View {
    let status: ClaimStatus

    var body: some View {
        Label(status.displayName, systemImage: symbol)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch status {
        case .known:         return "checkmark.seal"
        case .probedClaimed: return "questionmark.circle"
        case .inferred:      return "sparkle.magnifyingglass"
        case .capability:    return "eye"
        }
    }

    private var color: Color {
        switch status {
        case .known:         return .green
        case .probedClaimed: return .orange
        case .inferred:      return .blue
        case .capability:    return .secondary
        }
    }
}

struct ConflictChip: View {
    let conflict: Conflict

    var body: some View {
        Label(conflict.kind.displayName, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch conflict.kind {
        case .definite:     return "exclamationmark.triangle.fill"
        case .contextual:   return "rectangle.on.rectangle"
        case .shadowed:     return "eye.slash"
        case .unattributed: return "questionmark.circle"
        }
    }

    private var color: Color {
        switch conflict.severity {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow
        case .info:   return .secondary
        }
    }
}

/// A five-segment confidence bar.
///
/// Anything below 1.0 is deliberately, visibly different from a direct read: the
/// whole point is that an inference must never look like a fact.
struct ConfidenceMeter: View {
    let confidence: Double
    var showLabel = true

    private var filled: Int {
        max(0, min(5, Int((confidence * 5).rounded())))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(index < filled ? color : Color.secondary.opacity(0.2))
                    .frame(width: 6, height: 9)
            }
            if showLabel {
                Text(confidence >= 1.0 ? "exact" : String(format: "%.0f%%", confidence * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help(
            confidence >= 1.0
                ? "Read directly from a config file, plist or the Accessibility API."
                : "Inferred. Confidence rises as Shortking observes more evidence."
        )
    }

    private var color: Color {
        if confidence >= 1.0 { return .green }
        if confidence >= 0.7 { return .blue }
        if confidence >= 0.4 { return .orange }
        return .secondary
    }
}

/// An empty state that explains itself instead of showing a blank pane.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// A toggleable filter chip.
struct FilterChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isOn ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
