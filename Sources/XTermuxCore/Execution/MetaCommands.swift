// MetaCommands.swift
// XTermux — environment, history, identity, and text-processing builtins.
//
// All commands execute in-process inside the iOS app sandbox. Nothing here
// spawns subprocesses (iOS does not allow fork/exec for App Store apps), and
// nothing here requires or elevates privileges.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Identifying strings shared across the shell and UI.
public enum ShellInfo {
    public static let appName = "XTermux"
    public static let appVersion = "1.0.0"
    public static let shellName = "xsh"
    public static let sandboxUser = "xtermux"
    /// The person behind this build, shown honestly in the UI.
    public static let developer = "razer0x1 (Bhargav Haldipur)"
    /// Honest notice: the design borrows ideas from Termux but has no
    /// affiliation with the Termux project or its deliverables.
    public static let inspirationNotice =
        "Terminal design inspired by Termux — not affiliated with the Termux project."
}


// MARK: help

struct HelpCommand: ShellCommand {
    var name: String { "help" }
    var aliases: [String] { ["?"] }
    var usage: String { "help [command]" }
    var help: String { "list builtin commands, or show details for one command" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        if let topic = args.first(where: { !ShellArgs.isFlag($0) }),
           let cmd = engine.registry.lookup(topic) {
            io.printLine("\(cmd.name) — \(cmd.help)")
            io.printLine("usage: \(cmd.usage)")
            if let module = SandboxModuleCatalog.module(containingCommand: cmd.name),
               !PkgDB.installedModules(fs: engine.fs).contains(module.name) {
                io.printLine("not installed — run: pkg install \(module.name)")
            }
            return 0
        }
        io.printLine("\(ShellInfo.appName) \(ShellInfo.appVersion) — local sandbox shell")
        io.printLine("Commands below run inside this app's iOS sandbox: no fork/exec,")
        io.printLine("no subprocesses, no root. iOS itself stays in full control.")
        io.printLine("")
        io.printLine("Builtins (module commands stay gated until `pkg install`):")
        let installed = PkgDB.installedModules(fs: engine.fs)
        for cmd in engine.registry.allCommands() {
            var line = "  \(cmd.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(cmd.help)"
            if let module = SandboxModuleCatalog.module(containingCommand: cmd.name),
               !installed.contains(module.name) {
                line += "  · not installed — pkg install \(module.name)"
            }
            io.printLine(line)
        }
        io.printLine("")
        io.printLine("Supported: pipes (a | b), redirects (> >> <), $VAR/${VAR} expansion,")
        io.printLine("$? exit code, Tab completion, ↑/↓ history, Ctrl-R search, Ctrl+C/L/U/W/D.")
        io.printLine("For full Linux: open an SSH session (Terminal → + → SSH).")
        return 0
    }
}

// MARK: pwd

struct PwdCommand: ShellCommand {
    var name: String { "pwd" }
    var aliases: [String] { [] }
    var usage: String { "pwd" }
    var help: String { "print the working directory (virtual sandbox path)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        io.printLine(engine.cwd)
        return 0
    }
}

// MARK: echo

struct EchoCommand: ShellCommand {
    var name: String { "echo" }
    var aliases: [String] { [] }
    var usage: String { "echo [-n] text…" }
    var help: String { "write text ($vars are expanded by the shell; -n skips newline)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var words = args
        var newline = true
        if words.first == "-n" {
            newline = false
            words.removeFirst()
        }
        io.writeOutput(words.joined(separator: " "))
        if newline { io.writeOutput("\n") }
        return 0
    }
}

// MARK: date

struct DateCommand: ShellCommand {
    var name: String { "date" }
    var aliases: [String] { [] }
    var usage: String { "date [-u]" }
    var help: String { "print the device date/time (-u for UTC)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let useUTC = ShellArgs.containsFlag(args, ["u"])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = useUTC ? TimeZone(secondsFromGMT: 0) : TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        io.printLine("\(formatter.string(from: Date())) (\(useUTC ? "UTC" : "device time"))")
        return 0
    }
}

