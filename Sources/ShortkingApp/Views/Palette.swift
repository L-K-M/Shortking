import SwiftUI

/// The overview's colour vocabulary.
///
/// Saturated gradients carry meaning here rather than decoration: warm for "two
/// things are fighting", violet for "somebody has this and won't say who", blue for
/// "these processes can see your keys", green for "nothing to do". Every card that
/// uses one also states the same thing in words, so the colour is reinforcement and
/// never the only signal.
enum Palette {

    static let crimson = Color(red: 0.96, green: 0.31, blue: 0.36)
    static let rose    = Color(red: 0.91, green: 0.22, blue: 0.53)
    static let amber   = Color(red: 0.99, green: 0.64, blue: 0.20)
    static let tangelo = Color(red: 0.96, green: 0.42, blue: 0.24)
    static let violet  = Color(red: 0.58, green: 0.36, blue: 0.97)
    static let indigo  = Color(red: 0.36, green: 0.31, blue: 0.92)
    static let azure   = Color(red: 0.22, green: 0.62, blue: 0.97)
    static let cyan    = Color(red: 0.20, green: 0.80, blue: 0.85)
    static let mint    = Color(red: 0.16, green: 0.80, blue: 0.55)
    static let teal    = Color(red: 0.06, green: 0.62, blue: 0.60)

    static let conflict = [crimson, rose]
    static let unknown  = [violet, indigo]
    static let warning  = [amber, tangelo]
    static let watchers = [azure, indigo]
    static let clear    = [mint, teal]
    static let hero     = [indigo, violet]

    static func gradient(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The window wash. Kept low-opacity over the system window colour so the page
    /// reads correctly in both light and dark appearance instead of being a
    /// hard-coded dark theme.
    static var canvas: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [indigo.opacity(0.20), violet.opacity(0.10), .clear],
                startPoint: .topLeading,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

/// A large, colourful summary tile.
struct SummaryCard: View {
    let title: String
    let value: String
    let caption: String
    let symbol: String
    let colors: [Color]
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Palette.gradient(colors)

            // The oversized glyph is decoration, so it is explicitly hidden from
            // assistive technology — the title and value already say everything.
            Image(systemName: symbol)
                .font(.system(size: 84, weight: .semibold))
                .foregroundStyle(.white.opacity(0.18))
                .offset(x: 18, y: -14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))

                Spacer(minLength: 8)

                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .bottom) {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    Spacer()
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.22)))
                    }
                }
            }
            .padding(16)
        }
        .frame(minHeight: 168)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: colors.first?.opacity(0.28) ?? .clear, radius: 12, y: 6)
    }
}

/// A section heading with an optional "see all" affordance.
struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
    }
}

/// A rounded panel used for the lists on the overview.
struct Panel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
