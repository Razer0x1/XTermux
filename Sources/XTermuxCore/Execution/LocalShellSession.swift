// LocalShellSession.swift
// XTermux — session wrapper around ShellEngine for the local sandbox backend.
//
// This is a REAL line-oriented shell front end, not a mock:
//   - printable echo + in-place editing (cursor moves, backspace, Ctrl-W/K/U)
//   - ↑/↓ persistent history navigation, Ctrl-R reverse search, Tab completion
//   - Ctrl-C cancel, Ctrl-D logout, Ctrl-L clear
//   - shell output (stdout + stderr + prompt) is streamed as terminal bytes
//     that SwiftTerm renders directly
//
// It owns the echo (ExecutionBackend.echoMode == .localEcho): bytes typed by
// the user are rendered by this class, never by the remote (there is none).
//
// The execution engine is synchronous and fast (in-memory); a single NSLock
// serializes the whole byte-processing state machine, which keeps Swift
// concurrency composition clean without actor hops.

import Foundation

public final class LocalShellSession: ExecutionSession, @unchecked Sendable {
    public let events: AsyncStream<SessionEvent>
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let engine: ShellEngine
    private let lock = NSLock()
    private var closed = false

    // line-editing state
    private var line: [Character] = []
    private var cursor = 0
    private var promptText = ""
    private var historyIndex = -1
    private var savedLiveLine: [Character] = []
    private var escapeBuffer: [UInt8] = []
    private var utf8Pending: [UInt8] = []
    private var utf8Remaining = 0

    // reverse-search state (Ctrl-R)
    private var searchMode = false
    private var searchQuery = ""
    private var searchIndex = 0
    private var preSearchLine: [Character] = []

    init(engine: ShellEngine) {
        var continuation: AsyncStream<SessionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self.engine = engine
    }

    /// Emits the banner + first prompt. Called once by the backend after init.
    public func activate() {
        lock.lock()
        defer { lock.unlock() }
        emitBanner()
        continuation.yield(.status(.running))
        printPrompt()
    }

    // MARK: ExecutionSession

    public func sendInput(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        for byte in bytes {
            accept(byte)
        }
    }

    public func resize(cols: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        engine.terminalWidth = max(20, cols)
    }

    public func terminate() async {
        performTerminate()
    }

    /// A synchronous helper so the lock is never held across an await point
    /// (Foundation forbids NSLock.lock() directly in async contexts).
    private func performTerminate() {
        lock.lock()
        defer { lock.unlock() }
        endSession()
    }

    // MARK: byte state machine

    private func accept(_ byte: UInt8) {
        if !escapeBuffer.isEmpty {
            processEscape(byte)
            return
        }
        switch byte {
        case 0x0d, 0x0a: // CR / LF — execute (also from pasted multi-lines)
            executeCurrentLine()
        case 0x7f, 0x08: // DEL / BS
            deleteBefore()
        case 0x09: // Tab
            tabComplete()
        case 0x1b: // ESC
            escapeBuffer = [0x1b]
        case let b where b < 0x20:
            control(b)
        case let b where b >= 0x80:
            unicode(byte)
        default:
            insert(Character(UnicodeScalar(byte)))
        }
    }

    private func control(_ byte: UInt8) {
        switch byte {
        case 0x03: // Ctrl-C — cancel input / finish search
            if searchMode { cancelSearch() } else { cancelLine() }
        case 0x04: // Ctrl-D — EOF on empty line, delete-forward otherwise
            if searchMode { cancelSearch(); return }
            if line.isEmpty { endSession() } else { deleteForward() }
        case 0x0c: // Ctrl-L — clear screen, redraw
            if searchMode { cancelSearch(); return }
            emit(ANSI.clearScreen)
            printPrompt()
            renderInputText()
        case 0x12: // Ctrl-R — start / continue reverse search
            if searchMode { cycleSearch() } else { startSearch() }
        case 0x15: // Ctrl-U — kill whole line
            if searchMode { cancelSearch(); return }
            line = []
            cursor = 0
            renderInputLine()
        case 0x0b: // Ctrl-K — kill to end of line
            if searchMode { cancelSearch(); return }
            while cursor < line.count { line.removeLast() }
            renderInputText()
        case 0x17: // Ctrl-W — kill previous word
            if searchMode { cancelSearch(); return }
            deleteWord()
        case 0x01: // Ctrl-A — home
            jumpCursor(to: 0)
        case 0x05: // Ctrl-E — end
            jumpCursor(to: line.count)
        default:
            break // other control bytes are ignored honestly, not echoed
        }
    }