// MARK: env / printenv

struct EnvCommand: ShellCommand {
    var name: String { "env" }
    var aliases: [String] { [] }
    var usage: String { "env" }
    var help: String { "print the shell environment" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var keys = Set(engine.environment.keys)
        keys.insert("PWD")
        for key in keys.sorted() {
            io.printLine("\(key)=\(engine.value(for: key) ?? "")")
        }
        return 0
    }
}

struct PrintEnvCommand: ShellCommand {
    var name: String { "printenv" }
    var aliases: [String] { [] }
    var usage: String { "printenv [NAME]" }
    var help: String { "print one variable's value, or the whole environment" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard let name = args.first(where: { !ShellArgs.isFlag($0) }) else {
            return EnvCommand().run(engine, args: [], io: io)
        }
        guard let value = engine.value(for: name) else {
            io.printError("printenv: \(name): not set")
            return 1
        }
        io.printLine(value)
        return 0
    }
}

// MARK: export / unset

struct ExportCommand: ShellCommand {
    var name: String { "export" }
    var aliases: [String] { [] }
    var usage: String { "export NAME=value" }
    var help: String { "set an environment variable for this session" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard let assignment = args.first(where: { !ShellArgs.isFlag($0) }),
              assignment.contains("=") else {
            io.printError("export: usage: export NAME=value")
            return 2
        }
        let parts = assignment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let value = parts.count > 1 ? String(parts[1]) : ""
        guard Self.isValidName(name) else {
            io.printError("export: not a valid identifier: \(name)")
            return 2
        }
        engine.setEnv(name, value)
        return 0
    }

    static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

struct UnsetCommand: ShellCommand {
    var name: String { "unset" }
    var aliases: [String] { [] }
    var usage: String { "unset NAME" }
    var help: String { "remove a session environment variable" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard let name = args.first(where: { !ShellArgs.isFlag($0) }) else {
            io.printError("unset: usage: unset NAME")
            return 2
        }
        engine.environment.removeValue(forKey: name)
        return 0
    }
}

// MARK: clear

struct ClearCommand: ShellCommand {
    var name: String { "clear" }
    var aliases: [String] { [] }
    var usage: String { "clear" }
    var help: String { "clear the terminal screen" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        io.writeOutput(ANSI.clearScreen)
        return 0
    }
}

// MARK: history

struct HistoryCommand: ShellCommand {
    var name: String { "history" }
    var aliases: [String] { ["hist"] }
    var usage: String { "history [search]" }
    var help: String { "print persistent command history (optionally filtered)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let filter = args.first(where: { !ShellArgs.isFlag($0) })
        let entries = engine.history.entries
        let width = max(1, String(entries.count).count)
        for entry in entries {
            if let filter, !entry.command.contains(filter) { continue }
            let number = String(entry.id).padding(toLength: width + 2, withPad: " ", startingAt: 0)
            io.printLine("\(number)  \(entry.command)")
        }
        return 0
    }
}

// MARK: which

struct WhichCommand: ShellCommand {
    var name: String { "which" }
    var aliases: [String] { [] }
    var usage: String { "which COMMAND [COMMAND…]" }
    var help: String { "locate a builtin command by name" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var missing = false
        for target in args {
            if ShellArgs.isFlag(target) { continue }
            if engine.registry.lookup(target) != nil {
                io.printLine("/bin/\(target)")
            } else {
                io.printError("which: no \(target) in (/bin)")
                missing = true
            }
        }
        return missing ? 1 : 0
    }
}

// MARK: identity & host

struct WhoAmICommand: ShellCommand {
    var name: String { "whoami" }
    var aliases: [String] { [] }
    var usage: String { "whoami" }
    var help: String { "print the sandbox user name" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        io.printLine(ShellInfo.sandboxUser)
        return 0
    }
}

struct UnameCommand: ShellCommand {
    var name: String { "uname" }
    var aliases: [String] { [] }
    var usage: String { "uname [-a]" }
    var help: String { "print a short, honest description of this environment" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let host = ProcessInfo.processInfo.hostName
        io.printLine(
            "\(ShellInfo.shellName) 1.0 \(host) — \(ShellInfo.appName) userspace shell on iOS. "
                + "The device runs Darwin/XNU; this app never modifies the kernel, "
                + "never uses root, and only executes its own in-process commands."
        )
        return 0
    }
}

// MARK: kernel — honest XNU information access

/// `kern` — kernel information, honestly. An iOS app can READ a handful of
/// kernel facts through sysctl(2) but can never touch the kernel itself, so
/// this command prints real values where the OS permits and clearly says
/// "unavailable" where it does not. It also carries the XNU explainer, an
/// iOS-vs-Android comparison, and exact steps for exploring Apple's
/// open-source XNU tree from a computer.
struct KernCommand: ShellCommand {
    var name: String { "kern" }
    var aliases: [String] { ["kernel"] }
    var usage: String { "kern [info|uname|ostype|osrelease|version|arch|compare|explore]" }
    var help: String {
        "XNU kernel info: read-only sysctl facts where iOS allows them, plus "
            + "an explainer, an iOS-vs-Android comparison, and steps to explore "
            + "the open-source kernel source"
    }

