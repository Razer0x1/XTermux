// ShellEngine.swift
// XTermux — the local shell execution engine (pure Swift, platform independent).
//
// Responsibilities:
//   - environment & working-directory state
//   - $VAR / ${VAR} / $? expansion (bash-style, suppressed inside single quotes)
//   - pipeline execution (`a | b`) with per-stage redirection (>, >>, <)
//   - the command registry
//
// Commands themselves are plain objects in MetaCommands.swift / FileCommands.swift.

import Foundation

// MARK: - ANSI helpers (used for honest, real terminal output)

public enum ANSI {
    public static let reset = "\u{1b}[0m"
    public static let clearScreen = "\u{1b}[2J\u{1b}[H"
    public static let clearLineRight = "\u{1b}[0K"
    public static func bold(_ s: String) -> String { "\u{1b}[1m" + s + reset }
    public static func red(_ s: String) -> String { "\u{1b}[31m" + s + reset }
    public static func green(_ s: String) -> String { "\u{1b}[1;32m" + s + reset }
    public static func cyan(_ s: String) -> String { "\u{1b}[1;36m" + s + reset }
    public static func blue(_ s: String) -> String { "\u{1b}[1;34m" + s + reset }
    public static func moveBack(_ n: Int) -> String { "\u{1b}[\(n)D" }
    public static func moveRight(_ n: Int) -> String { "\u{1b}[\(n)C" }
}

// MARK: - Command I/O

/// Per-command invocation I/O. `stdin` carries the output of the previous
/// pipeline stage (or a `<` redirect); `out`/`err` accumulate this stage's
/// output for both pipeline forwarding and terminal rendering.
public final class CommandIO {
    public var stdin: String
    public var out: String = ""
    public var err: String = ""

    public init(stdin: String = "") {
        self.stdin = stdin
    }

    public func writeOutput(_ text: String) { out += text }
    public func printLine(_ line: String) { out += line + "\n" }
    public func writeError(_ text: String) { err += text }
    public func printError(_ line: String) { err += line + "\n" }
}

// MARK: - Command protocol

public protocol ShellCommand {
    var name: String { get }
    var aliases: [String] { get }
    var usage: String { get }
    var help: String { get }

    /// Executes the command. Return value is the process-style exit code.
    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int
}

// MARK: - Arg helpers

public enum ShellArgs {
    /// "-a", "-l", "-la" style flags.
    public static func isFlag(_ arg: String) -> Bool {
        arg.count >= 2 && arg.hasPrefix("-")
    }

    public static func flagCharacters(_ arg: String) -> Set<Character> {
        isFlag(arg) ? Set(arg.dropFirst()) : []
    }

    public static func containsFlag(_ args: [String], _ chars: Set<Character>) -> Bool {
        for arg in args where isFlag(arg) {
            if !ShellArgs.flagCharacters(arg).isDisjoint(with: chars) { return true }
        }
        return false
    }

    /// First non-flag token (used by grep/head/tail/wc to locate the pattern).
    public static func firstOperand(_ args: [String]) -> String? {
        args.first { !isFlag($0) }
    }
}

// MARK: - Registry

public final class CommandRegistry: @unchecked Sendable {
    private var commands: [String: ShellCommand] = [:]
    private var aliasMap: [String: String] = [:]

    /// Commands that are known to exist in *real* Unix environments but are NOT
    /// implemented here, plus an honest pointer to what the user can do instead.
    public static let suggestions: [String: String] = [
        "git": "run git on your own server through an SSH session (Terminal → + → SSH)",
        "python": "Python needs a Linux VM (not integrated) or your SSH server",
        "python3": "Python needs a Linux VM (not integrated) or your SSH server",
        "pip": "Python tooling needs a Linux VM (not integrated) or your SSH server",
        "node": "Node.js needs a Linux VM (not integrated) or your SSH server",
        "npm": "JavaScript tooling needs a Linux VM or your SSH server",
        "gcc": "C toolchains need a Linux VM or your SSH server",
        "clang": "C toolchains need a Linux VM or your SSH server",
        "make": "Build systems need a Linux VM or your SSH server",
        "bash": "local sessions use the builtin XTerm shell",
        "sh": "local sessions use the builtin XTerm shell",
        "zsh": "local sessions use the builtin XTerm shell",
        "fish": "local sessions use the builtin XTerm shell",
        "apt": "package managers only run in a real Linux guest/server",
        "apt-get": "package managers only run in a real Linux guest/server",
        "apk": "package managers only run in a real Linux guest/server",
        "dnf": "package managers only run in a real Linux guest/server",
        "curl": "network tools can run on your SSH server",
        "wget": "network tools can run on your SSH server",
        "ssh": "open SSH sessions from the terminal tab bar (Terminal → + → SSH)",
        "scp": "open SSH sessions from the terminal tab bar (Terminal → + → SSH)",
        "sftp": "open SSH sessions from the terminal tab bar (Terminal → + → SSH)",
        "vim": "the Files tab includes a full text editor",
        "nano": "the Files tab includes a full text editor",
        "emacs": "the Files tab includes a full text editor",
        "sudo": "XTermux never needs or provides elevated privileges",
        "su": "XTermux never needs or provides elevated privileges",
        "kill": "no subprocesses exist in the sandbox, so there is nothing to kill",
        "ps": "no subprocesses exist in the sandbox",
        "top": "no subprocesses exist in the sandbox",
        "open": "iOS sandboxed apps cannot launch arbitrary system apps",
        "ln": "symbolic links are not supported inside the sandbox",
    ]

