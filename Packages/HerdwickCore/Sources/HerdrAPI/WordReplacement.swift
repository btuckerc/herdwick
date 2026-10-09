import Foundation

/// A dictionary entry for dictation: a phrase speech recognition keeps getting wrong and what to write instead.
public struct WordReplacement: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var heard: String
    public var write: String

    public init(heard: String, write: String) {
        self.heard = heard
        self.write = write
    }

    /// Case-insensitive, whole-word replacement in one pass: at each position the longest
    /// match wins (the earlier entry on a tie) and replacements never chain. The words of a
    /// phrase match however the recognizer joined them: spaced, run together, or split by a
    /// hyphen or comma ("poster SQL", "poster-SQL", "Poster, SQL"); curly and straight
    /// apostrophes match. Entries with a blank side are skipped, so a half-typed row does nothing.
    public static func apply(_ rules: [WordReplacement], to text: String) -> String {
        let patterns: [(heard: [[Unicode.Scalar]], write: String)] = rules.compactMap { rule in
            let heard = rule.heard.split(whereSeparator: \.isWhitespace).map { $0.unicodeScalars.map(fold) }
            let write = rule.write.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !write.isEmpty else { return nil }
            return (heard, write)
        }
        guard !patterns.isEmpty else { return text }
        let scalars = Array(text.unicodeScalars)
        let folded = scalars.map(fold)
        var out = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            var best: (end: Int, write: String)?
            if index == 0 || !isWordScalar(scalars[index - 1]) {
                for pattern in patterns {
                    guard let end = match(pattern.heard, in: folded, at: index), end > (best?.end ?? index),
                          end == scalars.count || !isWordScalar(scalars[end]) else { continue }
                    best = (end, pattern.write)
                }
            }
            if let best {
                out.append(contentsOf: best.write.unicodeScalars)
                index = best.end
            } else {
                out.append(scalars[index])
                index += 1
            }
        }
        return String(out)
    }

    /// Where the words end if they're at `start`, with any spaces, hyphens or commas between.
    private static func match(_ words: [[Unicode.Scalar]], in text: [Unicode.Scalar], at start: Int) -> Int? {
        var position = start
        for (offset, word) in words.enumerated() {
            if offset > 0 {
                while position < text.count, text[position].properties.isWhitespace || "-‐–,".unicodeScalars.contains(text[position]) {
                    position += 1
                }
            }
            let end = position + word.count
            guard end <= text.count, text[position..<end].elementsEqual(word) else { return nil }
            position = end
        }
        return position
    }

    /// Simple case folding (a scalar whose lowercase is more than one scalar stays as it
    /// is), with curly apostrophes made straight.
    private static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if scalar == "\u{2019}" || scalar == "\u{2018}" || scalar == "\u{02BC}" { return "'" }
        let lower = scalar.properties.lowercaseMapping.unicodeScalars
        return lower.count == 1 ? lower.first! : scalar
    }

    /// Unicode `\w`: letters, marks, decimal digits, connector punctuation and joiners.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isAlphabetic || properties.isJoinControl { return true }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return false
        }
    }
}
