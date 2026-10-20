// ExtraCommands.swift
// XTermux — sandbox module commands: text helpers, printf, test, xargs,
// file inspection (stat/du/df/tree) and shell conveniences (alias, expr).
//
// Everything here executes in-process inside the app sandbox: no fork/exec,
// no subprocesses, no privileges. Filesystem access always goes through
// FileSystemService so paths can never leave the sandbox root.

import Foundation

// MARK: - shared helpers

/// POSIX-style line handling shared by the text commands.
enum TextLines {
    /// Splits text into content lines. A final newline does not produce a
    /// trailing empty entry; interior empty lines are preserved.
    static func list(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    /// Joins content lines, each terminated with a newline.
    static func join(_ lines: [String]) -> String {
        lines.map { $0 + "\n" }.joined()
    }

    /// Reads the first file operand, or falls back to stdin. `label` prefixes
    /// any filesystem error (e.g. "uniq", "tac") like real utilities do.
    static func source(
        _ engine: ShellEngine,
        operands: [String],
        io: CommandIO,
        label: String
    ) -> String? {
        guard let file = operands.first else { return io.stdin }
        do {
            return try engine.fs.readText(file, relativeTo: engine.cwd).text
        } catch {
            io.printError("\(label): \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
            return nil
        }
    }
}

enum TextFormat {
    /// 1234 → "1.2M" style byte counts (du -h, df -h).
    static func humanBytes(_ bytes: Int64) -> String {
        let units: [(Int64, String)] = [(1 << 30, "G"), (1 << 20, "M"), (1 << 10, "K")]
        for (threshold, suffix) in units where bytes >= threshold {
            let value = Double(bytes) / Double(threshold)
            let rounded = (value * 10).rounded() / 10
            if rounded == rounded.rounded() { return "\(Int(rounded))\(suffix)" }
            return String(format: "%.1f", rounded) + suffix
        }
        return String(bytes)
    }
}

enum ShellPad {
    /// Space padding for text columns (left/right justify).
    static func text(_ value: String, width: Int?, right: Bool) -> String {
        guard let width, value.count < width else { return value }
        let filler = String(repeating: " ", count: width - value.count)
        return right ? filler + value : value + filler
    }

    /// Numeric padding with the optional zero flag; signs stay in front
    /// ("%-05.2f"/"-0042" C semantics for %0Nd of negative values).
    static func number(_ value: String, width: Int?, zero: Bool, right: Bool) -> String {
        guard let width, value.count < width else { return value }
        let fillerCount = width - value.count
        if zero, !right, let sign = value.first, sign == "-" || sign == "+" {
            let rest = String(value.dropFirst())
            return String(sign) + String(repeating: "0", count: fillerCount) + rest
        }
        let filler = String(repeating: zero ? "0" : " ", count: fillerCount)
        return right ? filler + value : value + filler
    }
}

/// C-style printf subset shared by `printf` and awk's printf statement.
/// Recognizes %[-][0][width][.prec]s and %d %i %u %x %X %f, plus %%; escapes
/// \n \t \r \\ are translated. Anything else is an honest error.
enum ShellFormat {
    /// Removes one layer of fully-wrapping quotes ('…' or "…").
    static func stripWrappingQuotes(_ value: String) -> String {
        guard value.count >= 2,
              (value.hasPrefix("'") && value.hasSuffix("'")) ||
              (value.hasPrefix("\"") && value.hasSuffix("\"")) else { return value }
        return String(value.dropFirst().dropLast())
    }

    struct Rendered {
        var text: String
        var consumed: Int
        var error: String?
    }

    static func render(_ format: String, arguments: ArraySlice<String>) -> Rendered {
        var out = ""
        var consumed = 0
        var index = format.startIndex

        func takeArg() -> String {
            defer { consumed += 1 }
            return arguments.isEmpty ? "" : arguments[arguments.startIndex + consumed]
        }

        func takeIntArg(_ spec: Character) -> Int64? {
            let raw = takeArg()
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let parsed = Int64(trimmed) { return parsed }
            // Integer stored in a string field is tolerated when it is numeric;
            // otherwise the caller reports the error.
            return nil
        }

        while index < format.endIndex {
            let character = format[index]

            if character == "\\" {
                let next = format.index(after: index)
                if next < format.endIndex {
                    switch format[next] {
                    case "n": out.append("\n"); index = format.index(after: next); continue
                    case "t": out.append("\t"); index = format.index(after: next); continue
                    case "r": out.append("\r"); index = format.index(after: next); continue
                    case "0": out.append("\0"); index = format.index(after: next); continue
                    case "\\": out.append("\\"); index = format.index(after: next); continue
                    default: break
                    }
                }
            }

            if character != "%" {
                out.append(character)
                index = format.index(after: index)
                continue
            }

            // Parse the specifier.
            var cursor = format.index(after: index)
            var leftAlign = false
            var zeroPad = false
            while cursor < format.endIndex, format[cursor] == "-" || format[cursor] == "0" {
                if format[cursor] == "-" { leftAlign = true; zeroPad = false }
                else { if !leftAlign { zeroPad = true } }
                cursor = format.index(after: cursor)
            }
            var widthText = ""
            while cursor < format.endIndex, format[cursor].isNumber {
                widthText.append(format[cursor])
                cursor = format.index(after: cursor)
            }
            var precisionText: String?
            if cursor < format.endIndex, format[cursor] == "." {
                cursor = format.index(after: cursor)
                var digits = ""
                while cursor < format.endIndex, format[cursor].isNumber {
                    digits.append(format[cursor])
                    cursor = format.index(after: cursor)
                }
                precisionText = digits.isEmpty ? "0" : digits
            }
            guard cursor < format.endIndex else {
                return Rendered(text: out, consumed: consumed, error: "printf: unterminated '%' specification")
            }
            let spec = format[cursor]
            let width = widthText.isEmpty ? nil : Int(widthText)
            cursor = format.index(after: cursor)

            switch spec {
            case "%":
                out.append("%")
            case "s":
                var value = takeArg()
                if let precision = precisionText.flatMap(Int.init), precision < value.count {
                    value = String(value.prefix(precision))
                }
                out += ShellPad.text(value, width: width, right: !leftAlign)
            case "d", "i":
                guard let number = takeIntArg(spec) else {
                    let raw = consumed <= 0 ? "" : arguments[arguments.startIndex + consumed - 1]
                    return Rendered(text: out, consumed: consumed,
                                    error: "printf: d: '\(raw)' is not an integer")
                }
                let text = String(number)
                out += ShellPad.number(text, width: width, zero: zeroPad, right: !leftAlign)
            case "u":
                guard let number = takeIntArg(spec) else {
                    return Rendered(text: out, consumed: consumed,
                                    error: "printf: u: argument is not an integer")
                }
                let text = String(UInt64(bitPattern: number))
                out += ShellPad.number(text, width: width, zero: zeroPad, right: !leftAlign)
            case "x", "X":
                guard let number = takeIntArg(spec) else {
                    return Rendered(text: out, consumed: consumed,
                                    error: "printf: \(spec): argument is not an integer")
                }
                var text = String(UInt64(bitPattern: number), radix: 16)
                if spec == "X" { text = text.uppercased() }
                out += ShellPad.number(text, width: width, zero: zeroPad, right: !leftAlign)
            case "f":
                let raw = takeArg()
                guard let number = Double(raw) else {
                    return Rendered(text: out, consumed: consumed,
                                    error: "printf: f: '\(raw)' is not numeric")
                }
                let digits = precisionText.flatMap(Int.init) ?? 6
                let text = String(format: "%.\(digits)f", number)
                out += ShellPad.number(text, width: width, zero: zeroPad, right: !leftAlign)
            default:
                return Rendered(text: out, consumed: consumed,
                                error: "printf: unsupported specification %\(spec) (supported: s d i u f x X %)")
            }
            index = cursor
        }
        return Rendered(text: out, consumed: consumed, error: nil)
    }
}

// MARK: - uniq

struct UniqCommand: ShellCommand {
    var name: String { "uniq" }
    var aliases: [String] { [] }
    var usage: String { "uniq [-c | -d | -u] [-i] [file]" }
    var help: String { "collapse adjacent duplicate lines (-c count, -d repeats, -u unique, -i case-insensitive)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var countMode = false
        var repeatsOnly = false
        var uniqueOnly = false
        var ignoreCase = false
        var operands: [String] = []
        for arg in args {
            if arg == "-c", !countMode { countMode = true }
            else if arg == "-d" { repeatsOnly = true }
            else if arg == "-u" { uniqueOnly = true }
            else if arg == "-i" { ignoreCase = true }
            else if ShellArgs.isFlag(arg) {
                if !countMode && Set(ShellArgs.flagCharacters(arg)).isSubset(of: ["c", "d", "u", "i"]) {
                    for character in ShellArgs.flagCharacters(arg) {
                        switch character {
                        case "c": countMode = true
                        case "d": repeatsOnly = true
                        case "u": uniqueOnly = true
                        case "i": ignoreCase = true
                        default: break
                        }
                    }
                } else {
                    io.printError("uniq: unsupported flag \(arg) (supported: -c -d -u -i)")
                    return 2
                }
            } else {
                operands.append(arg)
            }
        }

        guard let text = TextLines.source(engine, operands: operands, io: io, label: "uniq") else { return 1 }
        let lines = TextLines.list(text)

        struct Group {
            var first: String
            var occurrences: Int = 0
        }
        var groups: [Group] = []
        for line in lines {
            let current = ignoreCase ? line.lowercased() : line
            if let last = groups.last, (ignoreCase ? last.first.lowercased() : last.first) == current {
                groups[groups.count - 1].occurrences += 1
            } else {
                groups.append(Group(first: line, occurrences: 1))
            }
        }

        for group in groups {
            let line = group.first
            if group.occurrences == 1 && repeatsOnly { continue }
            if group.occurrences > 1 && uniqueOnly { continue }
            if countMode {
                io.printLine(TextPad.right(String(group.occurrences), 7) + " " + line)
            } else {
                io.printLine(line)
            }
        }
        return 0
    }
}

// MARK: - tac / rev / nl

struct TacCommand: ShellCommand {
    var name: String { "tac" }
    var aliases: [String] { [] }
    var usage: String { "tac [file]" }
    var help: String { "print a file in reverse line order" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard let text = TextLines.source(engine, operands: args, io: io, label: "tac") else { return 1 }
        io.writeOutput(TextLines.join(TextLines.list(text).reversed()))
        return 0
    }
}

struct RevCommand: ShellCommand {
    var name: String { "rev" }
    var aliases: [String] { [] }
    var usage: String { "rev [file]" }
    var help: String { "reverse the characters of every input line" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard let text = TextLines.source(engine, operands: args, io: io, label: "rev") else { return 1 }
        let lines = TextLines.list(text).map { String($0.reversed()) }
        io.writeOutput(TextLines.join(lines))
        return 0
    }
}

struct NlCommand: ShellCommand {
    var name: String { "nl" }
    var aliases: [String] { [] }
    var usage: String { "nl [-b a|t] [-w N] [file]" }
    var help: String { "number lines (-b t numbers non-empty lines, -b a numbers all; -w sets the width, default 6)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var numberAll = false
        var width = 6
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-b", index + 1 < args.count {
                let style = args[index + 1]
                guard style == "a" || style == "t" else {
                    io.printError("nl: unsupported -b style '\(style)' (supported: a t)")
                    return 2
                }
                numberAll = (style == "a")
                index += 1
            } else if arg.hasPrefix("-b"), arg.count > 2 {
                let style = String(arg.dropFirst(2))
                guard style == "a" || style == "t" else {
                    io.printError("nl: unsupported -b style '\(style)' (supported: a t)")
                    return 2
                }
                numberAll = (style == "a")
            } else if arg == "-w", index + 1 < args.count, let parsed = Int(args[index + 1]) {
                guard parsed >= 1, parsed <= 40 else {
                    io.printError("nl: width must be 1…40")
                    return 2
                }
                width = parsed
                index += 1
            } else if arg.hasPrefix("-w"), let parsed = Int(arg.dropFirst(2)), parsed >= 1, parsed <= 40 {
                width = parsed
            } else if ShellArgs.isFlag(arg) {
                io.printError("nl: unsupported flag \(arg) (supported: -b a|t -w N)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }

        guard let text = TextLines.source(engine, operands: operands, io: io, label: "nl") else { return 1 }
        var number = 0
        var output = ""
        for line in TextLines.list(text) {
            if numberAll || !line.isEmpty {
                number += 1
                output += TextPad.right(String(number), width) + "\t" + line + "\n"
            } else {
                output += line + "\n" // blank separator lines stay unnumbered
            }
        }
        io.writeOutput(output)
        return 0
    }
}

// MARK: - printf

struct PrintfCommand: ShellCommand {
    var name: String { "printf" }
    var aliases: [String] { [] }
    var usage: String { "printf FORMAT [argument…]" }
    var help: String { "write formatted text: %s %d %i %u %x %X %f, width/precision, %% , \\n \\t \\r \\\\" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard let format = args.first else {
            io.printError("printf: usage: printf FORMAT [arguments]")
            return 2
        }
        let rest = args.dropFirst()

        if !format.contains("%") {
            // No specifications: print the format once (extra args ignored,
            // matching coreutils) and still translate escapes.
            let rendered = ShellFormat.render(format, arguments: [] as ArraySlice<String>)
            io.writeOutput(rendered.text)
            return 0
        }

        var index = rest.startIndex
        while index < rest.endIndex {
            let rendered = ShellFormat.render(format, arguments: rest[index...])
            io.writeOutput(rendered.text)
            if let error = rendered.error {
                io.printError(error)
                return 1
            }
            // Guard against formats that consume nothing to avoid an endless loop.
            if rendered.consumed == 0 { break }
            index += rendered.consumed
        }
        return 0
    }
}

// MARK: - seq / sleep

struct SeqCommand: ShellCommand {
    var name: String { "seq" }
    var aliases: [String] { [] }
    var usage: String { "seq [-w] [-s SEP] LAST | seq [-w] [-s SEP] FIRST LAST | seq [-w] [-s SEP] FIRST INCR LAST" }
    var help: String { "print a numeric sequence (integers only); -w zero-pads, -s chooses the separator" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var zeroPad = false
        var separator = "\n"
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-w" { zeroPad = true }
            else if arg == "-s", index + 1 < args.count {
                let raw = args[index + 1]
                separator = raw == "\\n" ? "\n" : raw // allow literal \n
                index += 1
            } else if arg.hasPrefix("-s"), arg.count >= 2 {
                let raw = String(arg.dropFirst(2))
                separator = raw == "\\n" ? "\n" : raw
            } else if ShellArgs.isFlag(arg), Int64(arg) == nil {
                // Negative integers (for example "seq 3 -1 1") are operands, not flags.
                io.printError("seq: unsupported flag \(arg) (supported: -w -s SEP)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }

        var first: Int64 = 1
        var step: Int64 = 1
        var last: Int64
        switch operands.count {
        case 1:
            guard let value = Int64(operands[0]) else {
                io.printError("seq: '\(operands[0])' is not an integer")
                return 2
            }
            last = value
        case 2:
            guard let a = Int64(operands[0]), let b = Int64(operands[1]) else {
                io.printError("seq: values must be integers")
                return 2
            }
            first = a
            last = b
        case 3:
            guard let a = Int64(operands[0]), let s = Int64(operands[1]), let b = Int64(operands[2]) else {
                io.printError("seq: values must be integers")
                return 2
            }
            guard s != 0 else {
                io.printError("seq: INCREMENT must not be 0")
                return 2
            }
            first = a
            step = s
            last = b
        default:
            io.printError("seq: usage: \(usage)")
            return 2
        }

        var values: [Int64] = []
        var current = first
        let limit = 1_000_000
        while (step > 0 && current <= last) || (step < 0 && current >= last) {
            values.append(current)
            if values.count > limit {
                io.printError("seq: output exceeds \(limit) values — stopping honestly")
                return 1
            }
            // Guard against overflow by checking overshoot before adding.
            if (step > 0 && current > last - step) || (step < 0 && current < last - step) { break }
            current += step
        }

        var width = 1
        if zeroPad {
            let widest = max(abs(first), abs(last)).magnitude
            width = max(String(widest).count, 1) + (max(first, last) < 0 ? 1 : 0)
        }

        var out = ""
        for (i, value) in values.enumerated() {
            if i > 0 { out += separator }
            var text = String(value)
            if zeroPad, text.count < width { text = String(repeating: "0", count: width - text.count) + text }
            out += text
        }
        out += "\n"
        io.writeOutput(out)
        return 0
    }
}

struct SleepCommand: ShellCommand {
    var name: String { "sleep" }
    var aliases: [String] { [] }
    var usage: String { "sleep SECONDS[smh]…" }
    var help: String { "pause the session briefly (engine runs in-process; the honest limit is 60 seconds total)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard !args.isEmpty else {
            io.printError("sleep: usage: \(usage)")
            return 2
        }
        var total: Double = 0
        for arg in args {
            let value: String
            let suffix: String
            if let match = arg.firstIndex(where: { $0.isLetter }) {
                value = String(arg[..<match])
                suffix = String(arg[match...])
            } else {
                value = arg
                suffix = "s"
            }
            guard let number = Double(value) else {
                io.printError("sleep: invalid duration '\(arg)'")
                return 2
            }
            let multiplier: Double
            switch suffix {
            case "s": multiplier = 1
            case "m": multiplier = 60
            case "h": multiplier = 3600
            case "ms": multiplier = 0.001
            default:
                io.printError("sleep: unsupported unit '\(suffix)' (supported: s m h ms)")
                return 2
            }
            total += number * multiplier
        }
        guard total >= 0 else {
            io.printError("sleep: durations must be positive")
            return 2
        }
        if total > 60 {
            io.printError("sleep: limit is 60 seconds in the sandbox — the engine cannot block a session longer than that")
            return 1
        }
        Thread.sleep(forTimeInterval: total)
        return 0
    }
}

// MARK: - stat / du / df / tree

struct StatCommand: ShellCommand {
    var name: String { "stat" }
    var aliases: [String] { [] }
    var usage: String { "stat FILE…" }
    var help: String { "show sandbox metadata: path, size, type, permissions, modification time" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let operands = args.filter { !ShellArgs.isFlag($0) }
        guard !operands.isEmpty else {
            io.printError("stat: usage: \(usage)")
            return 2
        }
        let formatter = ISO8601DateFormatter()
        var failed = false
        for operand in operands {
            do {
                let entry = try engine.fs.stat(operand, relativeTo: engine.cwd)
                io.printLine("  File: \(entry.virtualPath)")
                if let size = entry.size {
                    io.printLine("  Size: \(size) bytes")
                } else {
                    io.printLine("  Size: —")
                }
                io.printLine("  Type: \(entry.isDirectory ? "directory" : "regular file")")
                io.printLine("  Mode: \(entry.permissions)")
                if let modified = entry.modified {
                    io.printLine("Modify: \(formatter.string(from: modified))")
                }
                io.printLine("")
            } catch {
                io.printError("stat: cannot stat '\(operand)': \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
}

struct DuCommand: ShellCommand {
    var name: String { "du" }
    var aliases: [String] { [] }
    var usage: String { "du [-s] [-h] [path]" }
    var help: String { "sandbox disk usage: every directory's total size; -s summary only, -h human units" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var summary = false
        var human = false
        var operands: [String] = []
        for arg in args {
            if ShellArgs.isFlag(arg) {
                let flags = ShellArgs.flagCharacters(arg)
                if flags.isSubset(of: ["s", "h"]) {
                    if flags.contains("s") { summary = true }
                    if flags.contains("h") { human = true }
                } else {
                    io.printError("du: unsupported flag \(arg) (supported: -s -h)")
                    return 2
                }
            } else {
                operands.append(arg)
            }
        }

        var failed = false
        for operand in operands.isEmpty ? ["."] : operands {
            var errorReported = false
            func walk(_ virtual: String, display: String, depth: Int) -> Int64 {
                if depth > 64 {
                    if !errorReported {
                        io.printError("du: \(display): nested too deeply — stopped at depth 64")
                        errorReported = true
                        failed = true
                    }
                    return 0
                }
                var total: Int64 = 0
                let entries: [FSEntry]
                do {
                    entries = try engine.fs.listEntries(virtual, relativeTo: engine.cwd, includeHidden: true)
                } catch {
                    if !errorReported {
                        io.printError("du: cannot access '\(display)': \((error as? FileSystemError)?.errorDescription ?? "error")")
                        errorReported = true
                        failed = true
                    }
                    return 0
                }
                for entry in entries {
                    if entry.isDirectory {
                        let childDisplay = display == "/" ? "/" + entry.name : display + "/" + entry.name
                        let size = walk(entry.virtualPath, display: childDisplay, depth: depth + 1)
                        total += size
                        if !summary {
                            let text = human ? TextFormat.humanBytes(size) : String(size)
                            io.printLine(String(TextPad.right(text, 8)) + "  " + childDisplay)
                        }
                    } else {
                        total += Int64(entry.size ?? 0)
                    }
                }
                return total
            }

            let resolvedDisplay: String
            do {
                resolvedDisplay = try SandboxPath.resolve(operand, relativeTo: engine.cwd)
            } catch {
                io.printError("du: cannot access '\(operand)': \((error as? FileSystemError)?.errorDescription ?? "error")")
                failed = true
                continue
            }
            let total = walk(resolvedDisplay, display: resolvedDisplay, depth: 0)
            let text = human ? TextFormat.humanBytes(total) : String(total)
            io.printLine(String(TextPad.right(text, 8)) + "  " + resolvedDisplay)
        }
        return failed ? 1 : 0
    }
}

/// Private helper so du/df print fixed-width columns without relying on
/// Foundation's CVarArg bridge (which differs subtly across platforms).
enum TextPad {
    static func right(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}

struct DfCommand: ShellCommand {
    var name: String { "df" }
    var aliases: [String] { [] }
    var usage: String { "df [-h]" }
    var help: String { "report the real volume behind the sandbox (Size/Used/Avail); -h human units" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let human = ShellArgs.containsFlag(args, ["h"])
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: engine.fs.baseURL.path)
        guard let attributes,
              let total = (attributes[.systemSize] as? NSNumber)?.int64Value,
              let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            io.printError("df: cannot determine volume statistics for the sandbox")
            return 1
        }
        let used = total - free
        let percent = total > 0 ? Int((Double(used) / Double(total) * 100).rounded()) : 0
        let name = "xtermux (sandbox)"
        io.printLine(String(TextPad.right("Filesystem", 18)) +
                     String(TextPad.right("Size", 7)) +
                     String(TextPad.right("Used", 7)) +
                     String(TextPad.right("Avail", 7)) +
                     String(TextPad.right("Use%", 6)))
        func cell(_ value: Int64) -> String {
            human ? TextFormat.humanBytes(value) : String(value)
        }
        io.printLine(String(TextPad.right(name, 18)) +
                     String(TextPad.right(cell(total), 7)) +
                     String(TextPad.right(cell(used), 7)) +
                     String(TextPad.right(cell(free), 7)) +
                     String(TextPad.right("\(percent)%", 6)))
        io.printLine("note: Used ≈ Size − Avail (purgeable space on the device is not counted)")
        return 0
    }
}

struct TreeCommand: ShellCommand {
    var name: String { "tree" }
    var aliases: [String] { [] }
    var usage: String { "tree [-a] [-L DEPTH] [path]" }
    var help: String { "list a directory as a tree; -a shows hidden entries, -L limits depth" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var showHidden = false
        var maxDepth = 32
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-a" { showHidden = true }
            else if arg == "-L", index + 1 < args.count {
                guard let level = Int(args[index + 1]), level >= 1, level <= 32 else {
                    io.printError("tree: invalid DEPTH (1…32)")
                    return 2
                }
                maxDepth = level
                index += 1
            } else if arg.hasPrefix("-L"), let level = Int(arg.dropFirst(2)), level >= 1, level <= 32 {
                maxDepth = level
            } else if ShellArgs.isFlag(arg) {
                io.printError("tree: unsupported flag \(arg) (supported: -a -L DEPTH)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }

        let root = operands.first ?? "."
        guard engine.fs.isDirectory(root, relativeTo: engine.cwd) else {
            io.printError("tree: not a directory: \(root)")
            return 1
        }
        var directories = 0
        var files = 0

        func walk(_ virtual: String, prefix: String, depth: Int) throws {
            let entries = try engine.fs.listEntries(virtual, relativeTo: engine.cwd, includeHidden: showHidden)
            for (position, entry) in entries.enumerated() {
                let isLast = position == entries.count - 1
                let connector = isLast ? "└── " : "├── "
                io.printLine(prefix + connector + entry.name)
                if entry.isDirectory {
                    directories += 1
                    if depth + 1 < maxDepth {
                        try walk(entry.virtualPath,
                                 prefix: prefix + (isLast ? "    " : "│   "),
                                 depth: depth + 1)
                    }
                } else {
                    files += 1
                }
            }
        }

        let resolved: String
        do {
            resolved = try SandboxPath.resolve(root, relativeTo: engine.cwd)
        } catch {
            io.printError("tree: cannot access '\(root)': \((error as? FileSystemError)?.errorDescription ?? "error")")
            return 1
        }
        io.printLine(resolved)
        do {
            try walk(resolved, prefix: "", depth: 0)
        } catch {
            io.printError("tree: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
            return 1
        }
        io.printLine("")
        io.printLine("\(directories) director\(directories == 1 ? "y" : "ies"), \(files) file\(files == 1 ? "" : "s")")
        return 0
    }
}

// MARK: - basename / dirname

struct BasenameCommand: ShellCommand {
    var name: String { "basename" }
    var aliases: [String] { [] }
    var usage: String { "basename PATH [SUFFIX] | basename -s SUFFIX PATH…" }
    var help: String { "strip directory and optional suffix from a path (string operation only)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var suffix: String?
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-s", index + 1 < args.count {
                suffix = args[index + 1]
                index += 1
            } else if arg.hasPrefix("-"), arg != "-" {
                io.printError("basename: unsupported flag \(arg)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }
        guard let first = operands.first else {
            io.printError("basename: usage: \(usage)")
            return 2
        }

        func component(_ path: String) -> String {
            var trimmed = path
            while trimmed.count > 1 && trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            if trimmed == "/" { return "/" }
            let name = trimmed.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            var result = name
            let suffixes = suffix.map { [$0] } ?? (operands.count >= 2 ? [operands[1]] : [])
            for candidate in suffixes where result.hasSuffix(candidate) && result.count > candidate.count {
                result.removeLast(candidate.count)
            }
            return result
        }

        if suffix != nil {
            for operand in operands {
                io.printLine(component(operand))
            }
        } else {
            io.printLine(component(first))
        }
        return 0
    }
}

struct DirnameCommand: ShellCommand {
    var name: String { "dirname" }
    var aliases: [String] { [] }
    var usage: String { "dirname NAME…" }
    var help: String { "print the parent-directory part of each path (string operation only)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let operands = args.filter { !ShellArgs.isFlag($0) }
        guard !operands.isEmpty else {
            io.printError("dirname: usage: \(usage)")
            return 2
        }
        for operand in operands {
            var path = operand
            if path == "/" { io.printLine("/"); continue }
            while path.hasSuffix("/") { path.removeLast() }
            guard let slash = path.lastIndex(of: "/") else {
                io.printLine(".")
                continue
            }
            let parent = String(path[..<slash])
            if parent.isEmpty {
                io.printLine("/")
            } else {
                var trimmed = parent
                while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
                io.printLine(trimmed)
            }
        }
        return 0
    }
}

// MARK: - expr

struct ExprCommand: ShellCommand {
    var name: String { "expr" }
    var aliases: [String] { [] }
    var usage: String { "expr A OP B… | expr length STRING | expr substr STRING POS LEN" }
    var help: String { "integer arithmetic (+ - * / %, precedence respected), length, substr" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        func fail(_ message: String) -> Int {
            io.printError("expr: \(message)")
            return 2
        }
        guard !args.isEmpty else { return fail("usage: \(usage)") }

        if args[0] == "length" {
            guard args.count == 2 else { return fail("length needs exactly one string") }
            let result = args[1]
            if result.isEmpty { io.printLine("0"); return 1 }
            io.printLine(String(result.count))
            return 0
        }
        if args[0] == "substr" {
            guard args.count == 4 else { return fail("substr needs STRING POS LEN") }
            guard let position = Int(args[2]), let length = Int(args[3]), position >= 1, length >= 0 else {
                return fail("POS and LEN must be positive integers")
            }
            let characters = Array(args[1])
            if position > characters.count {
                io.printLine("")
                return 1
            }
            let start = position - 1
            let end = min(start + length, characters.count)
            let result = String(characters[start..<end])
            io.printLine(result)
            return result.isEmpty ? 1 : 0
        }

        // Integer expression chain with precedence: * / % above + -.
        var operands: [Int64] = []
        var operators: [Character] = []
        var position = 0

        func nextOperand() -> Int64? {
            guard position < args.count else { return nil }
            let token = args[position]
            position += 1
            if let number = Int64(token) { return number }
            if token == "-" || token == "+" || token == "*" || token == "/" || token == "%" { return nil }
            // A bare non-numeric word is rejected honestly rather than coerced.
            return nil
        }

        guard let first = nextOperand() else { return fail(position == 0 ? "syntax error" : "non-integer argument: \(args[position - 1])") }
        operands.append(first)

        while position < args.count {
            let op = args[position]
            guard op.count == 1, let opCharacter = op.first,
                  "+-*/%".contains(opCharacter) else { return fail("unsupported token '\(op)'") }
            position += 1
            guard let rhs = nextOperand() else { return fail("syntax error after '\(op)'") }
            operators.append(opCharacter)
            operands.append(rhs)
        }

        // Precedence pass for * / %, then a final + - pass.
        var pass1Values: [Int64] = [operands[0]]
        var pass1Operators: [Character] = []
        var valueIndex = 1
        var operatorIndex = 0
        while operatorIndex < operators.count {
            let op = operators[operatorIndex]
            let rhs = operands[valueIndex]
            if op == "*" || op == "/" || op == "%" {
                let lhs = pass1Values.removeLast()
                guard let result = apply(lhs, op, rhs, io: io) else { return 2 }
                pass1Values.append(result)
            } else {
                pass1Operators.append(op)
                pass1Values.append(rhs)
            }
            operatorIndex += 1
            valueIndex += 1
        }
        var resultValue = pass1Values[0]
        var passIndex = 0
        while passIndex < pass1Operators.count {
            guard let combined = apply(resultValue, pass1Operators[passIndex], pass1Values[passIndex + 1], io: io) else { return 2 }
            resultValue = combined
            passIndex += 1
        }

        io.printLine(String(resultValue))
        return resultValue == 0 ? 1 : 0
    }

    private func apply(_ lhs: Int64, _ op: Character, _ rhs: Int64, io: CommandIO) -> Int64? {
        switch op {
        case "+": return lhs &+ rhs
        case "-": return lhs &- rhs
        case "*": return lhs &* rhs
        case "/":
            guard rhs != 0 else {
                io.printError("expr: division by zero")
                return nil
            }
            return lhs / rhs
        case "%":
            guard rhs != 0 else {
                io.printError("expr: division by zero")
                return nil
            }
            return lhs % rhs
        default: return nil
        }
    }
}

// MARK: - alias / unalias

struct AliasCommand: ShellCommand {
    var name: String { "alias" }
    var aliases: [String] { [] }
    var usage: String { "alias [name=value… | name…]" }
    var help: String { "define or list session aliases (quotes required if the value contains spaces; sessions only)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        if args.isEmpty {
            for key in engine.aliases.keys.sorted() {
                io.printLine("alias \(key)='\(engine.aliases[key] ?? "")'")
            }
            return 0
        }
        if args[0].contains("=") {
            // Definition form(s): `alias a=1 b=2 …`.
            for arg in args {
                guard let equals = arg.firstIndex(of: "=") else {
                    io.printError("alias: missing '=' in '\(arg)'")
                    return 2
                }
                let name = String(arg[..<equals])
                let value = ShellFormat.stripWrappingQuotes(String(arg[arg.index(after: equals)...]))
                guard !name.isEmpty, !name.contains(" ") else {
                    io.printError("alias: invalid name '\(name)'")
                    return 2
                }
                engine.aliases[name] = value
                io.printLine("alias \(name)='\(value)'")
            }
            return 0
        }
        if args.count == 1 {
            guard let value = engine.aliases[args[0]] else {
                io.printError("alias: \(args[0]): not found")
                return 1
            }
            io.printLine("alias \(args[0])='\(value)'")
            return 0
        }
        // `alias g ls -la` is another spelling of `alias g='ls -la'`.
        let name = args[0]
        let value = ShellFormat.stripWrappingQuotes(args.dropFirst().joined(separator: " "))
        guard !name.contains(" ") else {
            io.printError("alias: invalid name '\(name)'")
            return 2
        }
        engine.aliases[name] = value
        io.printLine("alias \(name)='\(value)'")
        return 0
    }
}

struct UnaliasCommand: ShellCommand {
    var name: String { "unalias" }
    var aliases: [String] { [] }
    var usage: String { "unalias name… | unalias -a" }
    var help: String { "remove session aliases (-a removes all)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard !args.isEmpty else {
            io.printError("unalias: usage: \(usage)")
            return 2
        }
        if ShellArgs.containsFlag(args, ["a"]) {
            engine.aliases.removeAll()
            return 0
        }
        var failed = false
        for arg in args where !ShellArgs.isFlag(arg) {
            if engine.aliases.removeValue(forKey: arg) == nil {
                io.printError("unalias: \(arg): not found")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
}

// MARK: - test / [

struct TestCommand: ShellCommand {
    var name: String { "test" }
    var aliases: [String] { ["["] }
    var usage: String { "test EXPRESSION | [ EXPRESSION ]" }
    var help: String { "evaluate a condition: -e -f -d -s -r -w -x files, -z -n strings, = !=, -eq -ne -lt -le -gt -ge, ! -a -o, ( )" }

    private final class Cursor {
        let tokens: [String]
        var index = 0

        init(_ tokens: [String]) { self.tokens = tokens }
        var atEnd: Bool { index >= tokens.count }
        var current: String? { atEnd ? nil : tokens[index] }
        func advance() { index += 1 }
    }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var tokens = args
        // When invoked as `[`, the closing bracket must close the expression.
        // `engine.lastInvokedName` reports the name the user actually typed.
        if engine.lastInvokedName == "[" {
            guard tokens.last == "]" else {
                io.printError("test: missing ']'")
                return 2
            }
            tokens.removeLast()
        } else if !tokens.isEmpty, tokens.last == "]" {
            // `test … ]` is malformed.
            io.printError("test: unexpected ']'")
            return 2
        }
        return evaluate(tokens, engine: engine, io: io)
    }

    private func evaluate(_ tokens: [String], engine: ShellEngine, io: CommandIO) -> Int {
        guard !tokens.isEmpty else { return 0 } // bare `test` is true
        let cursor = Cursor(tokens)
        do {
            let result = try orExpression(cursor, engine: engine)
            guard cursor.atEnd else {
                io.printError("test: unexpected token '\(cursor.current ?? "")'")
                return 2
            }
            return result ? 0 : 1
        } catch let error as TestError {
            io.printError("test: \(error.message)")
            return 2
        } catch {
            io.printError("test: \(String(describing: error))")
            return 2
        }
    }

    private struct TestError: Error { let message: String }

    private enum BinaryOp: String {
        case equal = "="
        case notEqual = "!="
        case eq = "-eq"
        case ne = "-ne"
        case lt = "-lt"
        case le = "-le"
        case gt = "-gt"
        case ge = "-ge"

        static let all: [String] = ["=", "!=", "-eq", "-ne", "-lt", "-le", "-gt", "-ge"]
    }

    private func orExpression(_ cursor: Cursor, engine: ShellEngine) throws -> Bool {
        var result = try andExpression(cursor, engine: engine)
        while cursor.current == "-o" {
            cursor.advance()
            let rhs = try andExpression(cursor, engine: engine)
            result = result || rhs
        }
        return result
    }

    private func andExpression(_ cursor: Cursor, engine: ShellEngine) throws -> Bool {
        var result = try notExpression(cursor, engine: engine)
        while cursor.current == "-a" {
            cursor.advance()
            let rhs = try notExpression(cursor, engine: engine)
            result = result && rhs
        }
        return result
    }

    private func notExpression(_ cursor: Cursor, engine: ShellEngine) throws -> Bool {
        if cursor.current == "!" {
            cursor.advance()
            return try !notExpression(cursor, engine: engine)
        }
        return try primary(cursor, engine: engine)
    }

    private func primary(_ cursor: Cursor, engine: ShellEngine) throws -> Bool {
        guard let token = cursor.current else { throw TestError(message: "expression expected") }
        if token == "(" {
            cursor.advance()
            let inner = try orExpression(cursor, engine: engine)
            guard cursor.current == ")" else { throw TestError(message: "missing ')'") }
            cursor.advance()
            return inner
        }

        let unaryFlags: Set<String> = ["-e", "-f", "-d", "-s", "-r", "-w", "-x", "-z", "-n"]
        if unaryFlags.contains(token), !(cursor.index + 1 < cursor.tokens.count && BinaryOp.all.contains(cursor.tokens[cursor.index + 1])) {
            cursor.advance()
            guard let operand = cursor.current else {
                throw TestError(message: "missing argument after \(token)")
            }
            cursor.advance()
            return runUnary(token, operand: operand, engine: engine)
        }

        // Operand, optionally followed by a binary operator.
        let binaryIndex = cursor.index + 1
        let maybeOperator = binaryIndex < cursor.tokens.count ? cursor.tokens[binaryIndex] : ""
        guard BinaryOp.all.contains(maybeOperator),
              !unaryFlags.contains(token) else {
            cursor.advance()
            return !token.isEmpty
        }

        let lhs = token
        cursor.advance() // lhs
        cursor.advance() // operator
        guard let rhs = cursor.current else {
            throw TestError(message: "missing argument after \(maybeOperator)")
        }
        cursor.advance()
        let op = BinaryOp(rawValue: maybeOperator)!
        switch op {
        case .equal: return lhs == rhs
        case .notEqual: return lhs != rhs
        case .eq, .ne, .lt, .le, .gt, .ge:
            guard let left = Int64(lhs.trimmingCharacters(in: .whitespaces)) else {
                throw TestError(message: "integer expression expected: '\(lhs)'")
            }
            guard let right = Int64(rhs.trimmingCharacters(in: .whitespaces)) else {
                throw TestError(message: "integer expression expected: '\(rhs)'")
            }
            switch op {
            case .eq: return left == right
            case .ne: return left != right
            case .lt: return left < right
            case .le: return left <= right
            case .gt: return left > right
            case .ge: return left >= right
            default: return false
            }
        }
    }

    private func runUnary(_ flag: String, operand path: String, engine: ShellEngine) -> Bool {
        switch flag {
        case "-z": return path.isEmpty
        case "-n": return !path.isEmpty
        default: break
        }
        switch flag {
        case "-e":
            return engine.fs.exists(path, relativeTo: engine.cwd)
        case "-f":
            return engine.fs.exists(path, relativeTo: engine.cwd) && !engine.fs.isDirectory(path, relativeTo: engine.cwd)
        case "-d":
            return engine.fs.isDirectory(path, relativeTo: engine.cwd)
        case "-s":
            let entry = try? engine.fs.stat(path, relativeTo: engine.cwd)
            return (entry?.size ?? 0) > 0
        case "-r", "-w", "-x":
            guard let url = try? engine.fs.realURL(path, relativeTo: engine.cwd) else { return false }
            let manager = FileManager.default
            switch flag {
            case "-r": return manager.isReadableFile(atPath: url.path)
            case "-w": return manager.isWritableFile(atPath: url.path)
            case "-x": return manager.isExecutableFile(atPath: url.path)
            default: return false
            }
        default:
            return false
        }
    }
}

// MARK: - xargs

struct XargsCommand: ShellCommand {
    var name: String { "xargs" }
    var aliases: [String] { [] }
    var usage: String { "xargs [-n N] [command [argument…]]" }
    var help: String { "run a command once per batch of stdin words appended as arguments (default command: echo)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var batchLimit: Int?
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-n", index + 1 < args.count, let parsed = Int(args[index + 1]), parsed >= 1 {
                batchLimit = parsed
                index += 1
            } else if arg.hasPrefix("-n"), let parsed = Int(arg.dropFirst(2)), parsed >= 1 {
                batchLimit = parsed
            } else if ShellArgs.isFlag(arg) {
                io.printError("xargs: unsupported flag \(arg) (supported: -n N)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }

        let words = io.stdin.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }.map(String.init)
        let commandName = operands.first ?? "echo"
        let initialArguments = Array(operands.dropFirst())

        var batches: [[String]]
        if words.isEmpty {
            batches = [[]] // POSIX: empty stdin still runs the command once
        } else if let limit = batchLimit {
            batches = stride(from: 0, to: words.count, by: limit).map {
                Array(words[$0..<min($0 + limit, words.count)])
            }
        } else {
            batches = [words]
        }

        var lastExit = 0
        for batch in batches {
            switch engine.resolve(commandName) {
            case .found(let command):
                let child = CommandIO()
                let code = command.run(engine, args: initialArguments + batch, io: child)
                io.writeOutput(child.out)
                io.writeError(child.err)
                if code != 0 { lastExit = code }
            case .notInstalled(let module):
                io.printError("xargs: \(commandName) — pkg '\(module)' is not installed (run: pkg install \(module))")
                return 127
            case .unknown:
                io.printError("xargs: command not found: \(commandName)")
                return 127
            }
        }
        return lastExit
    }
}