    public init() {}

    public func register(_ command: ShellCommand) {
        commands[command.name] = command
        for alias in command.aliases { aliasMap[alias] = command.name }
    }

    public func registerAll() {
        register(HelpCommand())
        register(PwdCommand())
        register(CdCommand())
        register(LsCommand())
        register(CatCommand())
        register(EchoCommand())
        register(MkdirCommand())
        register(TouchCommand())
        register(CpCommand())
        register(MvCommand())
        register(RmCommand())
        register(FindCommand())
        register(GrepCommand())
        register(HeadCommand())
        register(TailCommand())
        register(WcCommand())
        register(SortCommand())
        register(CutCommand())
        register(TrCommand())
        register(ChmodCommand())
        register(WhichCommand())
        register(PrintEnvCommand())
        register(DateCommand())
        register(EnvCommand())
        register(ExportCommand())
        register(UnsetCommand())
        register(ClearCommand())
        register(HistoryCommand())
        register(WhoAmICommand())
        register(UnameCommand())
        register(KernCommand())
        register(IdCommand())
        register(TrueCommand())
        register(FalseCommand())
        register(ExitCommand())
        // Module-managed commands (gated by pkg state — see ModulePackages.swift).
        register(PkgCommand())
        register(SedCommand())
        register(AwkCommand())
        register(DiffCommand())
        register(StatCommand())
        register(DuCommand())
        register(DfCommand())
        register(TreeCommand())
        register(BasenameCommand())
        register(DirnameCommand())
        register(SeqCommand())
        register(SleepCommand())
        register(PrintfCommand())
        register(AliasCommand())
        register(UnaliasCommand())
        register(XargsCommand())
        register(ExprCommand())
        register(TacCommand())
        register(RevCommand())
        register(UniqCommand())
        register(NlCommand())
        register(TestCommand())
    }

    public func lookup(_ name: String) -> ShellCommand? {
        commands[aliasMap[name] ?? name]
    }

    public func allCommands() -> [ShellCommand] {
        commands.values.sorted { $0.name < $1.name }
    }
}

// MARK: - Engine

public struct ShellExecutionResult: Sendable {
    public let exitCode: Int
    /// What should appear on screen for this line (stderr + un-redirected stdout, ANSI included).
    public let visibleOutput: String
    public let wantsSessionEnd: Bool
}

/// Pe-forms the actual execution of command lines inside the sandbox.
///
/// Concurrency note: a single engine belongs to one shell session; the session
/// serializes all access on its own queue, so plain mutable state is safe.
public final class ShellEngine: @unchecked Sendable {
    public let fs: FileSystemService
    public let history: HistoryStore
    public let registry: CommandRegistry

    /// Current working directory (absolute, virtual).
    public var cwd: String = SandboxPath.homePrefix
    /// Terminal width hint, updated by the view layer on resize.
    public var terminalWidth: Int = 80

    public var lastExitCode: Int = 0
    /// Set by `exit`/`logout`; executeLine surfaces it as `wantsSessionEnd`
    /// so the session layer can close the view tab cleanly.
    public var sessionWantsExit = false
    public var environment: [String: String]
    /// Session shell aliases (`alias`/`unalias`); expanded before scanning.
    public var aliases: [String: String] = [:]
    /// Name the user typed for the current invocation (`[` vs `test` need it).
    public var lastInvokedName: String?

    public init(fs: FileSystemService, history: HistoryStore) {
        self.fs = fs
        self.history = history
        self.registry = CommandRegistry()
        self.environment = [
            "HOME": SandboxPath.homePrefix,
            "USER": "xtermux",
            "SHELL": "/bin/xsh",
            "TERM": "xterm-256color",
            "PATH": "/bin:/usr/bin",
            "XTOOL_BRANCH": "local-sandbox",
        ]
        registry.registerAll()
    }

