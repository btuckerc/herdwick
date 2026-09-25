import Foundation

/// Streams a file to a private, per-session temporary directory on the remote host.
public enum AttachmentUpload {
    public static func command(session: String, filename: String, retentionMinutes: Int) -> String {
        let directory = "\"${TMPDIR:-/tmp}/herdwick-$(id -u)\""
        let file = shellQuote(filename)
        return "root=\(directory); session=\(shellQuote(session)); d=\"$root/$session\"; umask 077; mkdir -p \"$d\" && find \"$root\" -type f -mmin +\(max(1, retentionMinutes)) -delete 2>/dev/null && cat > \"$d\"/\(file).part && mv \"$d\"/\(file).part \"$d\"/\(file) && printf '%s\\n' \"$d\"/\(file) && wc -c < \"$d\"/\(file)"
    }

    public static func upload(_ data: Data, session: String, filename: String, retentionMinutes: Int, runner: any CommandRunner) async throws -> String {
        guard [session, filename].allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") && !$0.contains("\n") && !$0.contains("\r")
        }) else { throw UploadError.invalidPath }
        let channel = try await runner.exec(command(session: session, filename: filename, retentionMinutes: retentionMinutes))
        do {
            for start in stride(from: 0, to: data.count, by: 64 * 1024) {
                try await channel.write(Array(data[start..<min(start + 64 * 1024, data.count)]))
            }
            try await channel.closeInput()
            var output = [UInt8]()
            for try await chunk in channel.output { output.append(contentsOf: chunk) }
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n")
            guard lines.count == 2, lines[0].hasPrefix("/"), Int(lines[1].trimmingCharacters(in: .whitespaces)) == data.count else {
                throw UploadError.invalidResponse
            }
            await channel.close()
            return String(lines[0])
        } catch {
            await channel.close()
            throw error
        }
    }
}

public enum UploadError: Error { case invalidResponse, invalidPath }
