// ShellEngineTests.swift — parser, expansion, pipes/redirects, file commands,
// exit codes and honest error paths for the XTermux sandbox shell.

import XCTest
@testable import XTermuxCore

final class ShellEngineTests: XCTestCase {
    private var dir: URL!
    private var fs: FileSystemService!
    private var engine: ShellEngine!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtermux-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fs = FileSystemService(baseURL: dir)
        fs.bootstrapDefaultLayout()
        engine = ShellEngine(fs: fs, history: HistoryStore(baseURL: dir))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: basic execution

    func testEchoOutputAndExitCode() {
        let result = engine.executeLine("echo hello")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.visibleOutput, "hello\n")
    }

    func testEchoNoNewline() {
        let result = engine.executeLine("echo -n raw")
        XCTAssertEqual(result.visibleOutput, "raw")
    }

    func testQuotedArgumentsPreserveSpacing() {
        let result = engine.executeLine("echo \"a   b  c\"")
        XCTAssertEqual(result.visibleOutput, "a   b  c\n")
    }

    func testCommandNotFoundIsHonest() {
        let result = engine.executeLine("totallymissingcmd")
        XCTAssertEqual(result.exitCode, 127)
        XCTAssertTrue(result.visibleOutput.contains("command not found: totallymissingcmd"))
    }

    func testUnsupportedCommandGetsHelpfulSuggestion() {
        let result = engine.executeLine("git status")
        XCTAssertEqual(result.exitCode, 127)
        XCTAssertTrue(result.visibleOutput.contains("SSH session"))
    }

    // MARK: expansion

    func testExportAndExpansion() {
        let result = engine.executeLine("export X=v1")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(engine.executeLine("echo $X").visibleOutput, "v1\n")
        XCTAssertEqual(engine.executeLine("echo pre${X}post").visibleOutput, "prev1post\n")
    }

    func testDollarQuestionReportsLastExitCode() {
        XCTAssertEqual(engine.executeLine("false").exitCode, 1)
        XCTAssertEqual(engine.executeLine("echo $?").visibleOutput, "1\n")
        XCTAssertEqual(engine.executeLine("true").exitCode, 0)
        XCTAssertEqual(engine.executeLine("echo $?").visibleOutput, "0\n")
    }

    // MARK: pipelines

    func testPipelineHidesIntermediateStage() throws {
        try fs.writeText("f.txt", relativeTo: engine.cwd, content: "3\n1\n2\n")
        let result = engine.executeLine("cat f.txt | sort")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.visibleOutput, "1\n2\n3\n")
    }

    func testThreeStagePipeline() throws {
        try fs.writeText("f.txt", relativeTo: engine.cwd, content: "apple\napricot\npear\n")
        let result = engine.executeLine("cat f.txt | grep ap | wc -l")
        XCTAssertTrue(result.visibleOutput.contains("2"))
        XCTAssertEqual(result.exitCode, 0)
    }

    func testPipeForwardAfterRedirectWritesEmpty() throws {
        try fs.writeText("f.txt", relativeTo: engine.cwd, content: "hi\n")
        let result = engine.executeLine("cat f.txt > o.txt | grep nothin")
        // stdout went to disk, so grep sees empty input and exits 1 (no match)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(try fs.readText("o.txt", relativeTo: engine.cwd).text, "hi\n")
        XCTAssertEqual(result.visibleOutput, "")
    }

    // MARK: redirection

    func testRedirectOverwritesThenAppends() throws {
        try fs.writeText("f.txt", relativeTo: engine.cwd, content: "3\n1\n2\n")
        XCTAssertEqual(engine.executeLine("sort f.txt > s.txt").visibleOutput, "")
        XCTAssertEqual(try fs.readText("s.txt", relativeTo: engine.cwd).text, "1\n2\n3\n")
        XCTAssertEqual(engine.executeLine("echo tail >> s.txt").exitCode, 0)
        XCTAssertEqual(try fs.readText("s.txt", relativeTo: engine.cwd).text, "1\n2\n3\ntail\n")
    }

    func testInfileRedirectFeedsStdin() throws {
        try fs.writeText("g.txt", relativeTo: engine.cwd, content: "hello\n")
        let result = engine.executeLine("cat < g.txt")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.visibleOutput, "hello\n")
    }

    func testRedirectOnlyStageCreatesFile() {
        let result = engine.executeLine("> out.txt")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(fs.exists("out.txt", relativeTo: engine.cwd))
    }

    func testRedirectToMissingParentFails() {
        let result = engine.executeLine("echo x > nodir/file.txt")
        XCTAssertEqual(result.exitCode, 1)
    }

    // MARK: scanner

    func testScannerSplitsPipelineAndRedirect() throws {
        let stages = try CommandScanner.scan("echo a | grep a > out.txt")
        XCTAssertEqual(stages.count, 2)
        XCTAssertEqual(stages[0].name, "echo")
        XCTAssertEqual(stages[1].name, "grep")
        XCTAssertEqual(stages[1].redirects, [RedirectSpec(kind: .overwrite, argument: "out.txt")])
    }

    func testScannerQuoteHandling() throws {
        let stages = try CommandScanner.scan("echo \"a b\" 'c d' plain")
        XCTAssertEqual(stages[0].argv, ["echo", "a b", "c d", "plain"])
    }

    func testScannerRejectsUnterminatedQuote() {
        XCTAssertThrowsError(try CommandScanner.scan("echo \"abc"))
    }

    func testScannerRejectsDanglingRedirect() {
        XCTAssertThrowsError(try CommandScanner.scan("echo >"))
    }

    // MARK: sort / cut / tr

    func testSortNumericUniqueAndReverse() throws {
        try fs.writeText("nums.txt", relativeTo: engine.cwd, content: "2\n10\n1\n2\n")
        XCTAssertEqual(engine.executeLine("sort -n -u nums.txt").visibleOutput, "1\n2\n10\n")
        XCTAssertEqual(engine.executeLine("sort -r nums.txt").visibleOutput, "2\n2\n10\n1\n")
    }

    func testCutFieldsAndCharacters() throws {
        try fs.writeText("csv.txt", relativeTo: engine.cwd, content: "a:b:c\nx:y:z\n")
        XCTAssertEqual(engine.executeLine("cut -d: -f2 csv.txt").visibleOutput, "b\ny\n")
        try fs.writeText("chars.txt", relativeTo: engine.cwd, content: "abcdef\n")
        XCTAssertEqual(engine.executeLine("cut -c1-3 chars.txt").visibleOutput, "abc\n")
    }

    func testCutInvalidSelectionIsRejected() {
        XCTAssertEqual(engine.executeLine("cut -f 0").exitCode, 2)
    }

    func testTrTranslatesAndDeletes() throws {
        XCTAssertEqual(engine.executeLine("echo abc | tr a-z A-Z").visibleOutput, "ABC\n")
        XCTAssertEqual(engine.executeLine("echo banana | tr -d a").visibleOutput, "bnn\n")
    }

    // MARK: filesystem commands

    func testFileLifecycleMkdirTouchCpMvRm() throws {
        XCTAssertEqual(engine.executeLine("mkdir sub").exitCode, 0)
        XCTAssertEqual(engine.executeLine("touch sub/f1").exitCode, 0)
        XCTAssertEqual(engine.executeLine("cp sub/f1 sub/f2").exitCode, 0)
        XCTAssertTrue(fs.exists("sub/f2", relativeTo: engine.cwd))
        XCTAssertEqual(engine.executeLine("mv sub/f2 renamed.txt").exitCode, 0)
        XCTAssertTrue(fs.exists("renamed.txt", relativeTo: engine.cwd))
        XCTAssertEqual(engine.executeLine("rm renamed.txt").exitCode, 0)
        XCTAssertFalse(fs.exists("renamed.txt", relativeTo: engine.cwd))
        XCTAssertEqual(engine.executeLine("rm -r sub").exitCode, 0)
        XCTAssertFalse(fs.exists("sub", relativeTo: engine.cwd))
    }

    func testLsListsContents() {
        engine.executeLine("touch aa bb")
        let result = engine.executeLine("ls")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.visibleOutput.contains("aa"))
        XCTAssertTrue(result.visibleOutput.contains("bb"))
    }

    func testLsHiddenFiltering() {
        engine.executeLine("touch .secret visible")
        let plain = engine.executeLine("ls")
        XCTAssertFalse(plain.visibleOutput.contains(".secret"))
        let all = engine.executeLine("ls -a")
        XCTAssertTrue(all.visibleOutput.contains(".secret"))
    }

    func testRmDirectoryWithoutRecursiveFails() {
        engine.executeLine("mkdir d")
        engine.executeLine("touch d/x")
        let result = engine.executeLine("rm d")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.visibleOutput.contains("not empty"))
    }

    func testRmForIgnoresMissing() {
        XCTAssertEqual(engine.executeLine("rm -f neverexisted.txt").exitCode, 0)
        XCTAssertEqual(engine.executeLine("rm neverexisted.txt").exitCode, 1)
    }

    func testCatConcatenatesFiles() throws {
        try fs.writeText("a.txt", relativeTo: engine.cwd, content: "A\n")
        try fs.writeText("b.txt", relativeTo: engine.cwd, content: "B\n")
        let result = engine.executeLine("cat a.txt b.txt")
        XCTAssertEqual(result.visibleOutput, "A\nB\n")
    }

    func testHeadAndTail() throws {
        try fs.writeText("nums.txt", relativeTo: engine.cwd, content: "1\n2\n3\n4\n5\n")
        XCTAssertEqual(engine.executeLine("head -n 2 nums.txt").visibleOutput, "1\n2\n")
        XCTAssertEqual(engine.executeLine("tail -n 2 nums.txt").visibleOutput, "4\n5\n")
    }

    func testGrepNumbersAndInvert() throws {
        try fs.writeText("log.txt", relativeTo: engine.cwd, content: "alpha\nbeta\nalphabet\n")
        let result = engine.executeLine("grep -n alp log.txt")
        XCTAssertEqual(result.visibleOutput, "1:alpha\n3:alphabet\n")
        XCTAssertEqual(result.exitCode, 0)
        let noMatch = engine.executeLine("grep -v alp log.txt")
        XCTAssertEqual(noMatch.visibleOutput, "beta\n") // no -n flag → no line numbers
        XCTAssertEqual(noMatch.exitCode, 0)
        XCTAssertEqual(engine.executeLine("grep zzz log.txt").exitCode, 1)
    }

    func testWcCounts() throws {
        try fs.writeText("text.txt", relativeTo: engine.cwd, content: "one two\nthree\n")
        let result = engine.executeLine("wc text.txt")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.visibleOutput.contains("14")) // bytes
        XCTAssertTrue(result.visibleOutput.contains("2")) // lines
        XCTAssertTrue(result.visibleOutput.contains("3")) // words
    }

    func testChmodNumericMode() throws {
        engine.executeLine("touch mode_test.txt")
        let result = engine.executeLine("chmod 640 mode_test.txt")
        XCTAssertEqual(result.exitCode, 0)
        let entry = try fs.stat("mode_test.txt", relativeTo: engine.cwd)
        if entry.permissions.hasPrefix("----------") {
            throw XCTSkip("posixPermissions unsupported on this platform")
        }
        XCTAssertEqual(entry.permissions, "-rw-r-----")
    }

    func testChmodSymbolicModeIsHonest() {
        engine.executeLine("touch s.txt")
        let result = engine.executeLine("chmod +x s.txt")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.visibleOutput.contains("not supported"))
    }

    func testCdAndPwdTrackWorkingDirectory() {
        XCTAssertEqual(engine.executeLine("cd Projects").exitCode, 0)
        XCTAssertEqual(engine.cwd, "/home/xtermux/Projects")
        XCTAssertEqual(engine.executeLine("pwd").visibleOutput, "/home/xtermux/Projects\n")
        XCTAssertEqual(engine.executeLine("cd ..").exitCode, 0)
        XCTAssertEqual(engine.cwd, "/home/xtermux")
    }

    func testCdToMissingPathFails() {
        let result = engine.executeLine("cd /no/such/place")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertEqual(engine.cwd, SandboxPath.homePrefix)
    }

    // MARK: sandbox safety

    func testPathTraversalIsRejected() {
        // From /home/xtermux, exactly two ".." land at the sandbox root's
        // /etc/passwd (legit chroot behaviour); a third one must be rejected.
        let inside = engine.executeLine("cat ../../etc/passwd")
        XCTAssertEqual(inside.exitCode, 1) // nonexistent file inside the sandbox
        let result = engine.executeLine("cat ../../../etc/passwd")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.visibleOutput.contains("escapesRoot"))
    }

    func testPathsNeverLeaveSandboxRoot() throws {
        let url = try fs.realURL("/home/xtermux/x.txt", relativeTo: "/")
        XCTAssertTrue(url.path.hasPrefix(fs.baseURL.path))
    }

    // MARK: meta

    func testWhichLocatesBinaries() {
        XCTAssertEqual(engine.executeLine("which ls").visibleOutput, "/bin/ls\n")
        XCTAssertEqual(engine.executeLine("which ls").exitCode, 0)
        XCTAssertEqual(engine.executeLine("which nope").exitCode, 1)
    }

    func testPrintenvValueAndMissing() {
        XCTAssertEqual(engine.executeLine("printenv PATH").visibleOutput, "/bin:/usr/bin\n")
        XCTAssertEqual(engine.executeLine("printenv MISSING_XYZ").exitCode, 1)
    }

    func testHistoryRecorded() {
        engine.executeLine("echo recorded_one")
        XCTAssertEqual(engine.history.entry(fromEnd: 0), "echo recorded_one")
        XCTAssertEqual(engine.executeLine("history").exitCode, 0)
    }

    func testExitSignalsSessionEnd() {
        let result = engine.executeLine("exit 7")
        XCTAssertTrue(result.wantsSessionEnd)
        XCTAssertEqual(engine.lastExitCode, 7)
        XCTAssertEqual(engine.executeLine("echo still-runs").exitCode, 0)
    }

    func testWhoamiUnameIdRunCleanly() {
        XCTAssertEqual(engine.executeLine("whoami").exitCode, 0)
        XCTAssertEqual(engine.executeLine("uname -a").exitCode, 0)
        XCTAssertEqual(engine.executeLine("id").exitCode, 0)
    }
}