    private let topics = "info uname ostype osrelease version arch compare explore"

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        switch args.first(where: { !ShellArgs.isFlag($0) }) ?? "info" {
        case "info", "xnu":
            printInfo(io: io)
            return 0
        case "uname":
            return printUname(io: io)
        case "compare":
            printCompare(io: io)
            return 0
        case "explore", "steps", "source":
            printExplore(io: io)
            return 0
        case "help", "--help", "-h":
            io.printLine("usage: \(usage)")
            io.printLine(help)
            io.printLine("topics: \(topics)")
            return 0
        case "ostype":
            return sysctlLine("kern.ostype", io: io)
        case "osrelease":
            return sysctlLine("kern.osrelease", io: io)
        case "version", "osversion":
            return sysctlLine("kern.version", io: io)
        case "arch", "machine":
            return sysctlLine("hw.machine", io: io)
        case "osproductversion":
            return sysctlLine("kern.osproductversion", io: io)
        case let topic:
            io.printError("kern: unknown topic '\(topic)'")
            io.printLine("topics: \(topics)")
            return 2
        }
    }

    /// Reads one NUL-terminated string value from sysctl(2). Returns nil when
    /// the OS refuses — or when there is no sysctl (the Linux test host) — so
    /// the caller prints honestly instead of inventing a value.
    private static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size > 0 else { return nil }
        return String(decoding: value.prefix(size - 1), as: UTF8.self)
        #else
        _ = name
        return nil
        #endif
    }

    private func sysctlLine(_ name: String, io: CommandIO) -> Int {
        if let value = Self.sysctlString(name) {
            io.printLine(value)
            return 0
        }
        io.printLine("unavailable: '\(name)' is not readable here")
        io.printLine("(on an iPhone or iPad without jailbreak, iOS keeps most kernel tables closed)")
        return 1
    }

    private func printInfo(io: CommandIO) {
        io.printLine("XNU — the kernel inside iOS, macOS, tvOS, watchOS and visionOS")
        io.printLine("")
        io.printLine("  name        XNU (\"X is Not Unix\")")
        io.printLine("  type        hybrid kernel — Mach microkernel + BSD Unix layer")
        io.printLine("  components  I/O Kit and Apple-specific drivers live inside the kernel")
        io.printLine("  languages   primarily C and C++, with some assembly")
        io.printLine("  open source parts are published by Apple")
        io.printLine("              (github.com/apple-oss-distributions/xnu)")
        io.printLine("")
        io.printLine("This app can READ a few kernel facts via sysctl(2); it can never modify")
        io.printLine("XNU, load kernel code, or claim root. Everything this command shows is")
        io.printLine("information, not access.")
        io.printLine("Real facts on this device: try 'kern ostype', 'kern osrelease', 'kern uname'.")
    }

    private func printUname(io: CommandIO) -> Int {
        let ostype = Self.sysctlString("kern.ostype") ?? "?"
        let release = Self.sysctlString("kern.osrelease") ?? "?"
        let version = Self.sysctlString("kern.version") ?? "?"
        let machine = Self.sysctlString("hw.machine") ?? "?"
        let host = ProcessInfo.processInfo.hostName
        io.printLine("\(ostype) \(host) \(release) \(version) \(machine)")
        io.printLine("read from sysctl(2); view-only — \(ShellInfo.appName) never touches the kernel")
        return 0
    }

    private func printCompare(io: CommandIO) {
        io.printLine("XNU vs Linux — the two kernels behind iOS and Android")
        io.printLine("")
        io.printLine("  feature          iOS                            Android")
        io.printLine("  kernel           XNU                            Linux")
        io.printLine("  kernel type      hybrid                         monolithic with modular support")
        io.printLine("  base system      Darwin                         Linux")
        io.printLine("  drivers          I/O Kit and Apple-specific     Linux kernel drivers")
        io.printLine("                   frameworks")
        io.printLine("  custom kernels   highly restricted              possible on supported devices")
        io.printLine("")
        io.printLine("Neither table is this app's doing: the OS limits what any app can reach.")
    }

    private func printExplore(io: CommandIO) {
        io.printLine("Exploring the open-source XNU kernel — exact steps")
        io.printLine("")
        io.printLine("1. The XNU source is public. On a computer (Windows: WSL, macOS Terminal,")
        io.printLine("   or a Linux shell):")
        io.printLine("")
        io.printLine("     git clone https://github.com/apple-oss-distributions/xnu.git")
        io.printLine("     cd xnu")
        io.printLine("     ls")
        io.printLine("")
        io.printLine("2. Good reading order:")
        io.printLine("   bsd/kern  — system calls and process semantics")
        io.printLine("   osfmk     — the Mach microkernel half")
        io.printLine("   iokit     — I/O Kit drivers and driver families")
        io.printLine("")
        io.printLine("3. Cloning from a Windows PC (this project's own build path uses WSL) reads")
        io.printLine("   XNU's source on YOUR computer — it never reaches the kernel inside")
        io.printLine("   your iPhone.")
        io.printLine("")
        io.printLine("4. On an iPhone without jailbreak: terminal apps can read a handful of live")
        io.printLine("   kernel facts (try 'kern ostype' here) but cannot open kernel files or")
        io.printLine("   kernel memory. A jailbreak changes what a device allows; it never changes")
        io.printLine("   what this sandboxed app does.")
        io.printLine("")
        io.printLine("Official repository: https://github.com/apple-oss-distributions/xnu")
    }
}

