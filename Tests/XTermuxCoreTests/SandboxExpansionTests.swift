// SandboxExpansionTests.swift — pkg module gating, sed/awk/diff, and the
// extra utility commands added with the sandbox expansion.

import XCTest
@testable import XTermuxCore

final class SandboxExpansionTests: XCTestCase {
    private var dir: URL!
    private var fs: FileSystemService!
    private var engine: ShellEngine!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtermux-sandbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fs = FileSystemService(baseURL: dir)
        fs.bootstrapDefaultLayout()
        engine = ShellEngine(fs: fs, history: HistoryStore(baseURL: dir))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: pkg — honest module management

    func testPkgListShowsAllModulesByDefault() {
        let result = engine.executeLine("pkg list")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.visibleOutput.contains("sed"))
        XCTAssertTrue(result.visibleOutput.contains("gawk"))
        XCTAssertTrue(result.visibleOutput.contains("diffutils"))
        XCTAssertTrue(result.visibleOutput.contains("file-utils"))
        XCTAssertTrue(result.visibleOutput.contains("shell-utils"))
        XCTAssertTrue(result.visibleOutput.contains("installed"))
        XCTAssertFalse(result.visibleOutput.contains("not installed"))
    }

    func testPkgRemoveGatesCommandWithHonestError() throws {
        try fs.writeText("f.txt", relativeTo: engine.cwd, content: "one\nthree\n")
        XCTAssertEqual(engine.executeLine("diff f.txt f.txt").exitCode, 0)
        let removed = engine.executeLine("pkg remove diffutils")
        XCTAssertEqual(removed.exitCode, 0)
        XCTAssertTrue(removed.visibleOutput.contains("Removing diffutils"))
        let gated = engine.executeLine("diff f.txt f.txt")
        XCTAssertEqual(gated.exitCode, 127)
        XCTAssertTrue(gated.visibleOutput.contains("pkg 'diffutils' is not installed"))
        XCTAssertTrue(gated.visibleOutput.contains("pkg install diffutils"))
    }

    func testPkgInstallRestoresGatedCommand() {
        XCTAssertEqual(engine.executeLine("pkg remove gawk").exitCode, 0)
        // A second removal is an honest no-op, not an error.
        let stray = engine.executeLine("pkg remove gawk")
        XCTAssertEqual(stray.exitCode, 0)
        XCTAssertTrue(stray.visibleOutput.contains("pkg: gawk is not installed"))
        let gated = engine.executeLine("echo 'hi' | awk '{print $0}'")
        XCTAssertEqual(gated.exitCode, 127)
        XCTAssertEqual(engine.executeLine("pkg install gawk").exitCode, 0)
        let restored = engine.executeLine("echo 'hi' | awk '{print $0}'")
        XCTAssertEqual(restored.exitCode, 0)
        XCTAssertEqual(restored.visibleOutput, "hi\n")
    }

    func testPkgStatePersistsAcrossEngines() {
        XCTAssertEqual(engine.executeLine("pkg remove shell-utils").exitCode, 0)
        let second = ShellEngine(fs: fs, history: HistoryStore(baseURL: dir))
        let info = second.executeLine("pkg info shell-utils")
        XCTAssertEqual(info.exitCode, 0)
        XCTAssertTrue(info.visibleOutput.contains("Status:  not installed"))
        let gated = second.executeLine("seq 1 3")
        XCTAssertEqual(gated.exitCode, 127)
        XCTAssertTrue(gated.visibleOutput.contains("pkg 'shell-utils' is not installed"))
    }

    func testCorruptPkgStateFallsBackToDefaultAll() throws {
        try fs.writeText(PkgDB.storagePath, relativeTo: "/", content: "…not json {", createParents: true)
        let second = ShellEngine(fs: fs, history: HistoryStore(baseURL: dir))
        let info = second.executeLine("pkg info gawk")
        XCTAssertTrue(info.visibleOutput.contains("Status:  installed"))
        // sed executes (usage error, exit 2) rather than being gated (127).
        XCTAssertEqual(second.executeLine("sed").exitCode, 2)
    }

    func testPkgUnknownModuleAndSubcommandFailHonestly() {
        let missing = engine.executeLine("pkg remove nonexistent")
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.visibleOutput.contains("pkg: module not found: nonexistent"))
        let bad = engine.executeLine("pkg flurb")
        XCTAssertEqual(bad.exitCode, 2)
        XCTAssertTrue(bad.visibleOutput.contains("unknown subcommand"))
    }

    func testHelpMarksUninstalledModules() {
        XCTAssertEqual(engine.executeLine("pkg remove diffutils").exitCode, 0)
        let topic = engine.executeLine("help diff")
        XCTAssertTrue(topic.visibleOutput.contains("not installed — run: pkg install diffutils"))
        let list = engine.executeLine("help")
        XCTAssertTrue(list.visibleOutput.contains("pkg install diffutils"))
    }

    // MARK: sed

    func testSedSubstitutionBasicAndGlobal() {
        XCTAssertEqual(engine.executeLine("echo 'hello world' | sed 's/world/there/'").visibleOutput,
                       "hello there\n")
        XCTAssertEqual(engine.executeLine("echo 'cool tool' | sed 's/o/0/g'").visibleOutput,
                       "c00l t00l\n")
    }

    func testSedNthOccurrenceAndCaseInsensitive() {
        XCTAssertEqual(engine.executeLine("echo 'one one one' | sed 's/one/two/2'").visibleOutput,
                       "one two one\n")
        XCTAssertEqual(engine.executeLine("echo 'MiXeD' | sed 's/mixed/lowercase/i'").visibleOutput,
                       "lowercase\n")
    }

    func testSedBackreferencesAndAmpersand() {
        XCTAssertEqual(engine.executeLine("echo 'john smith' | sed 's/(\\w+) (\\w+)/\\2 \\1/'").visibleOutput,
                       "smith john\n")
        XCTAssertEqual(engine.executeLine("echo 'ab' | sed 's/b/[&]/'").visibleOutput,
                       "a[b]\n")
        // \& escapes the ampersand so it stays a literal.
        XCTAssertEqual(engine.executeLine("echo 'ab' | sed 's/b/\\&/'").visibleOutput,
                       "a&\n")
    }

    func testSedAlternateDelimiter() {
        XCTAssertEqual(engine.executeLine("echo 'a/b' | sed 's,/,_,g'").visibleOutput,
                       "a_b\n")
    }

    func testSedDashNWithExplicitPrint() throws {
        try fs.writeText("abc.txt", relativeTo: engine.cwd, content: "a\nb\nc\n")
        XCTAssertEqual(engine.executeLine("sed -n '2p' abc.txt").visibleOutput, "b\n")
        XCTAssertEqual(engine.executeLine("sed -n '/b/p' abc.txt").visibleOutput, "b\n")
    }

    func testSedDeleteByAddressAndRange() throws {
        try fs.writeText("five.txt", relativeTo: engine.cwd, content: "1\n2\n3\n4\n5\n")
        XCTAssertEqual(engine.executeLine("sed '2d' five.txt").visibleOutput, "1\n3\n4\n5\n")
        XCTAssertEqual(engine.executeLine("sed '2,4d' five.txt").visibleOutput, "1\n5\n")
        XCTAssertEqual(engine.executeLine("sed '3d;$d' five.txt").visibleOutput, "1\n2\n4\n")
    }

    func testSedNegatedAddress() throws {
        try fs.writeText("three.txt", relativeTo: engine.cwd, content: "a\nb\nc\n")
        XCTAssertEqual(engine.executeLine("sed '2!d' three.txt").visibleOutput, "b\n")
        XCTAssertEqual(engine.executeLine("sed '$!d' three.txt").visibleOutput, "c\n")
    }

    func testSedUnsupportedCommandAndBadRegexAreHonest() {
        let unknown = engine.executeLine("echo 'x' | sed 'y/ab/xy/'")
        XCTAssertEqual(unknown.exitCode, 2)
        XCTAssertTrue(unknown.visibleOutput.contains("unsupported command 'y'"))
        let invalid = engine.executeLine("echo 'x' | sed 's/(/x/'")
        XCTAssertEqual(invalid.exitCode, 2)
        XCTAssertTrue(invalid.visibleOutput.contains("invalid regex"))
    }

    // MARK: awk

    func testAwkFieldsAndNF() throws {
        try fs.writeText("f.txt", relativeTo: engine.cwd, content: "alpha beta gamma\ndelta\n")
        XCTAssertEqual(engine.executeLine("awk '{print $1}' f.txt").visibleOutput, "alpha\ndelta\n")
        XCTAssertEqual(engine.executeLine("awk '{print NF}' f.txt").visibleOutput, "3\n1\n")
    }

    func testAwkNRAndConcatenation() throws {
        try fs.writeText("f.txt", relativeTo: engine.cwd, content: "alpha\nbeta\n")
        XCTAssertEqual(engine.executeLine("awk '{print NR \":\" $0}' f.txt").visibleOutput,
                       "1:alpha\n2:beta\n")
    }

    func testAwkArithmeticAndConcat() {
        XCTAssertEqual(engine.executeLine("echo '4 5' | awk '{print $1 + $2}'").visibleOutput, "9\n")
        XCTAssertEqual(engine.executeLine("echo 'hi' | awk '{print \"the \" $0 \"!\"}'").visibleOutput,
                       "the hi!\n")
    }

    func testAwkRegexPatternFilter() throws {
        try fs.writeText("words.txt", relativeTo: engine.cwd, content: "apple\nbanana\napricot\n")
        XCTAssertEqual(engine.executeLine("awk '/ap/ {print}' words.txt").visibleOutput,
                       "apple\napricot\n")
    }

    func testAwkComparisonPattern() throws {
        try fs.writeText("nums.txt", relativeTo: engine.cwd, content: "1\n2\n3\n")
        XCTAssertEqual(engine.executeLine("awk '$1 > 1 {print $1}' nums.txt").visibleOutput,
                       "2\n3\n")
    }

    func testAwkBeginAndEnd() throws {
        try fs.writeText("f.txt", relativeTo: engine.cwd, content: "a\nb\n")
        XCTAssertEqual(engine.executeLine("awk 'BEGIN{print \"start\"} END{print \"end \" NR}' f.txt").visibleOutput,
                       "start\nend 2\n")
    }

    func testAwkFieldSeparatorFlag() {
        XCTAssertEqual(engine.executeLine("echo 'a,b,c' | awk -F, '{print $2}'").visibleOutput, "b\n")
    }

    func testAwkAssignmentAndFunctions() {
        XCTAssertEqual(engine.executeLine("echo 'hi' | awk '{x = $0; print toupper(x)}'").visibleOutput,
                       "HI\n")
        XCTAssertEqual(engine.executeLine("echo 'hello' | awk '{print substr($0, 2, 3)}'").visibleOutput,
                       "ell\n")
        XCTAssertEqual(engine.executeLine("echo 'hello' | awk '{print index($0, \"l\")}'").visibleOutput,
                       "3\n")
    }

    func testAwkPrintfFormats() {
        XCTAssertEqual(engine.executeLine("echo 'x' | awk '{printf \"%s=%d\\n\", $0, 42}'").visibleOutput,
                       "x=42\n")
        XCTAssertEqual(engine.executeLine("awk 'BEGIN{printf \"%.2f\\n\", 3.141}'").visibleOutput,
                       "3.14\n")
    }

    func testAwkUnsupportedFunctionIsHonest() {
        let result = engine.executeLine("echo 'x' | awk '{print system(\"ls\")}'")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.visibleOutput.contains("unsupported function"))
    }

    // MARK: diff

    func testDiffIdenticalFilesAreQuiet() throws {
        try fs.writeText("a.txt", relativeTo: engine.cwd, content: "one\ntwo\n")
        let result = engine.executeLine("diff a.txt a.txt")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.visibleOutput, "")
    }

    func testDiffNormalFormats() throws {
        try fs.writeText("o.txt", relativeTo: engine.cwd, content: "one\nthree\n")
        try fs.writeText("n.txt", relativeTo: engine.cwd, content: "one\ntwo\nthree\n")
        let added = engine.executeLine("diff o.txt n.txt")
        XCTAssertEqual(added.exitCode, 1)
        XCTAssertEqual(added.visibleOutput, "1a2\n> two\n")
        let deleted = engine.executeLine("diff n.txt o.txt")
        XCTAssertEqual(deleted.exitCode, 1)
        XCTAssertEqual(deleted.visibleOutput, "2d1\n< two\n")
        try fs.writeText("m.txt", relativeTo: engine.cwd, content: "x\ny\n")
        try fs.writeText("z.txt", relativeTo: engine.cwd, content: "x\nz\n")
        let changed = engine.executeLine("diff m.txt z.txt")
        XCTAssertEqual(changed.exitCode, 1)
        XCTAssertEqual(changed.visibleOutput, "2c2\n< y\n---\n> z\n")
    }

    func testDiffUnifiedFormat() throws {
        try fs.writeText("u1.txt", relativeTo: engine.cwd, content: "one\ntwo\nx\nthree\n")
        try fs.writeText("u2.txt", relativeTo: engine.cwd, content: "one\ntwo\nthree\n")
        let result = engine.executeLine("diff -u u1.txt u2.txt")
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.visibleOutput.contains("--- u1.txt"))
        XCTAssertTrue(result.visibleOutput.contains("+++ u2.txt"))
        XCTAssertTrue(result.visibleOutput.contains("@@ -1,4 +1,3 @@"))
        XCTAssertTrue(result.visibleOutput.contains("-x"))
        XCTAssertTrue(result.visibleOutput.contains(" three"))
        try fs.writeText("p1.txt", relativeTo: engine.cwd, content: "one\n")
        try fs.writeText("p2.txt", relativeTo: engine.cwd, content: "one\ntwo\n")
        let added = engine.executeLine("diff -u p1.txt p2.txt")
        XCTAssertTrue(added.visibleOutput.contains("@@ -1,1 +1,2 @@"))
        XCTAssertTrue(added.visibleOutput.contains("+two"))
    }

    func testDiffHonestSizeAndDirectoryLimits() throws {
        let big = String(repeating: "x\n", count: 2001)
        try fs.writeText("bigA.txt", relativeTo: engine.cwd, content: big)
        try fs.writeText("bigB.txt", relativeTo: engine.cwd, content: big)
        let large = engine.executeLine("diff bigA.txt bigB.txt")
        XCTAssertEqual(large.exitCode, 2)
        XCTAssertTrue(large.visibleOutput.contains("too large"))
        // "." relative to the working directory is the home directory itself.
        let directories = engine.executeLine("diff . .")
        XCTAssertEqual(directories.exitCode, 2)
        XCTAssertTrue(directories.visibleOutput.contains("directories are not supported"))
    }

    // MARK: seq / printf / uniq

    func testSeqVariants() {
        XCTAssertEqual(engine.executeLine("seq 3").visibleOutput, "1\n2\n3\n")
        XCTAssertEqual(engine.executeLine("seq 2 4").visibleOutput, "2\n3\n4\n")
        XCTAssertEqual(engine.executeLine("seq 3 -1 1").visibleOutput, "3\n2\n1\n")
        XCTAssertEqual(engine.executeLine("seq -s , 1 3").visibleOutput, "1,2,3\n")
        XCTAssertEqual(engine.executeLine("seq -w 8 10").visibleOutput, "08\n09\n10\n")
        XCTAssertNotEqual(engine.executeLine("seq nope").exitCode, 0)
    }

    func testPrintfRendersAndEscapes() {
        XCTAssertEqual(engine.executeLine("printf '%s=%04d ok\\n' x 42").visibleOutput, "x=0042 ok\n")
        XCTAssertEqual(engine.executeLine("printf 'a%sb%%c\\n' X").visibleOutput, "aXb%c\n")
        let rejected = engine.executeLine("printf '%y' x")
        XCTAssertEqual(rejected.exitCode, 1)
        XCTAssertTrue(rejected.visibleOutput.contains("unsupported specification"))
    }

    func testUniqModes() throws {
        try fs.writeText("u.txt", relativeTo: engine.cwd, content: "a\nA\nb\nb\nc\n")
        let counted = engine.executeLine("uniq -i -c u.txt")
        XCTAssertTrue(counted.visibleOutput.contains("      2 a"))
        XCTAssertTrue(counted.visibleOutput.contains("      2 b"))
        XCTAssertTrue(counted.visibleOutput.contains("      1 c"))
        XCTAssertEqual(engine.executeLine("uniq -d u.txt").visibleOutput, "b\n")
        XCTAssertEqual(engine.executeLine("uniq -u u.txt").visibleOutput, "a\nA\nc\n")
    }

    func testTacRevNl() throws {
        try fs.writeText("t.txt", relativeTo: engine.cwd, content: "one\ntwo\n")
        XCTAssertEqual(engine.executeLine("tac t.txt").visibleOutput, "two\none\n")
        try fs.writeText("r.txt", relativeTo: engine.cwd, content: "abc\nde\n")
        XCTAssertEqual(engine.executeLine("rev r.txt").visibleOutput, "cba\ned\n")
        try fs.writeText("n.txt", relativeTo: engine.cwd, content: "x\n\nz\n")
        XCTAssertEqual(engine.executeLine("nl n.txt").visibleOutput, "     1\tx\n\n     2\tz\n")
        let all = engine.executeLine("nl -b a n.txt")
        XCTAssertTrue(all.visibleOutput.contains("     2\t"))
        XCTAssertTrue(all.visibleOutput.contains("     3\tz"))
    }

    // MARK: stat / du / df / tree

    func testStatReportsSandboxMetadata() throws {
        try fs.writeText("s.txt", relativeTo: engine.cwd, content: "abc\n")
        let ok = engine.executeLine("stat s.txt")
        XCTAssertEqual(ok.exitCode, 0)
        XCTAssertTrue(ok.visibleOutput.contains("File: "))
        XCTAssertTrue(ok.visibleOutput.contains("Size: 4 bytes"))
        XCTAssertTrue(ok.visibleOutput.contains("regular file"))
        XCTAssertTrue(ok.visibleOutput.contains("Mode:"))
        let missing = engine.executeLine("stat nope.txt")
        XCTAssertEqual(missing.exitCode, 1)
        XCTAssertTrue(missing.visibleOutput.contains("cannot stat"))
    }

    func testDuReportsDirectoryTotals() throws {
        try fs.createDirectory("d", relativeTo: engine.cwd)
        try fs.createDirectory("d/sub", relativeTo: engine.cwd)
        try fs.writeText("d/f", relativeTo: engine.cwd, content: "12345")
        try fs.writeText("d/sub/g", relativeTo: engine.cwd, content: "01")
        let du = engine.executeLine("du d")
        XCTAssertEqual(du.exitCode, 0)
        XCTAssertTrue(du.visibleOutput.contains("2  /home/xtermux/d/sub"))
        XCTAssertTrue(du.visibleOutput.contains("7  /home/xtermux/d"))
        let summary = engine.executeLine("du -s d")
        XCTAssertFalse(summary.visibleOutput.contains("d/sub"))
        XCTAssertTrue(summary.visibleOutput.contains("7  /home/xtermux/d"))
    }

    func testDfReportsRealVolumeFacts() {
        let df = engine.executeLine("df")
        XCTAssertEqual(df.exitCode, 0)
        XCTAssertTrue(df.visibleOutput.contains("Filesystem"))
        XCTAssertTrue(df.visibleOutput.contains("Use%"))
        XCTAssertTrue(df.visibleOutput.contains("xtermux (sandbox)"))
    }

    func testTreeShowsStructureAndCounts() throws {
        try fs.createDirectory("d", relativeTo: engine.cwd)
        try fs.createDirectory("d/sub", relativeTo: engine.cwd)
        try fs.writeText("d/f", relativeTo: engine.cwd, content: "1")
        try fs.writeText("d/sub/g", relativeTo: engine.cwd, content: "1")
        let full = engine.executeLine("tree d")
        XCTAssertEqual(full.exitCode, 0)
        XCTAssertTrue(full.visibleOutput.contains("sub"))
        XCTAssertTrue(full.visibleOutput.contains("g"))
        XCTAssertTrue(full.visibleOutput.contains("1 directory, 2 files"))
        let shallow = engine.executeLine("tree -L 1 d")
        XCTAssertTrue(shallow.visibleOutput.contains("sub"))
        XCTAssertFalse(shallow.visibleOutput.contains("g"))
        XCTAssertTrue(shallow.visibleOutput.contains("1 directory, 1 file"))
    }

    // MARK: basename / dirname

    func testBasenameAndDirnameVariants() {
        XCTAssertEqual(engine.executeLine("basename /a/b/c.txt").visibleOutput, "c.txt\n")
        XCTAssertEqual(engine.executeLine("basename /a/b/c.txt .txt").visibleOutput, "c\n")
        XCTAssertEqual(engine.executeLine("basename -s .x a.x b.x").visibleOutput, "a\nb\n")
        XCTAssertEqual(engine.executeLine("dirname /a/b/c").visibleOutput, "/a/b\n")
        XCTAssertEqual(engine.executeLine("dirname /a").visibleOutput, "/\n")
        XCTAssertEqual(engine.executeLine("dirname a").visibleOutput, ".\n")
        XCTAssertEqual(engine.executeLine("dirname /").visibleOutput, "/\n")
    }

    // MARK: expr

    func testExprArithmeticPrecedenceAndStrings() {
        XCTAssertEqual(engine.executeLine("expr 1 + 2 * 3").visibleOutput, "7\n")
        XCTAssertEqual(engine.executeLine("expr length hello").visibleOutput, "5\n")
        XCTAssertEqual(engine.executeLine("expr substr hello 2 3").visibleOutput, "ell\n")
        let divide = engine.executeLine("expr 1 / 0")
        XCTAssertEqual(divide.exitCode, 2)
        XCTAssertTrue(divide.visibleOutput.contains("division by zero"))
        XCTAssertEqual(engine.executeLine("expr 1 - 1").exitCode, 1)
        XCTAssertEqual(engine.executeLine("expr 1 - 1").visibleOutput, "0\n")
    }

    // MARK: alias / test

    func testAliasesExpandUnaliasAndStayQuoteAware() {
        XCTAssertEqual(engine.executeLine("alias ll=\"ls\"").exitCode, 0)
        XCTAssertEqual(engine.executeLine("ll").exitCode, 0)
        XCTAssertTrue(engine.executeLine("alias").visibleOutput.contains("alias ll='ls'"))

        // Aliases can name other aliases (bounded depth).
        XCTAssertEqual(engine.executeLine("alias a1='echo one'").exitCode, 0)
        XCTAssertEqual(engine.executeLine("alias a2='a1 two'").exitCode, 0)
        XCTAssertEqual(engine.executeLine("a2").visibleOutput, "one two\n")

        // A quoted head is never expanded, exactly like the shell would behave.
        let quoted = engine.executeLine("'ll'")
        XCTAssertEqual(quoted.exitCode, 127)
        XCTAssertTrue(quoted.visibleOutput.contains("command not found: ll"))

        XCTAssertEqual(engine.executeLine("alias nothere").exitCode, 1)
        XCTAssertEqual(engine.executeLine("unalias ll").exitCode, 0)
        XCTAssertEqual(engine.executeLine("ll").exitCode, 127)
    }

    func testTestComparisonsFileChecksAndGrouping() throws {
        try fs.writeText("t.txt", relativeTo: engine.cwd, content: "hi\n")
        XCTAssertEqual(engine.executeLine("test 1 -eq 1").exitCode, 0)
        XCTAssertEqual(engine.executeLine("test 1 -lt 2").exitCode, 0)
        XCTAssertEqual(engine.executeLine("test 2 -le 1").exitCode, 1)
        XCTAssertEqual(engine.executeLine("test a = a").exitCode, 0)
        XCTAssertEqual(engine.executeLine("test a != b").exitCode, 0)
        XCTAssertEqual(engine.executeLine("test -z \"$EMPTY\"").exitCode, 0)
        XCTAssertEqual(engine.executeLine("test -n \"$EMPTY\"").exitCode, 1)
        XCTAssertEqual(engine.executeLine("test -f t.txt").exitCode, 0)
        XCTAssertEqual(engine.executeLine("test -d t.txt").exitCode, 1)
        XCTAssertEqual(engine.executeLine("test ! 1 -eq 1").exitCode, 1)
        XCTAssertEqual(engine.executeLine("test ( 1 -eq 1 )").exitCode, 0)
        XCTAssertEqual(engine.executeLine("test ( 1 -eq 1 ) -a ( 2 -le 1 )").exitCode, 1)
        XCTAssertEqual(engine.executeLine("test 1 -eq 1 -a 2 -eq 2").exitCode, 0)
        XCTAssertEqual(engine.executeLine("test 1 -eq 2 -o 2 -eq 2").exitCode, 0)

        // Invoked as `[`, the closing bracket must be present.
        XCTAssertEqual(engine.executeLine("[ 1 -eq 1 ]").exitCode, 0)
        let unclosed = engine.executeLine("[ 1 -eq 1")
        XCTAssertEqual(unclosed.exitCode, 2)
        XCTAssertTrue(unclosed.visibleOutput.contains("]"))
    }

    // MARK: xargs

    func testXargsDefaultEchoAndBatching() {
        XCTAssertEqual(engine.executeLine("printf 'a b\\nc d\\n' | xargs").visibleOutput,
                       "a b c d\n")
        XCTAssertEqual(engine.executeLine("printf '1\\n2\\n3\\n' | xargs -n 1").visibleOutput,
                       "1\n2\n3\n")
        let missing = engine.executeLine("echo z | xargs definitelynotacmd")
        XCTAssertEqual(missing.exitCode, 127)
        XCTAssertTrue(missing.visibleOutput.contains("command not found"))
    }

    // MARK: kern — honest kernel information access

    func testKernInfoExplainsXNU() {
        let result = engine.executeLine("kern info")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.visibleOutput.contains("XNU"))
        XCTAssertTrue(result.visibleOutput.contains("hybrid"))
        XCTAssertTrue(result.visibleOutput.contains("Mach"))
        XCTAssertTrue(result.visibleOutput.contains("BSD"))
        XCTAssertTrue(result.visibleOutput.contains("I/O Kit"))
    }

    func testKernCompareListsLinuxAndDarwin() {
        let result = engine.executeLine("kern compare")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.visibleOutput.contains("Linux"))
        XCTAssertTrue(result.visibleOutput.contains("Darwin"))
        XCTAssertTrue(result.visibleOutput.contains("monolithic"))
        XCTAssertTrue(result.visibleOutput.contains("I/O Kit"))
    }

    func testKernExploreGivesExactSteps() {
        let result = engine.executeLine("kern explore")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.visibleOutput.contains("git clone"))
        XCTAssertTrue(result.visibleOutput.contains("apple-oss-distributions/xnu"))
        XCTAssertTrue(result.visibleOutput.contains("ls"))
    }

    func testKernUnknownTopicExitsTwo() {
        let result = engine.executeLine("kern frobnicate")
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.visibleOutput.contains("kern: unknown topic"))
        XCTAssertTrue(result.visibleOutput.contains("explore"))
    }

    func testKernAliasKernelWorksAndHelpListsTopics() {
        XCTAssertEqual(engine.executeLine("kernel info").exitCode, 0)
        let help = engine.executeLine("kern help")
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertTrue(help.visibleOutput.contains("ostype"))
    }

    func testKernSysctlTopicsNeverInventValues() {
        // On the Linux test host there is no sysctl; the command must say so
        // honestly rather than printing a made-up value.
        for topic in ["ostype", "osrelease", "version", "arch"] {
            let result = engine.executeLine("kern \(topic)")
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertTrue(result.visibleOutput.contains("unavailable"), topic)
        }
    }

    func testUnameStaysHonestUnderRebrand() {
        let result = engine.executeLine("uname -a")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.visibleOutput.contains("Darwin/XNU"))
        XCTAssertTrue(result.visibleOutput.contains("userspace shell"))
    }
}
