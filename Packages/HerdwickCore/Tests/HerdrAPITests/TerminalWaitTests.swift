import Foundation
import HerdrAPI
import Testing

@Suite("Terminal input waits")
struct TerminalWaitTests {
    private func screen(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Screens"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func conversation(_ name: String, format: TranscriptFormat = .omp) throws -> Conversation {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Screens"))
        var reader = TranscriptReader(format: format)
        var conversation = Conversation()
        conversation.apply(records: reader.appendRecords(Array(try Data(contentsOf: url))))
        return conversation
    }

    @Test func capturedPtyCallWaitsUntilItsResult() throws {
        let waiting = try conversation("omp-pty-transcript")
        let wait = try #require(waiting.pendingTerminalInput)
        #expect(wait.toolCallId == "toolu_01WytBoeoSLQpUhMotNXqVW2")
        #expect(wait.command == "read -p 'Overwrite config.yml? [y/N] ' a; echo got:$a")
        #expect(wait.startedAt == (try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-10-30T05:28:11.500Z")))
        #expect(try conversation("omp-pty-transcript-after").pendingTerminalInput == nil)
    }

    @Test func onlyTheNewestPtyCallCanWaitAndUserOrResultClearsIt() throws {
        let pty = #"{"type":"message","id":"a1","timestamp":"2026-10-30T05:28:11.500Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"pty","name":"bash","arguments":{"command":"read x","pty":true}}]}}"#
        let nonPty = #"{"type":"message","id":"a2","message":{"role":"assistant","content":[{"type":"toolCall","id":"plain","name":"bash","arguments":{"command":"echo ok","pty":false}}]}}"#
        let laterUser = #"{"type":"message","id":"u2","message":{"role":"user","content":[{"type":"text","text":"continue"}]}}"#
        let result = #"{"type":"message","id":"r1","message":{"role":"toolResult","toolCallId":"pty","content":[{"type":"text","text":"done"}]}}"#
        func parsed(_ lines: [String]) throws -> Conversation {
            var reader = TranscriptReader()
            var result = Conversation()
            result.apply(records: reader.appendRecords(Array((lines.joined(separator: "\n") + "\n").utf8)))
            return result
        }
        #expect(try parsed([pty]).pendingTerminalInput?.toolCallId == "pty")
        #expect(try parsed([pty, nonPty]).pendingTerminalInput == nil)
        #expect(try parsed([pty, laterUser]).pendingTerminalInput == nil)
        #expect(try parsed([pty, result]).pendingTerminalInput == nil)
        #expect(try conversation("omp-pty-transcript", format: .claude).pendingTerminalInput == nil)
        #expect(try conversation("omp-pty-transcript", format: .codex).pendingTerminalInput == nil)
    }

    @Test func parsesTheRunningConsoleOverlay() throws {
        let parsed = try #require(ConsoleScreen.parse(screen("omp-pty-prompt")))
        #expect(parsed.command == "read -p 'Overwrite config.yml? [y/N] ' a; echo got:$a")
        #expect(parsed.prompt == "Overwrite config.yml? [y/N]")
        #expect(parsed.offersYesNo)
        #expect(ConsoleScreen.parse(try screen("omp-pty-after")) == nil)
        #expect(ConsoleScreen.parse(try screen("omp-plain-screen")) == nil)
    }

    /// What reads as waiting on input at once; anything else needs the console to stay still.
    @Test(arguments: [("Password:", true, false), ("Overwrite config.yml? [y/N]", true, true),
                      ("Enter passphrase for key '/home/u/.ssh/id_ed25519'", true, false),
                      ("Listening on http://localhost:3000", false, false)])
    func promptClassification(last: String, asks: Bool, yesNo: Bool) throws {
        let text = "╭────╮\n│ Console cmd ⟨running⟩ │\n│ starting │\n│ \(last) │\n│ force-kill · input forwarded to PTY │\n╰────╯"
        let parsed = try #require(ConsoleScreen.parse(text))
        #expect(parsed.prompt == last)
        #expect(parsed.asksForInput == asks)
        #expect(parsed.offersYesNo == yesNo)
    }
}
