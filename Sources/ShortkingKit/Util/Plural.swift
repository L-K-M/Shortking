import Foundation

/// English pluralisation, so the interface never says "1 claim(s)".
///
/// Shortking writes counts into almost every sentence it produces — claims,
/// conflicts, processes, event taps, observations, restart cycles — and a
/// parenthesised "(s)" is the most visible sign in a user interface that nobody
/// proofread it. Small enough not to warrant a dependency, explicit enough that the
/// words English does not simply suffix can say so.
///
/// Not localised. When Shortking is, this becomes a `String(localized:)` lookup with
/// a plural rule per language, and the call sites do not change shape.
public enum Plural {

    /// `Plural.count(1, "claim")` → `"1 claim"`, `Plural.count(3, "claim")` → `"3 claims"`.
    public static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(word(number, singular, plural))"
    }

    /// The noun alone, inflected for `number`.
    public static func word(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        number == 1 ? singular : (plural ?? regularPlural(of: singular))
    }

    /// The regular rule, plus the endings that take `-es`.
    ///
    /// Anything irregular passes its plural explicitly rather than being guessed at —
    /// a wrong plural is a worse look than a verbose call site.
    private static func regularPlural(of singular: String) -> String {
        let lowered = singular.lowercased()
        for ending in ["s", "x", "z", "ch", "sh"] where lowered.hasSuffix(ending) {
            return singular + "es"
        }
        return singular + "s"
    }
}
