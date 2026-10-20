// ModulePackages.swift
// XTermux — honest in-app module packages for the sandbox shell.
//
// A "module package" is a named group of built-in shell commands delivered
// inside the app itself. `pkg install` enables the module's commands;
// `pkg remove` gates them behind an honest error (+ a real exit code 127).
//
// There is no network download, no root, and no Linux binaries anywhere in
// this flow: real remote tools are reached over SSH, exactly as the app's
// own help explains. State persists per-sandbox in "/.xpkg/installed.json".

import Foundation

public struct SandboxModule: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let version: String
    public let summary: String
    public let commands: [String]

    public init(name: String, version: String, summary: String, commands: [String]) {
        self.name = name
        self.version = version
        self.summary = summary
        self.commands = commands
    }
}

public enum SandboxModuleCatalog {
    /// All installable in-app modules. Every module ships inside the binary;
    /// the database only records which ones are enabled.
    public static let modules: [SandboxModule] = [
        SandboxModule(
            name: "sed",
            version: "1.0.0",
            summary: "Stream editor subset: s///, p, d, q with line/regex addresses and ranges",
            commands: ["sed"]
        ),
        SandboxModule(
            name: "gawk",
            version: "1.0.0",
            summary: "AWK text processor subset: patterns, fields, print/printf, arithmetic",
            commands: ["awk"]
        ),
        SandboxModule(
            name: "diffutils",
            version: "1.0.0",
            summary: "Line-based file comparison (normal format and -u unified)",
            commands: ["diff"]
        ),
        SandboxModule(
            name: "file-utils",
            version: "1.0.0",
            summary: "File inspection: stat, du, df, tree, basename, dirname",
            commands: ["stat", "du", "df", "tree", "basename", "dirname"]
        ),
        SandboxModule(
            name: "shell-utils",
            version: "1.0.0",
            summary: "Shell conveniences: seq, sleep, printf, alias, unalias, xargs, expr, tac, rev, uniq, nl",
            commands: ["seq", "sleep", "printf", "alias", "unalias", "xargs", "expr", "tac", "rev", "uniq", "nl"]
        ),
    ]

    public static func module(containingCommand commandName: String) -> SandboxModule? {
        modules.first { $0.commands.contains(commandName) }
    }

    public static func module(named name: String) -> SandboxModule? {
        modules.first { $0.name == name }
    }
}

public enum PkgDB {
    /// Virtual path inside the sandbox root; each sandbox keeps its own state.
    public static let storagePath = "/.xpkg/installed.json"

    /// Fresh sandboxes (or a missing/corrupt state file) behave like Termux's
    /// base set: everything this app can offer is already installed.
    public static var defaultInstalled: Set<String> {
        Set(SandboxModuleCatalog.modules.map { $0.name })
    }

    public static func installedModules(fs: FileSystemService) -> Set<String> {
        guard let contents = try? fs.readText(storagePath, relativeTo: "/").text else {
            return defaultInstalled
        }
        guard let data = contents.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return defaultInstalled
        }
        let known = SandboxModuleCatalog.modules.map { $0.name }
        return Set(names.filter { known.contains($0) })
    }

    public static func save(_ installed: Set<String>, fs: FileSystemService) throws {
        let names = SandboxModuleCatalog.modules
            .map { $0.name }
            .filter { installed.contains($0) }
            .sorted()
        let data = try JSONEncoder().encode(names)
        let text = String(decoding: data, as: UTF8.self)
        try fs.writeText(storagePath, relativeTo: "/", content: text, createParents: true)
    }
}

/// `pkg` — the manager for in-app sandbox modules.
struct PkgCommand: ShellCommand {
    var name: String { "pkg" }
    var aliases: [String] { [] }
    var usage: String { "pkg list | search TERM | install MODULE… | remove MODULE… | info MODULE" }
    var help: String { "enable or disable in-app command modules (honest: nothing is downloaded — modules ship inside the app; real remote tools need SSH, see 'help ssh')" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        guard let subcommand = args.first else {
            io.printError("pkg: usage: \(usage)")
            return 2
        }
        let rest = Array(args.dropFirst())
        switch subcommand {
        case "list": return list(rest, engine: engine, io: io)
        case "search": return search(rest, io: io)
        case "install": return change(rest, engine: engine, io: io, adding: true)
        case "remove", "uninstall": return change(rest, engine: engine, io: io, adding: false)
        case "info": return info(rest, engine: engine, io: io)
        case "help", "--help", "-h":
            io.printLine("pkg — manage in-app sandbox modules")
            io.printLine("usage: \(usage)")
            return 0
        default:
            io.printError("pkg: unknown subcommand '\(subcommand)' (supported: list search install remove info)")
            return 2
        }
    }

