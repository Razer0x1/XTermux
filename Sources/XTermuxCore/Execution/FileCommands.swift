// FileCommands.swift
// XTermux — filesystem builtins: ls, cd, cat, mkdir, touch, cp, mv, rm, find,
// grep, head, tail, wc, chmod.
//
// All path handling goes through FileSystemService / SandboxPath, which reject
// traversal outside the app sandbox. Nothing here touches protected iOS
// directories — this can only ever see the app's own container.

import Foundation

// MARK: cd

struct CdCommand: ShellCommand {
    var name: String { "cd" }
    var aliases: [String] { [] }
    var usage: String { "cd [path]" }
    var help: String { "change the working directory (~ is the sandbox home)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let target = args.first { !ShellArgs.isFlag($0) } ?? "~"
        do {
            _ = try engine.chdir(target)
            return 0
        } catch {
            io.printError("cd: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
            return 1
        }
    }
}

// MARK: ls

struct LsCommand: ShellCommand {
    var name: String { "ls" }
    var aliases: [String] { ["dir"] }
    var usage: String { "ls [-l] [-a] [path…]" }
    var help: String { "list files (-l long format, -a include hidden)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let long = ShellArgs.containsFlag(args, ["l"])
        let all = ShellArgs.containsFlag(args, ["a"])
        let targets = args.filter { !ShellArgs.isFlag($0) }
        let list = targets.isEmpty ? ["."] : targets
        let multiTarget = list.count > 1
        var status = 0

        for target in list {
            do {
                let resolved = try SandboxPath.resolve(target, relativeTo: engine.cwd)
                let stat = try engine.fs.stat(resolved, relativeTo: "/")
                if !stat.isDirectory {
                    io.printLine(long ? Self.longLine(stat) : (stat.isDirectory ? stat.name + "/" : stat.name))
                    continue
                }
                let entries = try engine.fs.listEntries(resolved, relativeTo: "/", includeHidden: all)
                if multiTarget {
                    io.printLine("")
                    io.printLine("\(target):")
                }
                if long {
                    for entry in entries { io.printLine(Self.longLine(entry)) }
                } else {
                    let names = entries.map { entry in entry.isDirectory ? entry.name + "/" : entry.name }
                    let text = Self.columns(names, width: max(40, engine.terminalWidth))
                    if !text.isEmpty { io.writeOutput(text) }
                }
            } catch {
                io.printError("ls: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
                status = 1
            }
        }
        return status
    }

    static func longLine(_ entry: FSEntry) -> String {
        let size = entry.size.map { rightAligned(String($0), 8) } ?? rightAligned("-", 8)
        let date = entry.modified.map { Self.dateFormatter.string(from: $0) } ?? "           "
        let name = entry.name + (entry.isDirectory ? "/" : "")
        return "\(entry.permissions) \(size) \(date) \(name)"
    }

    static func columns(_ names: [String], width: Int) -> String {
        guard !names.isEmpty else { return "" }
        let maxLen = max(names.map { $0.count }.max() ?? 1, 1)
        let cols = max(1, (width - 1) / (maxLen + 2))
        var out = ""
        var index = 0
        while index < names.count {
            let row = Array(names[index..<min(index + cols, names.count)])
            var line = ""
            for (i, name) in row.enumerated() {
                line += i == row.count - 1 ? name : name.padding(toLength: maxLen + 2, withPad: " ", startingAt: 0)
            }
            out += line + "\n"
            index += cols
        }
        return out
    }

    static func rightAligned(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()
}

// MARK: cat

struct CatCommand: ShellCommand {
    var name: String { "cat" }
    var aliases: [String] { [] }
    var usage: String { "cat FILE… | cat" }
    var help: String { "print file contents raw ('-' reads from stdin in a pipe)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let targets = args.filter { !ShellArgs.isFlag($0) }
        guard !targets.isEmpty else {
            if !io.stdin.isEmpty { io.writeOutput(io.stdin); return 0 }
            io.printError("cat: no input (pass files or pipe data in)")
            return 1
        }
        var status = 0
        for target in targets {
            if target == "-" {
                io.writeOutput(io.stdin)
                continue
            }
            do {
                let (text, truncated) = try engine.fs.readText(target, relativeTo: engine.cwd)
                if truncated {
                    io.printError("cat: \(target): warning — preview truncated at 8 MB")
                }
                io.writeOutput(text)
            } catch {
                let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                io.printError("cat: \(target): \(desc)")
                status = 1
            }
        }
        return status
    }
}

// MARK: mkdir / touch

struct MkdirCommand: ShellCommand {
    var name: String { "mkdir" }
    var aliases: [String] { [] }
    var usage: String { "mkdir [-p] DIR…" }
    var help: String { "create directories (-p creates intermediate parents)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let recursive = ShellArgs.containsFlag(args, ["p"])
        let targets = args.filter { !ShellArgs.isFlag($0) }
        guard !targets.isEmpty else {
            io.printError("mkdir: missing operand")
            return 1
        }
        var status = 0
        for target in targets {
            do {
                try engine.fs.createDirectory(target, relativeTo: engine.cwd, recursive: recursive)
            } catch {
                let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                io.printError("mkdir: cannot create directory '\(target)': \(desc)")
                status = 1
            }
        }
        return status
    }
}

struct TouchCommand: ShellCommand {
    var name: String { "touch" }
    var aliases: [String] { [] }
    var usage: String { "touch FILE…" }
    var help: String { "create empty files, or refresh modification times" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let targets = args.filter { !ShellArgs.isFlag($0) }
        guard !targets.isEmpty else {
            io.printError("touch: missing operand")
            return 1
        }
        var status = 0
        for target in targets {
            do {
                try engine.fs.touchFile(target, relativeTo: engine.cwd)
            } catch {
                let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                io.printError("touch: cannot touch '\(target)': \(desc)")
                status = 1
            }
        }
        return status
    }
}

// MARK: cp / mv / rm

struct CpCommand: ShellCommand {
    var name: String { "cp" }
    var aliases: [String] { [] }
    var usage: String { "cp [-r] SOURCE… DEST" }
    var help: String { "copy files or directories into DEST (-r for trees)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let recursive = ShellArgs.containsFlag(args, ["r", "R"])
        let operands = args.filter { !ShellArgs.isFlag($0) }
        guard operands.count >= 2 else {
            io.printError("cp: usage: cp [-r] SOURCE… DEST")
            return 1
        }
        let destination = operands.last!
        let sources = Array(operands.dropLast())
        let destinationIsDir = engine.fs.isDirectory(destination, relativeTo: engine.cwd)
        var status = 0

        if sources.count > 1 && !destinationIsDir {
            io.printError("cp: target '\(destination)' is not a directory")
            return 1
        }
        for source in sources {
            let sourceIsDir = engine.fs.isDirectory(source, relativeTo: engine.cwd)
            if sourceIsDir && !recursive {
                io.printError("cp: '\(source)' is a directory (use -r)")
                status = 1
                continue
            }
            do {
                // File→file overwrites (POSIX behavior); copy-into-dir handled by fs.copy.
                if !destinationIsDir && !sourceIsDir && engine.fs.exists(destination, relativeTo: engine.cwd) {
                    try engine.fs.delete(destination, relativeTo: engine.cwd)
                }
                _ = try engine.fs.copy(source, to: destination, relativeTo: engine.cwd)
            } catch {
                let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                io.printError("cp: cannot copy '\(source)': \(desc)")
                status = 1
            }
        }
        return status
    }
}

struct MvCommand: ShellCommand {
    var name: String { "mv" }
    var aliases: [String] { [] }
    var usage: String { "mv SOURCE… DEST" }
    var help: String { "move or rename files and directories" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let operands = args.filter { !ShellArgs.isFlag($0) }
        guard operands.count >= 2 else {
            io.printError("mv: usage: mv SOURCE… DEST")
            return 1
        }
        let destination = operands.last!
        let sources = Array(operands.dropLast())
        let destinationIsDir = engine.fs.isDirectory(destination, relativeTo: engine.cwd)
        var status = 0

        if sources.count > 1 && !destinationIsDir {
            io.printError("mv: target '\(destination)' is not a directory")
            return 1
        }
        for source in sources {
            do {
                if !destinationIsDir && engine.fs.exists(destination, relativeTo: engine.cwd) {
                    try engine.fs.delete(destination, relativeTo: engine.cwd)
                }
                _ = try engine.fs.move(source, to: destination, relativeTo: engine.cwd)
            } catch {
                let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                io.printError("mv: cannot move '\(source)': \(desc)")
                status = 1
            }
        }
        return status
    }
}

struct RmCommand: ShellCommand {
    var name: String { "rm" }
    var aliases: [String] { [] }
    var usage: String { "rm [-r] [-f] FILE…" }
    var help: String { "remove files or directories (-r recursive, -f ignore missing)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let recursive = ShellArgs.containsFlag(args, ["r", "R"])
        let force = ShellArgs.containsFlag(args, ["f"])
        let targets = args.filter { !ShellArgs.isFlag($0) }
        guard !targets.isEmpty else {
            io.printError("rm: missing operand")
            return 1
        }
        var status = 0
        for target in targets {
            do {
                try engine.fs.delete(target, relativeTo: engine.cwd, recursive: recursive)
            } catch {
                if force, case FileSystemError.notFound = (error as? FileSystemError ?? .notFound(target)) {
                    continue
                }
                let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                io.printError("rm: cannot remove '\(target)': \(desc)")
                status = 1
            }
        }
        return status
    }
}

// MARK: find

struct FindCommand: ShellCommand {
    var name: String { "find" }
    var aliases: [String] { [] }
    var usage: String { "find [DIR] [-name PATTERN] [-type f|d]" }
    var help: String { "walk the sandbox tree and print matching paths" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var root = "."
        var namePattern: String?
        var typeFilter: String?

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-name", "-iname":
                index += 1
                guard index < args.count else {
                    io.printError("find: \(arg) requires a pattern")
                    return 2
                }
                namePattern = args[index]
            case "-type":
                index += 1
                guard index < args.count, ["f", "d"].contains(args[index]) else {
                    io.printError("find: -type needs 'f' (file) or 'd' (directory)")
                    return 2
                }
                typeFilter = args[index]
            case let other where ShellArgs.isFlag(other):
                io.printError("find: unsupported flag \(other) (supported: -name, -type)")
                return 2
            default:
                if root == "." || root.isEmpty {
                    root = arg
                } else {
                    io.printError("find: only one starting path is supported ('\(arg)')")
                    return 2
                }
            }
            index += 1
        }

        do {
            let resolvedRoot = try SandboxPath.resolve(root, relativeTo: engine.cwd)
            let rootEntry = try engine.fs.stat(resolvedRoot, relativeTo: "/")

            var emitted = 0
            var reportedTruncation = false
            let prefix = resolvedRoot == "/" ? "" : resolvedRoot

            func displayPath(_ entry: FSEntry) -> String {
                if entry.virtualPath == resolvedRoot { return root == "." ? "." : resolvedRoot }
                return "." + entry.virtualPath.dropFirst(prefix.count)
            }

            func include(_ entry: FSEntry) -> Bool {
                if let typeFilter {
                    if typeFilter == "d" && !entry.isDirectory { return false }
                    if typeFilter == "f" && entry.isDirectory { return false }
                }
                if let namePattern, !shellGlobMatch(namePattern, entry.name) { return false }
                return true
            }

            func walk(_ entries: [FSEntry]) {
                for entry in entries {
                    guard emitted < 5000 else {
                        if !reportedTruncation {
                            io.printError("find: output truncated at 5000 entries")
                            reportedTruncation = true
                        }
                        return
                    }
                    if include(entry) {
                        io.printLine(displayPath(entry))
                        emitted += 1
                    }
                    if entry.isDirectory, let children = try? engine.fs.listEntries(entry.virtualPath, relativeTo: "/", includeHidden: true) {
                        walk(children)
                    }
                }
            }

            walk([rootEntry]) // real find prints the starting point itself
            return 0
        } catch {
            io.printError("find: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
            return 1
        }
    }
}

/// Minimal shell glob: '*' = any run, '?' = one char; everything else literal.
func shellGlobMatch(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern), t = Array(text)

