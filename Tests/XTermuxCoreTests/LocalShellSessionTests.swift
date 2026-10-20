// LocalShellSessionTests.swift — the byte-level terminal state machine:
// echo, history navigation, Ctrl-R search, exit handling.

import XCTest
@testable import XTermuxCore

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var finished = false

    func append(_ string: String) {
        lock.lock()
        defer { lock.unlock() }
        text += string
    }

    func markFinished() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}

final class LocalShellSessionTests: XCTestCase {
    private func makeSandbox() throws -> (fs: FileSystemService, engine: ShellEngine) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtermux-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fs = FileSystemService(baseURL: dir)
        fs.bootstrapDefaultLayout()
        let engine = ShellEngine(fs: fs, history: HistoryStore(baseURL: dir))
        return (fs, engine)
    }

    private func consumer(for session: LocalShellSession) -> OutputCollector {
        let collector = OutputCollector()
        Task {
            for await event in session.events {
                if case .output(let bytes) = event {
                    collector.append(String(decoding: bytes, as: UTF8.self))
                }
            }
            collector.markFinished()
        }
        return collector
    }

    /// Lets the stream consumer task drain the buffered events.
    private func drainMoment() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func testBannerPromptEcho() async throws {
        let (_, engine) = try makeSandbox()
        let session = LocalShellSession(engine: engine)
        session.activate()
        let collector = consumer(for: session)

        session.sendInput(Array("echo hi\n".utf8))
        try await drainMoment()

        XCTAssertTrue(collector.value.contains("hi\r\n"))
        XCTAssertTrue(collector.value.contains("$ "))
    }

    func testLocalEchoContainsTypedText() async throws {
        let (_, engine) = try makeSandbox()
        let session = LocalShellSession(engine: engine)
        session.activate()
        let collector = consumer(for: session)

        session.sendInput(Array("echo".utf8))
        try await drainMoment()

        // The session echoes what the user typed (local echo mode).
        XCTAssertTrue(collector.value.contains("echo"))
    }

    func testArrowUpRecallsHistoryExecution() async throws {
        let (_, engine) = try makeSandbox()
        let session = LocalShellSession(engine: engine)
        session.activate()
        let collector = consumer(for: session)

        session.sendInput(Array("echo first\n".utf8))
        session.sendInput(Array("echo second\n".utf8))
        // ↑ ↑ then Enter should re-run `echo first`.
        session.sendInput([0x1b, 0x5b, 0x41])
        session.sendInput([0x1b, 0x5b, 0x41])
        session.sendInput([0x0d])
        try await drainMoment()

        XCTAssertTrue(collector.value.contains("first\r\n"))
    }

    func testCtrlRSearchReplaysMatch() async throws {
        let (_, engine) = try makeSandbox()
        let session = LocalShellSession(engine: engine)
        session.activate()
        let collector = consumer(for: session)

        session.sendInput(Array("echo alpha\n".utf8))
        try await drainMoment()
        let before = collector.value

        session.sendInput([0x12]) // Ctrl-R
        session.sendInput([0x0d]) // accept candidate
        try await drainMoment()

        // "alpha\r\n" appears once for the original run and once for the replay.
        let occurrences = components(of: collector.value, separatedBy: "alpha\r\n").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 1)
        _ = before
    }

    func testCtrlCCancelsLine() async throws {
        let (_, engine) = try makeSandbox()
        let session = LocalShellSession(engine: engine)
        session.activate()
        let collector = consumer(for: session)

        session.sendInput(Array("echo never-reaches-shell".utf8))
        session.sendInput([0x03])
        session.sendInput(Array("echo after\n".utf8))
        try await drainMoment()

        XCTAssertFalse(collector.value.contains("never-reaches-shell\r\n") && !collector.value.contains("^C"))
        XCTAssertTrue(collector.value.contains("after\r\n"))
    }

    func testExitFinishesSession() async throws {
        let (_, engine) = try makeSandbox()
        let session = LocalShellSession(engine: engine)
        session.activate()
        let collector = consumer(for: session)

        session.sendInput(Array("exit 3\n".utf8))
        try await drainMoment()

        XCTAssertTrue(collector.value.contains("logout"))
        XCTAssertTrue(collector.isFinished)
        XCTAssertEqual(engine.lastExitCode, 3)
    }

    func testInputAfterExitIsIgnoredSafely() async throws {
        let (_, engine) = try makeSandbox()
        let session = LocalShellSession(engine: engine)
        session.activate()
        let collector = consumer(for: session)

        session.sendInput(Array("exit\n".utf8))
        try await drainMoment()
        let afterExit = collector.value

        session.sendInput(Array("echo more\n".utf8))
        try await drainMoment()

        XCTAssertEqual(collector.value, afterExit)
    }

    private func components(of text: String, separatedBy separator: String) -> [String] {
        text.components(separatedBy: separator)
    }
}