    private func processEscape(_ byte: UInt8) {
        // The buffer always starts with ESC.
        if escapeBuffer.count == 1 {
            switch byte {
            case 0x5b: escapeBuffer.append(byte) // CSI ("ESC [")
            case 0x4f: escapeBuffer.append(byte) // SS3 ("ESC O")
            default: escapeBuffer = []           // swallow two-byte sequences (honest)
            }
            return
        }
        if escapeBuffer[1] == 0x4f {
            escapeBuffer = []
            dispatchArrow(byte)
            return
        }
        if (0x40...0x7e).contains(byte) { // CSI final byte
            escapeBuffer = []
            dispatchArrow(byte)
            return
        }
        escapeBuffer.append(byte) // parameters, e.g. "1;5"
    }

    private func dispatchArrow(_ byte: UInt8) {
        switch byte {
        case 0x41: historyPrev()
        case 0x42: historyNext()
        case 0x43: moveCursor(+1)
        case 0x44: moveCursor(-1)
        default: break
        }
    }

    // MARK: unicode ingestion

    private func unicode(_ byte: UInt8) {
        if utf8Pending.isEmpty {
            guard let total = Self.utf8SequenceLength(byte) else { return } // stray byte
            utf8Pending = [byte]
            utf8Remaining = total - 1
            return
        }
        guard (0x80...0xbf).contains(byte) else {
            utf8Pending = []
            utf8Remaining = 0
            unicode(byte) // broken sequence: retry this byte as a lead byte
            return
        }
        utf8Pending.append(byte)
        utf8Remaining -= 1
        guard utf8Remaining == 0 else { return }
        let bytes = utf8Pending
        utf8Pending = []
        if let scalar = String(decoding: bytes, as: UTF8.self).unicodeScalars.first,
           scalar.value != 0xFFFD {
            insert(Character(scalar))
        }
    }

    private static func utf8SequenceLength(_ lead: UInt8) -> Int? {
        switch lead {
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default: return nil
        }
    }

    // MARK: editing primitives

    private func insert(_ char: Character) {
        if searchMode {
            searchType(String(char))
            return
        }
        line.insert(char, at: cursor)
        cursor += 1
        emit(String(char))
        if cursor < line.count { renderInputText() }
    }

    private func deleteBefore() {
        if searchMode {
            searchBack()
            return
        }
        guard cursor > 0 else { bell(); return }
        line.remove(at: cursor - 1)
        cursor -= 1
        renderInputLine()
    }

    private func deleteForward() {
        guard cursor < line.count else { bell(); return }
        line.remove(at: cursor)
        renderInputText()
    }

    private func deleteWord() {
        guard cursor > 0 else { bell(); return }
        var j = cursor - 1
        while j >= 0, line[j] == " " || line[j] == "\t" { j -= 1 }
        while j >= 0, line[j] != " ", line[j] != "\t" { j -= 1 }
        let start = j + 1
        guard start < cursor else { bell(); return }
        line.removeSubrange(start..<cursor)
        cursor = start
        renderInputLine()
    }

    private func moveCursor(_ delta: Int) {
        let next = min(max(0, cursor + delta), line.count)
        jumpCursor(to: next)
    }

    private func jumpCursor(to target: Int) {
        guard target != cursor, (0...line.count).contains(target) else { bell(); return }
        cursor = target
        emit("\r" + ANSI.moveRight(promptColumns + cursor))
    }

    // MARK: rendering

    private func text() -> String {
        String(line)
    }

    /// Repaints prompt + whole input line, leaving the cursor at `cursor`.
    private func renderInputLine() {
        emit("\r" + ANSI.clearLineRight + promptText + text())
        if cursor < line.count { emit(ANSI.moveBack(line.count - cursor)) }
    }

    /// Repaints just the text portion (prompt already on screen).
    private func renderInputText() {
        emit(ANSI.clearLineRight + line[cursor...].map { String($0) }.joined())
    }

    private func bell() {
        emit("\u{07}")
    }

    private func printPrompt() {
        promptText = ANSI.green(ShellInfo.sandboxUser) + ":" + ANSI.blue(SandboxPath.display(engine.cwd)) + "$ "
        emit(promptText)
    }

