import Testing
@testable import HerdrAPI

@Suite struct KnownTermsTests {
    @Test func spellsTermsIgnoringCaseSpacingAndPunctuation() {
        #expect(KnownTerms.apply(["GitHub", "PostgreSQL", "GPT-4"], to: "push to github, then (postgre sql) on GPT 4.")
            == "push to GitHub, then (PostgreSQL) on GPT-4.")
        #expect(KnownTerms.apply(["R&D"], to: "send it to R and D or rd") == "send it to R&D or R&D")
    }

    @Test func longestRunWinsAndKeepsSurroundingSpace() {
        #expect(KnownTerms.apply(["Mac", "MacBook Pro"], to: "a mac\n\nmac book  pro mac")
            == "a Mac\n\nMacBook Pro Mac")
    }

    @Test func runsStopAtPunctuationAndShortTermsMatchExactly() {
        #expect(KnownTerms.apply(["GitHub"], to: "git, hub") == "git, hub")
        #expect(KnownTerms.apply(["Swift", "Git", "AI", "Claude"], to: "shift, get a grip on the clause")
            == "shift, get a grip on the clause")
        #expect(KnownTerms.apply([" ", ""], to: "a b") == "a b")
    }

    @Test func pluralsAndPossessivesKeepTheirEnding() {
        #expect(KnownTerms.apply(["GitHub", "Mac", "AI"], to: "two githubs, github’s CI, macs and ais")
            == "two GitHubs, GitHub’s CI, Macs and ais")
    }

    @Test func longTermsCatchNearMisses() {
        let heard = "Run the poster SQL migration, then make the retry item potent and a board controller in herd wick."
        #expect(KnownTerms.apply(["PostgreSQL", "idempotent", "AbortController", "Herdwick"], to: heard)
            == "Run the PostgreSQL migration, then make the retry idempotent and AbortController in Herdwick.")
        // Too far off, or across punctuation, stays as heard.
        #expect(KnownTerms.apply(["Herdwick", "Kubernetes"], to: "hard work on cooper netties, herd. wick")
            == "hard work on cooper netties, herd. wick")
    }

    @Test func anExactSpellingBeatsANearMiss() {
        #expect(KnownTerms.apply(["Herdwick", "Hardwick"], to: "hardwick") == "Hardwick")
    }
}