struct IdCommand: ShellCommand {
    var name: String { "id" }
    var aliases: [String] { [] }
    var usage: String { "id" }
    var help: String { "print the sandbox identity" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        io.printLine("uid=1000(\(ShellInfo.sandboxUser)) gid=1000(\(ShellInfo.sandboxUser)) — enforced by the app's sandbox path logic; the real UID is managed by iOS")
        return 0
    }
}

// MARK: true / false / exit

struct TrueCommand: ShellCommand {
    var name: String { "true" }
    var aliases: [String] { [] }
    var usage: String { "true" }
    var help: String { "exit successfully (status 0)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int { 0 }
}

struct FalseCommand: ShellCommand {
    var name: String { "false" }
    var aliases: [String] { [] }
    var usage: String { "false" }
    var help: String { "exit with status 1" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int { 1 }
}

struct ExitCommand: ShellCommand {
    var name: String { "exit" }
    var aliases: [String] { ["logout", "q"] }
    var usage: String { "exit [code]" }
    var help: String { "end this shell session" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        engine.sessionWantsExit = true
        if let arg = args.first {
            guard let parsed = Int(arg) else {
                io.printError("exit: numeric argument required: \(arg)")
                return 2
            }
            return parsed & 0xFF
        }
        return engine.lastExitCode
    }
}

// MARK: text processing (sort / cut / tr)

struct SortCommand: ShellCommand {
    var name: String { "sort" }
    var aliases: [String] { [] }
    var usage: String { "sort [-r] [-u] [-n] [file…]" }
    var help: String { "sort lines of stdin or files (-r reverse, -u unique, -n numeric)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let reverse = ShellArgs.containsFlag(args, ["r"])
        let unique = ShellArgs.containsFlag(args, ["u"])
        let numeric = ShellArgs.containsFlag(args, ["n"])

        guard let text = InputText.read(engine: engine, args: args, io: io) else { return 1 }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }

