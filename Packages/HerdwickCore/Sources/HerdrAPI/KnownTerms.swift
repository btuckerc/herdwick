import Foundation

/// Dictation's known terms: names and jargon to spell as entered (GitHub, PostgreSQL, R&D).
public enum KnownTerms {
    /// A heard word, or a run of words, that spells a term once case, spacing and punctuation
    /// are set aside ("github", "Postgre SQL", "R and D") becomes the term, the longest run
    /// winning (the earlier term on a tie); a plural or possessive keeps its "s" ("githubs").
    /// Failing that, a run within a few letters of a long term becomes it too ("poster SQL",
    /// "item potent"): recognizers hear unfamiliar words as sound-alike ones. Short terms only
    /// match exactly, so "shift" never becomes "Swift". Runs don't cross punctuation, and the
    /// text around them keeps its spacing.
    public static func apply(_ terms: [String], to text: String) -> String {
        var byKey: [String: String] = [:]
        var entries: [Entry] = []
        var longest = 1
        for term in terms {
            let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = term.split(whereSeparator: \.isWhitespace).count
            for key in [key(term), key(term.replacingOccurrences(of: "&", with: " and "))] where !key.isEmpty {
                guard byKey[key] == nil else { continue }
                byKey[key] = term
                entries.append(Entry(key: Array(key), term: term, words: words))
                longest = max(longest, words)
            }
        }
        guard !byKey.isEmpty else { return text }
        let near = entries.filter { slack(for: $0.key.count) > 0 }
        let words = text.split(whereSeparator: \.isWhitespace)
        var out = ""
        var cursor = text.startIndex
        var index = 0
        while index < words.count {
            var run = ""
            var exact: Match?
            var close: (match: Match, distance: Int)?
            for (offset, word) in words[index..<min(index + longest + 2, words.count)].enumerated() {
                let wordKey = key(word)
                guard !wordKey.isEmpty else { break }
                run += wordKey
                if let term = byKey[run] {
                    exact = Match(count: offset + 1, term: term)
                } else if run.count > 3, run.last == "s", let term = byKey[String(run.dropLast())] {
                    exact = Match(count: offset + 1, term: term + plural(word))
                } else if exact == nil {
                    let heard = Array(run)
                    for entry in near where offset < entry.words + 2 && entry.key.first == heard.first {
                        let limit = min(slack(for: entry.key.count), close.map { $0.distance - 1 } ?? .max)
                        guard limit >= 0, let distance = distance(heard, entry.key, within: limit) else { continue }
                        close = (Match(count: offset + 1, term: entry.term), distance)
                    }
                }
                // "Charge B, che": the comma ends the run.
                if let last = word.last, !isWordCharacter(last) { break }
            }
            guard let match = exact ?? close?.match else {
                index += 1
                continue
            }
            let first = words[index], last = words[index + match.count - 1]
            out += text[cursor..<first.startIndex]
            out += first[..<(first.firstIndex(where: isWordCharacter) ?? first.endIndex)]
            out += match.term
            out += last[(last.lastIndex(where: isWordCharacter).map(last.index(after:)) ?? last.endIndex)...]
            cursor = last.endIndex
            index += match.count
        }
        return out + text[cursor...]
    }

    private struct Entry {
        let key: [Character]
        let term: String
        let words: Int
    }

    private struct Match {
        let count: Int
        let term: String
    }

    /// Letters a heard run may be off by: none below eight, then about one in seven.
    private static func slack(for length: Int) -> Int {
        switch length {
        case ..<8: 0
        case ..<10: 1
        case ..<14: 2
        default: 3
        }
    }

    /// "github's" keeps its apostrophe.
    private static func plural(_ word: Substring) -> String {
        guard let end = word.lastIndex(where: isWordCharacter), end > word.startIndex else { return "s" }
        let mark = word[word.index(before: end)]
        return mark == "'" || mark == "’" ? "\(mark)s" : "s"
    }

    /// Edit distance, or nil once it's past `limit`.
    private static func distance(_ a: [Character], _ b: [Character], within limit: Int) -> Int? {
        guard abs(a.count - b.count) <= limit else { return nil }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            var best = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                best = min(best, current[j])
            }
            guard best <= limit else { return nil }
            swap(&previous, &current)
        }
        return previous[b.count] <= limit ? previous[b.count] : nil
    }

    private static func key(_ text: some StringProtocol) -> String {
        String(text.lowercased().filter(isWordCharacter))
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
