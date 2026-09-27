import Foundation
import HerdrAPI
import HerdrTestSupport
import Testing

@Suite struct FileReadTests {
    let client = HerdrClient(runner: LocalProcessRunner())

    @Test func readsBinaryBytesExactlyAndRefusesLargeOrMissingFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("read \(UUID().uuidString) it's.png")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data((0..<4096).map { UInt8($0 % 256) } + [0x0A, 0x00, 0x0D])
        try bytes.write(to: file)

        #expect(try await client.readFile(path: file.path) == bytes)
        let large = await #expect(throws: FileTooLarge.self) { try await client.readFile(path: file.path, maxBytes: 100) }
        #expect(large?.bytes == bytes.count)
        let missing = await #expect(throws: FileUnreadable.self) { try await client.readFile(path: "/no/such/image.png") }
        #expect(missing?.path == "/no/such/image.png")
    }
}