    // MARK: environment

    public func value(for name: String) -> String? {
        switch name {
        case "PWD":
            return cwd
        case "?":
            return String(lastExitCode)
        default:
            return environment[name]
        }
    }

    public func setEnv(_ name: String, _ value: String) {
        environment[name] = value
    }

    /// `$VAR` / `${VAR}` / `$?` expansion outside single quotes.
    public func expandVariables(in line: String) -> String {
        var result = ""
        var inSingle = false
        var index = line.startIndex

        while index < line.endIndex {
            let char = line[index]

            if char == "'", !inSingle {
                inSingle = true
                result.append(char)
            } else if char == "'", inSingle {
                inSingle = false
                result.append(char)
            } else if char == "$", !inSingle {
                result.append(contentsOf: readVariable(after: index, in: line))
                // Advance past the variable reference.
                index = advancePastVariable(from: index, in: line)
                continue
            } else {
                result.append(char)
            }
            index = line.index(after: index)
        }
        return result
    }

    private func variableEnd(from index: String.Index, in line: String) -> String.Index {
        // index points at the character after '$'
        var i = index
        if i < line.endIndex, line[i] == "{" {
            i = line.index(after: i)
            while i < line.endIndex, line[i] != "}" {
                i = line.index(after: i)
            }
            return i == line.endIndex ? i : line.index(after: i)
        }
        if i < line.endIndex, line[i] == "?" {
            return line.index(after: i)
        }
        while i < line.endIndex, line[i].isLetter || line[i].isNumber || line[i] == "_" {
            i = line.index(after: i)
        }
        return i
    }

    private func readVariable(after dollar: String.Index, in line: String) -> String {
        let end = variableEnd(from: line.index(after: dollar), in: line)
        guard line.index(after: dollar) < end else { return "$" }
        let start = line.index(after: dollar)
        var raw = String(line[start..<end])
        if raw.hasPrefix("{"), raw.hasSuffix("}") {
            raw = String(raw.dropFirst().dropLast())
        }
        return value(for: raw) ?? ""
    }

    private func advancePastVariable(from dollar: String.Index, in line: String) -> String.Index {
        variableEnd(from: line.index(after: dollar), in: line)
    }

    // MARK: directory change (used by `cd`)

    public func chdir(_ target: String) throws -> String {
        let resolved = try SandboxPath.resolve(target, relativeTo: cwd)
        guard fs.isDirectory(resolved, relativeTo: "/") else {
            throw FileSystemError.notADirectory(resolved)
        }
        cwd = resolved
        return cwd
    }

    // MARK: resolution & aliases

    public enum CommandResolution {
        case found(ShellCommand)
        /// A real module command exists, but its module is disabled.
        case notInstalled(module: String)
        case unknown
    }

    /// Registry lookup plus the honest `pkg` module gate.
    public func resolve(_ name: String) -> CommandResolution {
        guard let command = registry.lookup(name) else { return .unknown }
        if let module = SandboxModuleCatalog.module(containingCommand: name) {
            if !PkgDB.installedModules(fs: fs).contains(module.name) {
                return .notInstalled(module: module.name)
            }
        }
        return .found(command)
    }

    private struct UnquotedHead {
        let token: String
        let end: String.Index
    }