    func matches(_ pi: Int, _ ti: Int) -> Bool {
        if pi == p.count { return ti == t.count }
        if p[pi] == "*" {
            var k = ti
            while k <= t.count {
                if matches(pi + 1, k) { return true }
                k += 1
            }
            return false
        }
        if ti == t.count { return false }
        if p[pi] == "?" || p[pi] == t[ti] { return matches(pi + 1, ti + 1) }
        return false
    }

    return matches(0, 0)
}

// MARK: grep

struct GrepCommand: ShellCommand {
    var name: String { "grep" }
    var aliases: [String] { [] }
    var usage: String { "grep [-i] [-n] [-v] PATTERN [file…]" }
    var help: String { "print matching lines (-i case-insensitive, -n numbers, -v invert)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let ignoreCase = ShellArgs.containsFlag(args, ["i"])
        let numbers = ShellArgs.containsFlag(args, ["n"])
        let invert = ShellArgs.containsFlag(args, ["v"])

        let operands = args.filter { !ShellArgs.isFlag($0) }
        guard let pattern = operands.first, !pattern.isEmpty else {
            io.printError("grep: usage: grep [-i] [-n] [-v] PATTERN [file…]")
            return 2
        }
        let files = Array(operands.dropFirst())

        var status = 0
        var foundAny = false
        let needle = ignoreCase ? pattern.lowercased() : pattern

        func scan(_ text: String, source: String?) {
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if text.hasSuffix("\n"), lines.last == "" {
                lines.removeLast() // a trailing newline does not add an output line
            }
            for (offset, line) in lines.enumerated() {
                var haystack = line
                if ignoreCase { haystack = haystack.lowercased() }
                let match = haystack.contains(needle)
                if match == invert { continue }
                foundAny = true
                var out = source.map { "\($0):" } ?? ""
                if numbers { out += "\(offset + 1):" }
                out += line
                io.printLine(out)
            }
        }

        if files.isEmpty {
            scan(io.stdin, source: nil)
        } else {
            for file in files {
                do {
                    let (text, truncated) = try engine.fs.readText(file, relativeTo: engine.cwd)
                    if truncated {
                        io.printError("grep: \(file): warning — preview truncated at 8 MB")
                    }
                    scan(text, source: files.count > 1 ? file : nil)
                } catch {
                    let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                    io.printError("grep: \(file): \(desc)")
                    status = 2
                }
            }
        }

        if !foundAny && status == 0 { return 1 }
        return status
    }
}

// MARK: head / tail

struct HeadCommand: ShellCommand {
    var name: String { "head" }
    var aliases: [String] { [] }
    var usage: String { "head [-n COUNT] [file]" }
    var help: String { "print the first COUNT lines (default 10)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var count = 10
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-n", index + 1 < args.count, let parsed = Int(args[index + 1]) {
                count = parsed
                index += 1
            } else if arg.hasPrefix("-n"), let parsed = Int(arg.dropFirst(2)) {
                count = parsed
            } else if arg == "-n" {
                io.printError("head: -n needs a number")
                return 2
            } else if ShellArgs.isFlag(arg) {
                io.printError("head: unsupported flag \(arg) (supported: -n COUNT)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }
        guard count > 0, count <= 1_000_000 else {
            io.printError("head: invalid COUNT")
            return 2
        }

        let text: String
        if let file = operands.first {
            do { text = try engine.fs.readText(file, relativeTo: engine.cwd).text }
            catch {
                io.printError("head: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
                return 1
            }
        } else {
            text = io.stdin
        }

        if count == 0 { return 0 }
        var result = ""
        var newlines = 0
        for char in text {
            if newlines >= count { break }
            result.append(char)
            if char == "\n" { newlines += 1 }
        }
        io.writeOutput(result)
        return 0
    }
}

struct TailCommand: ShellCommand {
    var name: String { "tail" }
    var aliases: [String] { [] }
    var usage: String { "tail [-n COUNT] [file]" }
    var help: String { "print the last COUNT lines (default 10)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var count = 10
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-n", index + 1 < args.count, let parsed = Int(args[index + 1]) {
                count = parsed
                index += 1
            } else if arg.hasPrefix("-n"), let parsed = Int(arg.dropFirst(2)) {
                count = parsed
            } else if arg == "-n" {
                io.printError("tail: -n needs a number")
                return 2
            } else if ShellArgs.isFlag(arg) {
                io.printError("tail: unsupported flag \(arg) (supported: -n COUNT)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }
        guard count > 0, count <= 1_000_000 else {
            io.printError("tail: invalid COUNT")
            return 2
        }

        guard let file = operands.first else {
            guard !io.stdin.isEmpty else { return 0 }
            emit(String(io.stdin), count: count, io: io)
            return 0
        }
        do {
            emit(try engine.fs.readText(file, relativeTo: engine.cwd).text, count: count, io: io)
            return 0
        } catch {
            io.printError("tail: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
            return 1
        }
    }

    private func emit(_ text: String, count: Int, io: CommandIO) {
        let hadTrailingNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, lines.last == "" { lines.removeLast() }
        guard count > 0 else { return }
        let start = max(0, lines.count - count)
        var out = lines[start...].joined(separator: "\n")
        if hadTrailingNewline { out += "\n" }
        io.writeOutput(out)
    }
}

// MARK: wc

struct WcCommand: ShellCommand {
    var name: String { "wc" }
    var aliases: [String] { [] }
    var usage: String { "wc [-l | -w | -c] [file…]" }
    var help: String { "count lines, words, and bytes (-l lines, -w words, -c bytes)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var wanted: [Character] = ["l", "w", "c"]
        var masked = false
        for flag in ["l", "w", "c"] where ShellArgs.containsFlag(args, [Character(flag)]) {
            if !masked { wanted = []; masked = true }
            wanted.append(Character(flag))
        }
        let files = args.filter { !ShellArgs.isFlag($0) }

        func counts(for text: String) -> String {
            let lineCount = text.filter { $0 == "\n" }.count
            let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
            let byteCount = text.utf8.count
            var columns: [String] = []
            for kind in wanted {
                switch kind {
                case "l": columns.append(LsCommand.rightAligned(String(lineCount), 7))
                case "w": columns.append(LsCommand.rightAligned(String(wordCount), 7))
                default: columns.append(LsCommand.rightAligned(String(byteCount), 7))
                }
            }
            return columns.joined()
        }

        var status = 0
        if files.isEmpty {
            io.printLine(counts(for: io.stdin))
            return 0
        }
        for file in files {
            do {
                let (text, truncated) = try engine.fs.readText(file, relativeTo: engine.cwd)
                if truncated {
                    io.printError("wc: \(file): warning — preview truncated at 8 MB")
                }
                io.printLine(counts(for: text) + " \(file)")
            } catch {
                io.printError("wc: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
                status = 1
            }
        }
        return status
    }
}

// MARK: chmod (numeric only)

struct ChmodCommand: ShellCommand {
    var name: String { "chmod" }
    var aliases: [String] { [] }
    var usage: String { "chmod MODE FILE… (numeric modes only, e.g. 644)" }
    var help: String { "change file permission bits (numeric modes like 644, 755)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let operands = args.filter { !ShellArgs.isFlag($0) }
        guard operands.count >= 2 else {
            io.printError("chmod: usage: \(usage)")
            return 1
        }
        let modeText = operands[0]
        let targets = Array(operands.dropFirst())

        if let plus = modeText.first, plus == "+" || plus == "-" {
            io.printError("chmod: symbolic modes (\(plus)x) are not supported here — use numeric modes, e.g. chmod 755 \(targets[0])")
            return 2
        }
        guard modeText.count >= 2 && modeText.count <= 4,
              modeText.allSatisfy({ $0.isNumber }),
              let posix = Int(modeText, radix: 8) else {
            io.printError("chmod: invalid MODE '\(modeText)' — expect digits only, e.g. 644 or 755")
            return 2
        }

        var status = 0
        for target in targets {
            do {
                try engine.fs.setPermissions(target, relativeTo: engine.cwd, posix: posix)
            } catch {
                let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                io.printError("chmod: cannot chmod '\(target)': \(desc)")
                status = 1
            }
        }
        return status
    }
}