    private var promptColumns: Int {
        Self.stripANSI(promptText).count
    }

    /// Removes CSI sequences so column math is correct (pads count screen cells).
    static func stripANSI(_ text: String) -> String {
        var out = ""
        var inEscape = false
        for char in text {
            if inEscape {
                if let value = char.unicodeScalars.first?.value, (0x40...0x7e).contains(value) {
                    inEscape = false
                }
            } else if char == "\u{1b}" {
                inEscape = true
            } else {
                out.append(char)
            }
        }
        return out
    }

    private func crlf(_ text: String) -> String {
        var out = ""
        var index = 0
        let chars = Array(text)
        while index < chars.count {
            if chars[index] == "\r", index + 1 < chars.count, chars[index + 1] == "\n" {
                out += "\r\n"
                index += 2
                continue
            }
            if chars[index] == "\n" {
                out += "\r\n"
                index += 1
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return out
    }

    // MARK: history navigation

    private func historyPrev() {
        guard !searchMode else { return }
        let next = historyIndex + 1
        guard let command = engine.history.entry(fromEnd: next) else { bell(); return }
        if historyIndex == -1 { savedLiveLine = line }
        historyIndex = next
        line = Array(command)
        cursor = line.count
        renderInputLine()
    }

    private func historyNext() {
        guard !searchMode, historyIndex != -1 else { bell(); return }
        let previous = historyIndex - 1
        if previous == -1 {
            historyIndex = -1
            line = savedLiveLine
            cursor = line.count
        } else {
            guard let command = engine.history.entry(fromEnd: previous) else { bell(); return }
            historyIndex = previous
            line = Array(command)
            cursor = line.count
        }
        renderInputLine()
    }

    // MARK: reverse search

    private func startSearch() {
        preSearchLine = line
        searchMode = true
        searchQuery = ""
        searchIndex = 0
        renderSearchLine()
    }

    private func searchType(_ text: String) {
        searchQuery += text
        searchIndex = 0
        renderSearchLine()
    }

    private func searchBack() {
        guard !searchQuery.isEmpty else { bell(); return }
        searchQuery.removeLast()
        searchIndex = 0
        renderSearchLine()
    }

    private func cycleSearch() {
        searchIndex += 1
        renderSearchLine()
    }

    private func cancelSearch() {
        searchMode = false
        line = preSearchLine
        cursor = line.count
        renderInputLine()
    }

    private func acceptSearch() {
        let candidate = searchCandidate ?? String(preSearchLine)
        searchMode = false
        line = Array(candidate)
        cursor = line.count
    }

    /// Most recent history entry (at/after `searchIndex`) containing the query.
    private var searchCandidate: String? {
        var index = searchIndex
        while let command = engine.history.entry(fromEnd: index) {
            if command.contains(searchQuery) { return command }
            index += 1
        }
        return nil
    }

    private func renderSearchLine() {
        let marker = "rsearch '\(searchQuery)': "
        let candidate = searchCandidate
        let body = candidate ?? "(no match)"
        emit("\r" + ANSI.clearLineRight + ANSI.bold(marker) + body)
    }

    // MARK: tab completion

    private func tabComplete() {
        guard !searchMode else { bell(); return }
        // token = current word from token start to cursor
        var tokenStart = cursor
        while tokenStart > 0, line[tokenStart - 1] != " ", line[tokenStart - 1] != "\t" {
            tokenStart -= 1
        }
        let token = String(line[tokenStart..<cursor])
        let slash = token.lastIndex(of: "/")
        let dirPart = slash.map { String(token[...$0]) } ?? ""
        let namePrefix = slash.map { String(token[token.index(after: $0)...]) } ?? token

        do {
            let dir = try SandboxPath.resolve(dirPart.isEmpty ? "." : dirPart, relativeTo: engine.cwd)
            let entries = try engine.fs.listEntries(dir, relativeTo: "/", includeHidden: namePrefix.hasPrefix("."))
            var candidates = entries
                .filter { $0.name.hasPrefix(namePrefix) }
                .map { (name: $0.name, isDirectory: $0.isDirectory) }
            if dirPart.isEmpty {
                for command in engine.registry.allCommands()
                where command.name.hasPrefix(namePrefix) {
                    candidates.append((command.name, false))
                }
            }
            guard !candidates.isEmpty else { bell(); return }

            if candidates.count == 1 {
                complete(with: candidates[0].name, intoDirectory: candidates[0].isDirectory, tokenStart: tokenStart, prefixLen: namePrefix.count)
                return
            }
            let common = Self.longestCommonPrefix(candidates.map { $0.name })
            if common.count > namePrefix.count {
                complete(with: common, intoDirectory: false, tokenStart: tokenStart, prefixLen: namePrefix.count)
                return
            }
            // list the choices, then redraw the prompt + line exactly as before
            bell()
            emit("\r\n")
            let names = candidates.map { $0.isDirectory ? $0.name + "/" : $0.name }
            emit(LsCommand.columns(names, width: max(40, engine.terminalWidth)))
            renderInputLine()
        } catch {
            bell()
        }
    }

    private func complete(with match: String, intoDirectory: Bool, tokenStart: Int, prefixLen: Int) {
        let suffix = String(match.dropFirst(prefixLen)) + (intoDirectory ? "/" : " ")
        for char in suffix {
            line.insert(char, at: cursor)
            cursor += 1
            emit(String(char))
        }
    }

    static func longestCommonPrefix(_ strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = ""
        for (offset, char) in first.enumerated() {
            if strings.allSatisfy({ $0.count > offset && Array($0)[offset] == char }) {
                prefix.append(char)
            } else {
                break
            }
        }
        return prefix
    }

    // MARK: execution

    private func executeCurrentLine() {
        if searchMode {
            acceptSearch()
        }
        let commandLine = text()
        emit("\r\n")
        line = []
        cursor = 0
        historyIndex = -1
        let result = engine.executeLine(commandLine)
        postExecute(result)
    }

    private func cancelLine() {
        // ^C echoes like a real shell and starts fresh
        emit("^C")
        line = []
        cursor = 0
        historyIndex = -1
        emit("\r\n")
        printPrompt()
    }

    private func postExecute(_ result: ShellExecutionResult) {
        emit(crlf(result.visibleOutput))
        if engine.sessionWantsExit {
            endSession()
            return
        }
        printPrompt()
    }

    private func emitBanner() {
        let banner = """
        \(ShellInfo.appName) \(ShellInfo.appVersion) — in-app sandbox shell
        Commands run inside this app's iOS sandbox: no fork/exec, no root.
        Type 'help' for commands. Full Linux: Terminal tab → + → SSH.
        
        """
        emit(crlf(banner + "\n"))
    }

    private func emit(_ text: String) {
        continuation.yield(.output(Array(text.utf8)))
    }

    private func endSession() {
        guard !closed else { return }
        closed = true
        emit("\r\nlogout\r\n")
        continuation.yield(.status(.ended))
        continuation.finish()
    }
}

// MARK: backend

/// The always-available in-app execution backend.
public final class LocalShellBackend: ExecutionBackend, @unchecked Sendable {
    public var descriptor: BackendDescriptor {
        BackendDescriptor(
            id: "local",
            title: "Local sandbox",
            subtitle: "in-app commands — no subprocesses, no root"
        )
    }

    public var echoMode: EchoMode { .localEcho }

    public let fs: FileSystemService
    public let history: HistoryStore

    public init(fs: FileSystemService, history: HistoryStore) {
        self.fs = fs
        self.history = history
    }

    public func createSession(cols: Int, rows: Int) async throws -> ExecutionSession {
        let engine = ShellEngine(fs: fs, history: history)
        engine.terminalWidth = max(20, cols)
        let session = LocalShellSession(engine: engine)
        session.activate()
        return session
    }

    public func describeCapabilities() -> [BackendCapability] {
        [
            BackendCapability(name: "Builtin commands", state: .available, note: "in-process shell with ls, cat, grep, pipes and more"),
            BackendCapability(name: "Pipes & redirection", state: .available, note: "a | b, >, >>, < inside the sandbox"),
            BackendCapability(name: "Text tools", state: .available, note: "sort, cut, tr, wc, head, tail, chmod"),
            BackendCapability(name: "Subprocesses (fork/exec)", state: .unavailable, note: "iOS never allows App Store apps to spawn binaries"),
            BackendCapability(name: "Root / sudo", state: .unavailable, note: "never needed; iOS enforces the sandbox"),
            BackendCapability(name: "Kernel modification", state: .unavailable, note: "Darwin/XNU stays fully under iOS control"),
            BackendCapability(name: "Full Linux userland", state: .limited, note: "connect a real machine over SSH (Terminal → + → SSH)"),
        ]
    }
}