    private func firstUnquotedToken(_ line: String) -> UnquotedHead? {
        var index = line.startIndex
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] != "'", line[index] != "\"" else { return nil }
        var end = index
        while end < line.endIndex, line[end] != " ", line[end] != "\t" {
            end = line.index(after: end)
        }
        return UnquotedHead(token: String(line[index..<end]), end: end)
    }

    /// Expands the leading unquoted token against the alias table. Bash-like:
    /// quoted heads never expand; a name never expands twice on one line.
    private func aliasExpanded(_ line: String) -> String {
        var result = line
        var seen: Set<String> = []
        var depth = 0
        while depth < 10 {
            guard let head = firstUnquotedToken(result),
                  !seen.contains(head.token),
                  let value = aliases[head.token], !value.isEmpty else { break }
            seen.insert(head.token)
            result = value + String(result[head.end...])
            depth += 1
        }
        return result
    }

    // MARK: main entry

    @discardableResult
    public func executeLine(_ raw: String) -> ShellExecutionResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ShellExecutionResult(exitCode: lastExitCode, visibleOutput: "", wantsSessionEnd: false)
        }
        history.record(raw)

        let expanded = expandVariables(in: raw)
        let aliased = aliasExpanded(expanded)

        let stages: [ScannedCommand]
        do {
            stages = try CommandScanner.scan(aliased)
        } catch let error as ScannerError {
            lastExitCode = 2
            return ShellExecutionResult(
                exitCode: 2,
                visibleOutput: ANSI.red("shell: syntax error near position \(ScannerFeedback.position(of: error))") + "\n",
                wantsSessionEnd: false
            )
        } catch {
            lastExitCode = 2
            return ShellExecutionResult(exitCode: 2, visibleOutput: ANSI.red("shell: parse error") + "\n", wantsSessionEnd: false)
        }
        if stages.isEmpty {
            return ShellExecutionResult(exitCode: lastExitCode, visibleOutput: "", wantsSessionEnd: false)
        }

        var visible = ""
        var pipelineStdin = ""
        var exitCode = 0

        stageLoop: for (stageIndex, stage) in stages.enumerated() {
            let io = CommandIO(stdin: pipelineStdin)

            if let name = stage.name {
                lastInvokedName = name
                switch resolve(name) {
                case .found(let command):
                    exitCode = command.run(self, args: stage.arguments, io: io)
                    lastExitCode = exitCode
                case .unknown:
                    io.printError("shell: command not found: \(name)")
                    if let tip = CommandRegistry.suggestions[name] {
                        io.printError("shell: \(name) — \(tip)")
                    }
                    visible += io.err
                    exitCode = 127
                    lastExitCode = 127
                    break stageLoop
                case .notInstalled(let module):
                    io.printError("shell: \(name) — pkg '\(module)' is not installed (run: pkg install \(module))")
                    visible += io.err
                    exitCode = 127
                    lastExitCode = 127
                    break stageLoop
                }
            } else {
                // Redirect-only stage, e.g. "> file" — legal (creates/expects a file).
                exitCode = 0
                lastExitCode = 0
            }

            // Apply this stage's redirections.
            var wroteStdoutToDisk = false
            for redirect in stage.redirects {
                if redirect.argument.isEmpty {
                    io.printError("shell: missing redirect target")
                    continue
                }
                switch redirect.kind {
                case .overwrite:
                    do {
                        try fs.writeText(redirect.argument, relativeTo: cwd, content: io.out)
                        wroteStdoutToDisk = true
                    } catch {
                        io.printError("shell: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
                        exitCode = 1
                        lastExitCode = 1
                    }
                case .append:
                    do {
                        let existing = (try? fs.readText(redirect.argument, relativeTo: cwd))?.text ?? ""
                        try fs.writeText(redirect.argument, relativeTo: cwd, content: existing + io.out)
                        wroteStdoutToDisk = true
                    } catch {
                        io.printError("shell: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
                        exitCode = 1
                        lastExitCode = 1
                    }
                case .infile:
                    if stageIndex == 0 {
                        do {
                            // Re-run with the file contents as stdin (single re-run, POSIX `<` semantics
                            // for simple commands). For stage > 0, stdin comes from the pipe.
                            let contents = try fs.readText(redirect.argument, relativeTo: cwd).text
                            if stage.name != nil {
                                let retry = CommandIO(stdin: contents)
                                lastInvokedName = stage.name
                                switch resolve(stage.name!) {
                                case .found(let command):
                                    exitCode = command.run(self, args: stage.arguments, io: retry)
                                    lastExitCode = exitCode
                                    io.out = retry.out + io.out
                                    io.err = retry.err
                                case .unknown:
                                    io.printError("shell: command not found: \(stage.name!)")
                                    exitCode = 127
                                    lastExitCode = 127
                                case .notInstalled(let module):
                                    io.printError("shell: \(stage.name!) — pkg '\(module)' is not installed (run: pkg install \(module))")
                                    exitCode = 127
                                    lastExitCode = 127
                                }
                            } else {
                                io.writeOutput(contents)
                            }
                        } catch {
                            io.printError("shell: cannot open '\(redirect.argument)': \((error as? FileSystemError)?.errorDescription ?? "unreadable")")
                            exitCode = 1
                            lastExitCode = 1
                        }
                    }
                }
            }

            // stderr flows to the terminal raw (commands print their own
            // "ls: …"-style prefixes; shell-level lines above already carry
            // the "shell:" prefix where they are emitted).
            visible += io.err
            let isLast = stageIndex == stages.count - 1
            if !wroteStdoutToDisk {
                if isLast { visible += io.out }
                pipelineStdin = io.out
            } else {
                pipelineStdin = ""
            }
        }

        return ShellExecutionResult(exitCode: lastExitCode, visibleOutput: visible, wantsSessionEnd: sessionWantsExit)
    }
}

enum ScannerFeedback {
    static func position(of error: ScannerError) -> Int {
        switch error {
        case .unterminatedQuote(let p): return p
        case .danglingRedirect(let p): return p
        }
    }
}
