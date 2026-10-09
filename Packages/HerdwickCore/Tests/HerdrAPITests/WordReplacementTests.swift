import Testing
@testable import HerdrAPI

@Suite struct WordReplacementTests {
    private func apply(_ text: String, _ rules: [(String, String)]) -> String {
        WordReplacement.apply(rules.map { WordReplacement(heard: $0.0, write: $0.1) }, to: text)
    }

    @Test func wholeWordsIgnoringCase() {
        #expect(apply("Two, TWO! twofold twosome _two two_ to too.\n two", [("two", "2")])
            == "2, 2! twofold twosome _two two_ to too.\n 2")
    }

    @Test func longestPhraseWinsAndNothingChains() {
        #expect(apply("New York, new job", [("new", "old"), ("new york", "NYC")]) == "NYC, old job")
        #expect(apply("a b", [("a", "b"), ("b", "c")]) == "b c")
        #expect(apply("xa a a", [("a a", "X")]) == "xa X")
    }

    @Test func writesLiterally() {
        #expect(apply("A+B (a+b)", [("a+b", "$1 iPhone")]) == "$1 iPhone ($1 iPhone)")
    }

    @Test func combiningMarksAreWordCharacters() {
        #expect(apply("café caféine CAFÉ café\u{0301} café\u{093E}", [("CAFÉ", "tea")])
            == "tea caféine tea café\u{0301} café\u{093E}")
    }

    @Test func fixesMeasuredMishearingsAndSkipsBlankRows() {
        let heard = "Run the poster SQL migration, then make the retry item potent and a board controller."
        #expect(apply(heard, [("poster SQL", "PostgreSQL"), ("item potent", "idempotent"),
                              ("a board controller", "AbortController"), (" ", "x"), ("retry", " ")])
            == "Run the PostgreSQL migration, then make the retry idempotent and AbortController.")
    }

    @Test func phrasesMatchHoweverTheWordsAreJoined() {
        let rules = [("poster SQL", "PostgreSQL"), ("don't know", "dunno")]
        #expect(apply("poster-SQL, Poster, SQL, postersql, posters SQL; I don’t know", rules)
            == "PostgreSQL, PostgreSQL, PostgreSQL, posters SQL; I dunno")
    }
}