    private func list(_ args: [String], engine: ShellEngine, io: CommandIO) -> Int {
        let installed = PkgDB.installedModules(fs: engine.fs)
        io.printLine("in-app modules (\(SandboxModuleCatalog.modules.count)) — these run inside the app sandbox; no Linux binaries are involved")
        for module in SandboxModuleCatalog.modules {
            let state = installed.contains(module.name) ? "installed" : "not installed"
            io.printLine(TextPad.right(module.name, 12) + " " +
                         TextPad.right(state, 13) + " " +
                         module.commands.joined(separator: ", "))
        }
        return 0
    }

    private func search(_ args: [String], io: CommandIO) -> Int {
        guard let term = args.first(where: { !ShellArgs.isFlag($0) }) else {
            io.printError("pkg: usage: pkg search TERM")
            return 2
        }
        let needle = term.lowercased()
        for module in SandboxModuleCatalog.modules {
            let haystack = ([module.name, module.summary] + module.commands).joined(separator: " ").lowercased()
            if haystack.contains(needle) {
                io.printLine(TextPad.right(module.name, 12) + " " + module.summary)
            }
        }
        // No hits is not an error: apt search also exits 0 on an empty result.
        return 0
    }

    private func change(_ args: [String], engine: ShellEngine, io: CommandIO, adding: Bool) -> Int {
        let names = args.filter { !ShellArgs.isFlag($0) }
        guard !names.isEmpty else {
            io.printError("pkg: usage: pkg \(adding ? "install" : "remove") MODULE…")
            return 2
        }

        var targets: [SandboxModule] = []
        var seen = Set<String>()
        for name in names {
            guard let module = SandboxModuleCatalog.module(named: name) else {
                io.printError("pkg: module not found: \(name) (see: pkg list)")
                return 1
            }
            if seen.insert(name).inserted {
                targets.append(module)
            }
        }

        let installed = PkgDB.installedModules(fs: engine.fs)
        let changed = targets.filter { adding ? !installed.contains($0.name) : installed.contains($0.name) }
        let untouched = targets.filter { !changed.contains($0) }

        if changed.isEmpty {
            for module in untouched {
                if adding {
                    io.printLine("pkg: \(module.name) is already installed")
                } else {
                    io.printLine("pkg: \(module.name) is not installed")
                }
            }
            return 0
        }

        var updated = installed
        let verb = adding ? "Installing" : "Removing"
        for module in changed {
            if adding { updated.insert(module.name) } else { updated.remove(module.name) }
            io.printLine("\(verb) \(module.name) \(module.version) (in-app module; nothing is downloaded)")
        }
        do {
            try PkgDB.save(updated, fs: engine.fs)
        } catch {
            io.printError("pkg: could not save module state: \((error as? FileSystemError)?.errorDescription ?? String(describing: error))")
            return 1
        }
        let commandNames = changed.flatMap { $0.commands }.sorted()
        if adding {
            io.printLine("commands ready: \(commandNames.joined(separator: ", "))")
        } else {
            io.printLine("commands now gated: \(commandNames.joined(separator: ", ")) — reinstall with: pkg install \(changed.map { $0.name }.joined())")
        }
        return 0
    }

    private func info(_ args: [String], engine: ShellEngine, io: CommandIO) -> Int {
        guard let name = args.first(where: { !ShellArgs.isFlag($0) }) else {
            io.printError("pkg: usage: pkg info MODULE")
            return 2
        }
        guard let module = SandboxModuleCatalog.module(named: name) else {
            io.printError("pkg: module not found: \(name) (see: pkg list)")
            return 1
        }
        let installed = PkgDB.installedModules(fs: engine.fs).contains(module.name)
        io.printLine("Name:    \(module.name)")
        io.printLine("Version: \(module.version) (in-app module)")
        io.printLine("Status:  \(installed ? "installed" : "not installed")")
        io.printLine("Summary: \(module.summary)")
        io.printLine("Provides: \(module.commands.joined(separator: ", "))")
        io.printLine("Note:    part of the XTermux binary — no download, no root, no Linux binaries")
        return 0
    }
}
