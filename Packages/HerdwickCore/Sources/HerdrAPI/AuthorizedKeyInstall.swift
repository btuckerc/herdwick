import Foundation

public enum AuthorizedKeyInstallError: Error, Equatable, Sendable {
    case invalidKeyLine
    case failed(String)
}

public enum AuthorizedKeyInstall {
    public enum Outcome: Sendable, Equatable {
        case installed
        case alreadyPresent
    }

    public static func script(for line: String) throws -> String {
        try validate(line)
        let quoted = "'" + line + "'"
        return """
        umask 077
        d="$HOME/.ssh"
        f="$d/authorized_keys"
        if [ -L "$d" ] || [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
          printf '%s\\n' 'refusing unsafe authorized_keys path' >&2
          exit 3
        fi
        mkdir -p "$d" || exit $?
        chmod 700 "$d" || exit $?
        touch "$f" || exit $?
        chmod 600 "$f" || exit $?
        if grep -qxF -- \(quoted) "$f"; then
          printf '%s\\n' present
        else
          if [ -s "$f" ] && [ "$(tail -c 1 "$f" | od -An -t x1 | tr -d ' \\n')" != "0a" ]; then
            printf '\\n' >> "$f"
          fi
          printf '%s\\n' \(quoted) >> "$f"
          printf '%s\\n' installed
        fi
        """
    }

    public static func install(line: String, client: HerdrClient) async throws -> Outcome {
        let script = try script(for: line)
        do {
            let channel = try await client.runner.exec(HerdrClient.posix(script))
            let output = String(decoding: try await HerdrClient.collect(channel), as: UTF8.self)
            switch output {
            case "installed\n": return .installed
            case "present\n": return .alreadyPresent
            default: throw AuthorizedKeyInstallError.failed(String(output.prefix(300)))
            }
        } catch let error as AuthorizedKeyInstallError {
            throw error
        } catch {
            let message: String
            if case let CommandError.exited(_, stderr) = error {
                message = stderr
            } else {
                message = String(describing: error)
            }
            throw AuthorizedKeyInstallError.failed(String(message.prefix(300)))
        }
    }

    public static func removalScript(for line: String) throws -> String {
        try validate(line)
        let quoted = "'" + line + "'"
        return """
        umask 077
        d="$HOME/.ssh"
        f="$d/authorized_keys"
        if [ -L "$d" ] || [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
          printf '%s\\n' 'refusing unsafe authorized_keys path' >&2
          exit 3
        fi
        [ -f "$f" ] || exit 0
        t="$d/.authorized_keys.XXXXXX"
        t=$(mktemp "$t") || exit $?
        trap 'rm -f "$t"' 0
        if grep -vxF -- \(quoted) "$f" > "$t"; then :; else
          status=$?
          [ "$status" -eq 1 ] || exit "$status"
        fi
        chmod 600 "$t" || exit $?
        mv "$t" "$f" || exit $?
        trap - 0
        """
    }

    private static func validate(_ line: String) throws {
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == "ssh-ed25519",
              fields[1].utf8.count == 68,
              fields[1].utf8.allSatisfy({ $0 == 61 || $0 == 43 || $0 == 47 || ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) }),
              (1...64).contains(fields[2].utf8.count),
              fields[2].utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 46 || $0 == 95 || $0 == 64 || $0 == 45 }) else {
            throw AuthorizedKeyInstallError.invalidKeyLine
        }
    }
}