        if numeric {
            lines.sort { a, b in
                switch (Double(a), Double(b)) {
                case let (av?, bv?) where av != bv: return av < bv
                default: return a < b
                }
            }
        } else {
            lines.sort { $0 < $1 }
        }
        if reverse { lines.reverse() }
        if unique {
            var result: [String] = []
            for line in lines where result.last != line { result.append(line) }
            lines = result
        }
        io.writeOutput(lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n")
        return 0
    }
}

struct CutCommand: ShellCommand {
    var name: String { "cut" }
    var aliases: [String] { [] }
    var usage: String { "cut -f LIST [-d CHAR] [file…]  |  cut -c LIST [file…]" }
    var help: String { "select fields (-f, delimiter -d) or characters (-c) from input lines" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var delimiter: Character = "\t"
        var fieldSpec: String?
        var charSpec: String?
        var plainArgs: [String] = []

        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-d", index + 1 < args.count {
                index += 1
                delimiter = args[index].first ?? "\t"
            } else if arg == "-f", index + 1 < args.count {
                index += 1
                fieldSpec = args[index]
            } else if arg.hasPrefix("-d"), arg.count > 2 {
                // attached form: -d:
                delimiter = Array(arg)[2]
            } else if arg.hasPrefix("-f"), arg.count > 2 {
                fieldSpec = String(arg.dropFirst(2))
            } else if arg == "-c", index + 1 < args.count {
                index += 1
                charSpec = args[index]
            } else if arg.hasPrefix("-c"), arg.count > 2 {
                charSpec = String(arg.dropFirst(2))
            } else if ShellArgs.isFlag(arg) {
                io.printError("cut: unsupported flag \(arg)")
                return 2
            } else {
                plainArgs.append(arg)
            }
            index += 1
        }

        if (fieldSpec == nil) == (charSpec == nil) {
            io.printError("cut: give exactly one of -f LIST or -c LIST")
            return 2
        }
        guard let spec = fieldSpec ?? charSpec,
              let ranges = Self.parseSelection(spec) else {
            io.printError("cut: invalid LIST (use N, N-, -M, N-M separated by commas)")
            return 2
        }

        guard let text = InputText.read(engine: engine, args: plainArgs, io: io) else { return 1 }
        guard !text.isEmpty else { return 0 }

        var bodyLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n"), bodyLines.last == "" {
            bodyLines.removeLast() // a trailing newline does not add an output line
        }

        var out = ""
        for line in bodyLines {
            if charSpec != nil {
                let chars = Array(line)
                out += Self.select(in: ranges, of: chars.count)
                    .map { $0 - 1 < chars.count ? String(chars[$0 - 1]) : "" }
                    .joined() + "\n"
            } else {
                let parts = line.split(separator: delimiter, omittingEmptySubsequences: false).map(String.init)
                guard parts.count > 1 else {
                    out += line + "\n"
                    continue
                }
                out += Self.select(in: ranges, of: parts.count)
                    .map { $0 - 1 < parts.count ? parts[$0 - 1] : "" }
                    .joined(separator: String(delimiter)) + "\n"
            }
        }
        io.writeOutput(out)
        return 0
    }

    /// Parses "3", "1-3", "5-,2", … into inclusive 1-based ranges.
    static func parseSelection(_ raw: String) -> [ClosedRange<Int>]? {
        var ranges: [ClosedRange<Int>] = []
        for token in raw.split(separator: ",") {
            let token = String(token).trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return nil }
            let parts = token.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if parts.count == 1 {
                guard let n = Int(token), n > 0 else { return nil }
                ranges.append(n...n)
            } else if parts.count == 2 {
                guard let start = parts[0].isEmpty ? 1 : Int(parts[0]), start > 0 else { return nil }
                let end = parts[1].isEmpty ? Int.max : Int(parts[1])
                guard let end, end >= start else { return nil }
                ranges.append(start...end)
            } else {
                return nil
            }
        }
        return ranges.isEmpty ? nil : ranges
    }

    static func select(in ranges: [ClosedRange<Int>], of count: Int) -> [Int] {
        var picked: [Int] = []
        var seen = Set<Int>()
        for range in ranges {
            let upper = min(range.upperBound, count)
            var i = range.lowerBound
            while i <= upper {
                if seen.insert(i).inserted { picked.append(i) }
                i += 1
            }
        }
        return picked
    }
}

