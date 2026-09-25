import Foundation

/// A terminal colour from an SGR sequence: palette index (0–255) or 24-bit.
public enum ANSIColor: Equatable, Hashable, Sendable {
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct ANSIStyle: Equatable, Hashable, Sendable {
    public var foreground: ANSIColor?
    public var background: ANSIColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    public var strikethrough = false

    public init() {}
}

public struct ANSIRun: Equatable, Sendable {
    public var text: String
    public var style: ANSIStyle

    public init(text: String, style: ANSIStyle = ANSIStyle()) {
        self.text = text
        self.style = style
    }
}

/// Splits `pane.read --format ansi` output into lines of styled runs. Only SGR (`ESC[…m`)
/// is interpreted; other CSI, OSC and lone escapes are dropped. Style carries across lines,
/// as it does in the terminal stream.
public enum ANSILines {
    public static func parse(_ text: String) -> [[ANSIRun]] {
        var lines: [[ANSIRun]] = []
        var line: [ANSIRun] = []
        var style = ANSIStyle()
        var pending = ""
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func flushRun() {
            guard !pending.isEmpty else { return }
            if let last = line.last, last.style == style {
                line[line.count - 1].text += pending
            } else {
                line.append(ANSIRun(text: pending, style: style))
            }
            pending = ""
        }

        while i < scalars.count {
            let scalar = scalars[i]
            switch scalar {
            case "\u{1B}":
                flushRun()
                i += 1
                guard i < scalars.count else { break }
                if scalars[i] == "[" {
                    // CSI: parameters and intermediates, then a final byte 0x40–0x7E.
                    var params = ""
                    i += 1
                    while i < scalars.count, !(0x40...0x7E).contains(scalars[i].value) {
                        params.unicodeScalars.append(scalars[i]); i += 1
                    }
                    if i < scalars.count, scalars[i] == "m" { apply(params, to: &style) }
                    i += 1
                } else if scalars[i] == "]" {
                    // OSC: ends at BEL or ST (ESC \).
                    i += 1
                    while i < scalars.count {
                        if scalars[i] == "\u{07}" { i += 1; break }
                        if scalars[i] == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
                } else {
                    i += 1
                }
            case "\n":
                flushRun()
                lines.append(line)
                line = []
                i += 1
            case "\r", "\u{07}", "\u{08}":
                i += 1
            default:
                pending.unicodeScalars.append(scalar)
                i += 1
            }
        }
        flushRun()
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    private static func apply(_ params: String, to style: inout ANSIStyle) {
        var codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty { codes = [0] }
        var i = 0
        while i < codes.count {
            let code = codes[i]
            switch code {
            case 0: style = ANSIStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.strikethrough = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strikethrough = false
            case 30...37: style.foreground = .indexed(UInt8(code - 30))
            case 39: style.foreground = nil
            case 40...47: style.background = .indexed(UInt8(code - 40))
            case 49: style.background = nil
            case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                var color: ANSIColor?
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    color = .indexed(UInt8(clamping: codes[i + 2])); i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    color = .rgb(UInt8(clamping: codes[i + 2]), UInt8(clamping: codes[i + 3]), UInt8(clamping: codes[i + 4]))
                    i += 4
                }
                if code == 38 { style.foreground = color } else { style.background = color }
            default: break
            }
            i += 1
        }
    }
}