struct TrCommand: ShellCommand {
    var name: String { "tr" }
    var aliases: [String] { [] }
    var usage: String { "tr [-d] SET1 [SET2]" }
    var help: String { "translate characters (a-z ranges; \\n and \\t escapes), or delete with -d" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        let deleteFlag = ShellArgs.containsFlag(args, ["d"])
        let plainArgs = args.filter { !ShellArgs.isFlag($0) }
        guard !plainArgs.isEmpty else {
            io.printError("tr: missing operand")
            return 2
        }

        guard let text = InputText.read(engine: engine, args: [], io: io) else { return 1 }

        let set1 = Self.expandSet(plainArgs[0])

        if deleteFlag {
            let removed = Set(set1)
            io.writeOutput(String(text.filter { !removed.contains($0) }))
            return 0
        }

        guard plainArgs.count >= 2 else {
            io.printError("tr: missing operand after SET1")
            return 2
        }
        let set2 = Self.expandSet(plainArgs[1])
        guard !set2.isEmpty else {
            io.printError("tr: translation set SET2 is empty")
            return 2
        }

        var map: [Character: Character] = [:]
        for (i, c) in set1.enumerated() where map[c] == nil {
            map[c] = set2[min(i, set2.count - 1)] // GNU behavior: repeat last char of SET2
        }

        io.writeOutput(String(text.map { map[$0] ?? $0 }))
        return 0
    }

    /// Expands escape sequences (\\n, \\t) and ranges (a-z, 0-9).
    static func expandSet(_ raw: String) -> [Character] {
        var chars: [Character] = []
        let src = Array(raw)
        var i = 0
        while i < src.count {
            if src[i] == "\\", i + 1 < src.count {
                let next = src[i + 1]
                chars.append(next == "n" ? "\n" : next == "t" ? "\t" : next)
                i += 2
                continue
            }
            if i + 2 < src.count, src[i + 1] == "-",
               let lo = src[i].unicodeScalars.first, let hi = src[i + 2].unicodeScalars.first,
               src[i].unicodeScalars.count == 1, src[i + 2].unicodeScalars.count == 1,
               lo.value < hi.value {
                var value = lo.value
                while value <= hi.value, let scalar = UnicodeScalar(value) {
                    chars.append(Character(scalar))
                    value += 1
                }
                i += 3
                continue
            }
            chars.append(src[i])
            i += 1
        }
        return chars
    }
}

// MARK: shared input source for text commands

enum InputText {
    /// Reads the files listed as non-flag args, or falls back to `io.stdin`.
    /// Returns nil (after printing an error) when a file cannot be read.
    static func read(engine: ShellEngine, args: [String], io: CommandIO) -> String? {
        let files = args.filter { !ShellArgs.isFlag($0) }
        if files.isEmpty { return io.stdin }
        var text = ""
        for file in files {
            do {
                let (content, truncated) = try engine.fs.readText(file, relativeTo: engine.cwd)
                if truncated {
                    io.printError("warning: \(file): preview truncated at 8 MB")
                }
                text += content
            } catch {
                let desc = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                io.printError("cannot read '\(file)': \(desc)")
                return nil
            }
        }
        return text
    }
}
