// StreamCommands.swift
// XTermux — stream editors and file comparison, implemented in-process.
//
//   sed   — substitution-oriented stream editor (addresses, p/d/q/s)
//   awk   — pattern-scanning text processor (fields, print/printf, arithmetic)
//   diff  — line-based file comparison (default normal format and -u)
//
// All of it runs inside the app sandbox on the local sandbox filesystem:
// no subprocesses, no privileges, no downloads. Subsets beyond what is
// implemented here fail with honest error messages naming the subset.

import Foundation

// MARK: - sed

private struct SedError: Error { let message: String }

private enum SedSimple {
    case line(Int)
    case last
    case regex(NSRegularExpression)
}

private enum SedAddr {
    case none
    case single(SedSimple)
    case range(SedSimple, SedSimple)
}

private enum SedInstruction {
    case print
    case delete
    case quit
    case substitute(regex: NSRegularExpression, template: String, global: Bool, occurrence: Int?)
}

private struct SedRule {
    let address: SedAddr
    let negate: Bool
    let instruction: SedInstruction
}

private final class SedCursor {
    let chars: [Character]
    var index = 0

    init(_ code: String) { chars = Array(code) }
    var atEnd: Bool { index >= chars.count }
    func peek(offset: Int = 0) -> Character? {
        index + offset < chars.count ? chars[index + offset] : nil
    }
    func advance(_ count: Int = 1) { index += count }
    func skipWhitespace() {
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
    }
}

private enum SedProgram {
    static func parse(_ script: String) throws -> [SedRule] {
        let cursor = SedCursor(script)
        var rules: [SedRule] = []
        while !cursor.atEnd {
            cursor.skipWhitespace()
            if cursor.atEnd { break }
            rules.append(try parseRule(cursor))
            cursor.skipWhitespace()
            if cursor.atEnd { break }
            switch cursor.peek() {
            case ";", "\n", "\r":
                cursor.advance()
            default:
                if let unexpected = cursor.peek() {
                    throw SedError(message: "unexpected text after command: '\(unexpected)'")
                }
            }
        }
        return rules
    }

    private static func parseRule(_ cursor: SedCursor) throws -> SedRule {
        let address = try parseAddress(cursor)
        cursor.skipWhitespace()
        var negate = false
        if cursor.peek() == "!" {
            cursor.advance()
            negate = true
            cursor.skipWhitespace()
        }
        guard let command = cursor.peek() else {
            throw SedError(message: "missing command after address")
        }
        switch command {
        case "p":
            cursor.advance()
            return SedRule(address: address, negate: negate, instruction: .print)
        case "d":
            cursor.advance()
            return SedRule(address: address, negate: negate, instruction: .delete)
        case "q":
            cursor.advance()
            return SedRule(address: address, negate: negate, instruction: .quit)
        case "s":
            let instruction = try parseSubstitution(cursor)
            return SedRule(address: address, negate: negate, instruction: instruction)
        default:
            throw SedError(message: "unsupported command '\(command)' (supported: p d q s)")
        }
    }

    private static func parseAddress(_ cursor: SedCursor) throws -> SedAddr {
        guard let first = try parseSimpleAddress(cursor) else { return .none }
        cursor.skipWhitespace()
        guard cursor.peek() == "," else { return .single(first) }
        cursor.advance()
        cursor.skipWhitespace()
        guard let second = try parseSimpleAddress(cursor) else {
            throw SedError(message: "address range needs an end address")
        }
        return .range(first, second)
    }

    private static func parseSimpleAddress(_ cursor: SedCursor) throws -> SedSimple? {
        guard let character = cursor.peek() else { return nil }
        if character == "$" {
            cursor.advance()
            return .last
        }
        if character.isNumber {
            var digits = ""
            while let c = cursor.peek(), c.isNumber {
                digits.append(c)
                cursor.advance()
            }
            guard let number = Int(digits), number >= 1 else {
                throw SedError(message: "line number must be 1 or greater")
            }
            return .line(number)
        }
        if character == "/" {
            cursor.advance()
            var pattern = ""
            while let c = cursor.peek(), c != "/" {
                if c == "\\", let next = cursor.peek(offset: 1), next == "/" {
                    pattern.append("/")
                    cursor.advance() // consumed '\\'
                    cursor.advance()
                } else {
                    pattern.append(c)
                    cursor.advance()
                }
            }
            guard !cursor.atEnd else { throw SedError(message: "unterminated address regex") }
            cursor.advance() // closing '/'
            let regex = try? NSRegularExpression(pattern: pattern)
            guard let regex else {
                throw SedError(message: "invalid address regex '\(pattern)'")
            }
            return .regex(regex)
        }
        return nil
    }

    private static func parseSubstitution(_ cursor: SedCursor) throws -> SedInstruction {
        cursor.advance() // past 's'
        guard let delimiter = cursor.peek() else {
            throw SedError(message: "substitution needs a pattern")
        }
        guard !delimiter.isLetter, !delimiter.isNumber,
              delimiter != " ", delimiter != "\t", delimiter != "\\", delimiter != "\n" else {
            throw SedError(message: "invalid substitution delimiter")
        }
        cursor.advance()
        let pattern = try readUntilDelimiter(cursor, delimiter)
        guard !cursor.atEnd else { throw SedError(message: "unterminated substitution") }
        cursor.advance()
        let template = try readUntilDelimiter(cursor, delimiter)
        guard !cursor.atEnd else { throw SedError(message: "unterminated substitution") }
        cursor.advance()

        var global = false
        var ignoreCase = false
        var occurrence: Int?
        var occurrenceDigits = ""
        while let flag = cursor.peek(), flag != ";", flag != "\n", flag != "\r", flag != " ", flag != "\t" {
            switch flag {
            case "g": global = true
            case "i": ignoreCase = true
            case "0"..."9": occurrenceDigits.append(flag)
            default:
                throw SedError(message: "unsupported s flag '\(flag)' (supported: g i N)")
            }
            cursor.advance()
        }
        if !occurrenceDigits.isEmpty {
            guard let parsed = Int(occurrenceDigits), parsed >= 1 else {
                throw SedError(message: "occurrence flag must be a positive number")
            }
            occurrence = parsed
        }
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        let regex = try? NSRegularExpression(pattern: pattern, options: options)
        guard let regex else { throw SedError(message: "invalid regex '\(pattern)'") }
        return .substitute(regex: regex, template: template, global: global, occurrence: occurrence)
    }

    private static func readUntilDelimiter(_ cursor: SedCursor, _ delimiter: Character) throws -> String {
        var text = ""
        while let c = cursor.peek(), c != delimiter {
            if c == "\\", let next = cursor.peek(offset: 1), next == delimiter {
                text.append(delimiter)
                cursor.advance()
                cursor.advance()
            } else {
                text.append(c)
                cursor.advance()
            }
        }
        return text
    }
}

struct SedCommand: ShellCommand {
    var name: String { "sed" }
    var aliases: [String] { [] }
    var usage: String { "sed [-n] [-e SCRIPT]… 'PROGRAM' [file]" }
    var help: String { "stream editor subset: addresses N,/re/,$ and ranges with !, commands p d q s; s/// with g i N flags, & and \\1…\\9, any delimiter" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var scripts: [String] = []
        var silent = false
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-e", index + 1 < args.count {
                scripts.append(args[index + 1])
                index += 1
            } else if arg == "-n" {
                silent = true
            } else if arg.hasPrefix("-e"), arg.count > 2 {
                scripts.append(String(arg.dropFirst(2)))
            } else if ShellArgs.isFlag(arg) {
                io.printError("sed: unsupported flag \(arg) (supported: -n -e SCRIPT)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }
        if scripts.isEmpty {
            guard let first = operands.first else {
                io.printError("sed: usage: \(usage)")
                return 2
            }
            scripts = [first]
            operands.removeFirst()
        }

        guard let text = TextLines.source(engine, operands: operands, io: io, label: "sed") else { return 1 }

        let rules: [SedRule]
        do {
            rules = try SedProgram.parse(scripts.joined(separator: "\n"))
        } catch let error as SedError {
            io.printError("sed: \(error.message)")
            return 2
        } catch {
            io.printError("sed: \(String(describing: error))")
            return 2
        }

        let lines = TextLines.list(text)
        var output = ""
        var rangeOpen = false
        var quit = false
        for (position, original) in lines.enumerated() {
            if quit { break }
            var current = original
            var deleted = false
            for rule in rules {
                let applies = addressApplies(rule.address,
                                             currentIndex: position + 1,
                                             total: lines.count,
                                             text: current,
                                             rangeOpen: &rangeOpen)
                let effective = rule.negate ? !applies : applies
                guard effective else { continue }
                switch rule.instruction {
                case .delete:
                    deleted = true
                case .quit:
                    quit = true
                case .print:
                    output += current + "\n"
                case .substitute(let regex, let template, let global, let occurrence):
                    current = SedSubstituter.apply(regex, template: template, global: global, occurrence: occurrence, line: current)
                }
                if deleted || quit { break }
            }
            if deleted {
                if quit { break }
                continue
            }
            if !silent {
                output += current + "\n"
            }
            if quit { break }
        }
        io.writeOutput(output)
        return 0
    }

    private func addressApplies(
        _ address: SedAddr,
        currentIndex: Int,
        total: Int,
        text: String,
        rangeOpen: inout Bool
    ) -> Bool {
        switch address {
        case .none:
            return true
        case .single(let simple):
            return SedMatcher.matches(simple, currentIndex: currentIndex, total: total, text: text)
        case .range(let start, let end):
            if !rangeOpen {
                if SedMatcher.matches(start, currentIndex: currentIndex, total: total, text: text) {
                    rangeOpen = true
                    // A one-line range (start matches the end too) closes here.
                    if SedMatcher.matches(end, currentIndex: currentIndex, total: total, text: text) {
                        rangeOpen = false
                    }
                    return true
                }
                return false
            } else {
                if SedMatcher.matches(end, currentIndex: currentIndex, total: total, text: text) {
                    rangeOpen = false
                }
                return true
            }
        }
    }
}

private enum SedMatcher {
    static func matches(_ simple: SedSimple, currentIndex: Int, total: Int, text: String) -> Bool {
        switch simple {
        case .line(let number):
            return currentIndex == number
        case .last:
            return currentIndex == total
        case .regex(let regex):
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}

private enum SedSubstituter {
    static func apply(
        _ regex: NSRegularExpression,
        template: String,
        global: Bool,
        occurrence: Int?,
        line: String
    ) -> String {
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard !matches.isEmpty else { return line }

        var selected: Set<Int> = []
        if global {
            selected = Set(matches.indices)
        } else if let occurrence = occurrence {
            if occurrence >= 1 && occurrence <= matches.count {
                selected = [occurrence - 1]
            } else {
                return line
            }
        } else {
            selected = [0]
        }

        let units = Array(line.utf16)
        var result: [UTF16.CodeUnit] = []
        var cursor = 0
        for (position, match) in matches.enumerated() {
            let lower = match.range.location
            let upper = match.range.location + match.range.length
            guard lower >= cursor, upper <= units.count else { continue }
            result.append(contentsOf: units[cursor..<lower])
            if selected.contains(position) {
                result.append(contentsOf: Array(expand(template, match: match, units: units).utf16))
            } else {
                result.append(contentsOf: units[lower..<upper])
            }
            cursor = upper
        }
        result.append(contentsOf: units[cursor...])
        return String(decoding: result, as: UTF16.self)
    }

    private static func segment(_ units: [UTF16.CodeUnit], _ range: NSRange) -> String {
        let lower = range.location
        let upper = range.location + range.length
        guard range.location != NSNotFound, lower >= 0, upper <= units.count, upper >= lower else { return "" }
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    private static func expand(_ template: String, match: NSTextCheckingResult, units: [UTF16.CodeUnit]) -> String {
        let characters = Array(template)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next.isNumber {
                    let digit = next.wholeNumberValue ?? 0
                    if digit == 0 {
                        output += segment(units, match.range)
                    } else if digit >= 1 && digit <= 9 {
                        output += segment(units, match.range(at: digit))
                    }
                    index += 2
                    continue
                }
                switch next {
                case "&": output += "&"
                case "\\": output += "\\"
                case "n": output += "\n"
                case "t": output += "\t"
                case "r": output += "\r"
                default:
                    output.append(character)
                    output.append(next)
                }
                index += 2
            } else if character == "&" {
                output += segment(units, match.range)
                index += 1
            } else {
                output.append(character)
                index += 1
            }
        }
        return output
    }
}

// MARK: - awk

private struct AwkError: Error { let message: String }

private enum AwkVal {
    case num(Double)
    case str(String)

    static func number(_ value: Double) -> AwkVal { .num(value) }

    var asNumber: Double {
        switch self {
        case .num(let value): return value
        case .str(let text):
            if let direct = Double(text) { return direct }
            return AwkVal.numberPrefix(text)
        }
    }

    var asString: String {
        switch self {
        case .num(let value):
            if value == value.rounded() && abs(value) < 1e15 {
                return String(Int64(value))
            }
            return String(value)
        case .str(let text): return text
        }
    }

    var truthy: Bool {
        switch self {
        case .num(let value): return value != 0
        case .str(let text): return !text.isEmpty && text != "0"
        }
    }

    var isNumericString: Bool {
        switch self {
        case .num: return true
        case .str(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && Double(trimmed) != nil
        }
    }

    private static func numberPrefix(_ text: String) -> Double {
        let characters = Array(text)
        var index = 0
        var prefix = ""
        if index < characters.count, characters[index] == "-" || characters[index] == "+" {
            prefix.append(characters[index])
            index += 1
        }
        var dots = 0
        while index < characters.count {
            let c = characters[index]
            if c.isNumber { prefix.append(c); index += 1 }
            else if c == ".", dots == 0 { dots = 1; prefix.append(c); index += 1 }
            else { break }
        }
        return Double(prefix) ?? 0
    }
}

private indirect enum AwkExpr {
    case number(Double)
    case string(String)
    case field(AwkExpr)
    case variable(String)
    case binary(Character, AwkExpr, AwkExpr)      // + - * / %
    case comparison(String, AwkExpr, AwkExpr)     // == != < <= > >=
    case concatenate([AwkExpr])
    case negate(AwkExpr)
    case call(String, [AwkExpr])
}

private enum AwkTarget {
    case variable(String)
    case field(AwkExpr)
}

private enum AwkStatement {
    case print([AwkExpr])
    case printf(String, [AwkExpr])
    case assign(AwkTarget, AwkExpr)
    case bare(AwkExpr)
}

private enum AwkPattern {
    case everything
    case begin
    case end
    case regex(NSRegularExpression)
    case expression(AwkExpr)
}

private struct AwkRule {
    let pattern: AwkPattern
    let statements: [AwkStatement]
}

private final class AwkCursor {
    let chars: [Character]
    var index = 0

    init(_ code: String) { chars = Array(code) }
    var atEnd: Bool { index >= chars.count }
    func peek(offset: Int = 0) -> Character? {
        index + offset < chars.count ? chars[index + offset] : nil
    }
    func advance(_ count: Int = 1) { index += count }
    func skipBlanks() {
        while let c = peek(), c == " " || c == "\t" { advance() }
    }
    func skipWhitespace() {
        while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
    }
    func atWord(_ word: String) -> Bool {
        let letters = Array(word)
        guard index + letters.count <= chars.count else { return false }
        for (offset, letter) in letters.enumerated() where chars[index + offset] != letter { return false }
        let after = index + letters.count
        if after < chars.count {
            let next = chars[after]
            if next.isLetter || next.isNumber || next == "_" { return false }
        }
        return true
    }
    func consumeWord(_ word: String) {
        index += word.count
    }
}

private enum AwkParser {
    static let functions = ["length", "substr", "toupper", "tolower", "index"]

    static func parse(_ program: String) throws -> [AwkRule] {
        let cursor = AwkCursor(program)
        var rules: [AwkRule] = []
        while true {
            cursor.skipWhitespace()
            if cursor.atEnd { break }
            let pattern = try parsePattern(cursor)
            cursor.skipWhitespace()
            guard cursor.peek() == "{" else {
                throw AwkError(message: "expected '{' after pattern")
            }
            let body = try captureBody(cursor)
            let statements = try parseStatements(body)
            rules.append(AwkRule(pattern: pattern, statements: statements))
        }
        return rules
    }

    private static func parsePattern(_ cursor: AwkCursor) throws -> AwkPattern {
        if cursor.atWord("BEGIN") {
            cursor.consumeWord("BEGIN")
            return .begin
        }
        if cursor.atWord("END") {
            cursor.consumeWord("END")
            return .end
        }
        if cursor.peek() == "/" {
            cursor.advance()
            var pattern = ""
            while let c = cursor.peek(), c != "/" {
                if c == "\\", let next = cursor.peek(offset: 1) {
                    pattern.append(c)
                    pattern.append(next)
                    cursor.advance()
                    cursor.advance()
                } else {
                    pattern.append(c)
                    cursor.advance()
                }
            }
            guard !cursor.atEnd else { throw AwkError(message: "unterminated pattern regex") }
            cursor.advance()
            let regex = try? NSRegularExpression(pattern: pattern)
            guard let regex else { throw AwkError(message: "invalid pattern regex '\(pattern)'") }
            return .regex(regex)
        }
        if cursor.peek() == "{" { return .everything }
        // Expression pattern such as `$3 > 10` or `NF == 2`.
        let expression = try parseExpression(cursor)
        return .expression(expression)
    }

    private static func captureBody(_ cursor: AwkCursor) throws -> String {
        cursor.advance() // past '{'
        var depth = 1
        var body = ""
        while let c = cursor.peek() {
            if c == "\"" {
                body.append(c)
                cursor.advance()
                while let inner = cursor.peek() {
                    body.append(inner)
                    cursor.advance()
                    if inner == "\\", cursor.peek() != nil {
                        body.append(cursor.peek()!)
                        cursor.advance()
                    } else if inner == "\"" {
                        break
                    }
                }
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" {
                depth -= 1
                if depth == 0 {
                    cursor.advance()
                    return body
                }
            }
            body.append(c)
            cursor.advance()
        }
        throw AwkError(message: "unbalanced braces in program body")
    }

    private static func parseStatements(_ body: String) throws -> [AwkStatement] {
        let cursor = AwkCursor(body)
        var statements: [AwkStatement] = []
        while true {
            cursor.skipWhitespace()
            if cursor.atEnd { break }
            if cursor.peek() == ";" { cursor.advance(); continue }
            let statement = try parseStatement(cursor)
            statements.append(statement)
            cursor.skipWhitespace()
        }
        return statements
    }

    private static func parseStatement(_ cursor: AwkCursor) throws -> AwkStatement {
        if cursor.atWord("print") {
            cursor.consumeWord("print")
            cursor.skipBlanks()
            var expressions: [AwkExpr] = []
            while cursor.peek() != nil, cursor.peek() != ";", cursor.peek() != "}" {
                if !expressions.isEmpty {
                    guard cursor.peek() == "," else { break }
                    cursor.advance()
                }
                let expression = try parseExpression(cursor)
                expressions.append(expression)
                cursor.skipBlanks()
            }
            return .print(expressions)
        }
        if cursor.atWord("printf") {
            cursor.consumeWord("printf")
            cursor.skipBlanks()
            guard cursor.peek() == "\"" else {
                throw AwkError(message: "printf needs a format string")
            }
            let format = try parseStringLiteral(cursor)
            cursor.skipBlanks()
            var arguments: [AwkExpr] = []
            if cursor.peek() == "," {
                cursor.advance()
                while cursor.peek() != nil, cursor.peek() != ";", cursor.peek() != "}" {
                    if !arguments.isEmpty {
                        guard cursor.peek() == "," else { break }
                        cursor.advance()
                    }
                    let expression = try parseExpression(cursor)
                    arguments.append(expression)
                    cursor.skipBlanks()
                }
            }
            return .printf(format, arguments)
        }

        // Assignment (`name = expr` or `$N = expr`) with rollback, so that a
        // lookalike statement still parses as a bare expression.
        let savedIndex = cursor.index
        do {
            return try parseAssignment(cursor)
        } catch {
            cursor.index = savedIndex
        }

        let expression = try parseExpression(cursor)
        return .bare(expression)
    }

    private static func parseAssignment(_ cursor: AwkCursor) throws -> AwkStatement {
        let target: AwkTarget
        if cursor.peek() == "$" {
            cursor.advance()
            let expression = try parseFactor(cursor)
            cursor.skipBlanks()
            guard cursor.peek() == "=", cursor.peek(offset: 1) != "=" else {
                throw AwkError(message: "not an assignment")
            }
            target = .field(expression)
        } else {
            var name = ""
            while let c = cursor.peek(), c.isLetter || c.isNumber || c == "_" {
                name.append(c)
                cursor.advance()
            }
            cursor.skipBlanks()
            guard !name.isEmpty, cursor.peek() == "=", cursor.peek(offset: 1) != "=" else {
                throw AwkError(message: "not an assignment")
            }
            target = .variable(name)
        }
        cursor.advance() // past '='
        cursor.skipBlanks()
        let value = try parseExpression(cursor)
        return .assign(target, value)
    }

    // Expression grammar -------------------------------------------------

    private static func parseExpression(_ cursor: AwkCursor) throws -> AwkExpr {
        var left = try parseAdditive(cursor)
        cursor.skipBlanks()
        while let op = peekComparison(cursor) {
            cursor.advance(op.count)
            let right = try parseAdditive(cursor)
            left = .comparison(op, left, right)
            cursor.skipBlanks()
        }
        return left
    }

    private static func peekComparison(_ cursor: AwkCursor) -> String? {
        // Two-character operators first.
        if let a = cursor.peek(), let b = cursor.peek(offset: 1) {
            let pair = String(a) + String(b)
            if pair == "==" || pair == "!=" || pair == "<=" || pair == ">=" { return pair }
        }
        if let a = cursor.peek(), "<>".contains(a) { return String(a) }
        return nil
    }

    private static func parseAdditive(_ cursor: AwkCursor) throws -> AwkExpr {
        var left = try parseMultiplicative(cursor)
        cursor.skipBlanks()
        while let op = cursor.peek(), op == "+" || op == "-" {
            cursor.advance()
            let right = try parseMultiplicative(cursor)
            left = .binary(op, left, right)
            cursor.skipBlanks()
        }
        return left
    }

    private static func parseMultiplicative(_ cursor: AwkCursor) throws -> AwkExpr {
        var left = try parseUnary(cursor)
        cursor.skipBlanks()
        while let op = cursor.peek(), op == "*" || op == "/" || op == "%" {
            cursor.advance()
            let right = try parseUnary(cursor)
            left = .binary(op, left, right)
            cursor.skipBlanks()
        }
        return left
    }

    private static func parseUnary(_ cursor: AwkCursor) throws -> AwkExpr {
        cursor.skipBlanks()
        if cursor.peek() == "-" {
            cursor.advance()
            let inner = try parseUnary(cursor)
            return .negate(inner)
        }
        if cursor.peek() == "+" {
            cursor.advance()
            return try parseUnary(cursor)
        }
        return try parseConcatenate(cursor)
    }

    private static func startsFactor(_ character: Character) -> Bool {
        character.isNumber || character == "\"" || character == "$" ||
        character.isLetter || character == "_" || character == "("
    }

    private static func parseConcatenate(_ cursor: AwkCursor) throws -> AwkExpr {
        var factors: [AwkExpr] = [try parseFactor(cursor)]
        cursor.skipBlanks()
        while let c = cursor.peek(), startsFactor(c) {
            factors.append(try parseFactor(cursor))
            cursor.skipBlanks()
        }
        if factors.count == 1 { return factors[0] }
        return .concatenate(factors)
    }

    static func parseFactor(_ cursor: AwkCursor) throws -> AwkExpr {
        guard let character = cursor.peek() else {
            throw AwkError(message: "unexpected end of expression")
        }
        if character.isNumber {
            var text = ""
            while let c = cursor.peek(), c.isNumber || c == "." {
                text.append(c)
                cursor.advance()
            }
            guard let number = Double(text) else {
                throw AwkError(message: "invalid number '\(text)'")
            }
            return .number(number)
        }
        if character == "\"" {
            return .string(try parseStringLiteral(cursor))
        }
        if character == "$" {
            cursor.advance()
            let inner = try parseFactor(cursor)
            return .field(inner)
        }
        if character == "(" {
            cursor.advance()
            let inner = try parseExpression(cursor)
            cursor.skipBlanks()
            guard cursor.peek() == ")" else { throw AwkError(message: "missing ')'") }
            cursor.advance()
            return inner
        }
        if character.isLetter || character == "_" {
            var name = ""
            while let c = cursor.peek(), c.isLetter || c.isNumber || c == "_" {
                name.append(c)
                cursor.advance()
            }
            cursor.skipBlanks()
            if cursor.peek() == "(" {
                cursor.advance()
                var arguments: [AwkExpr] = []
                cursor.skipBlanks()
                if cursor.peek() != ")" {
                    while true {
                        arguments.append(try parseExpression(cursor))
                        cursor.skipBlanks()
                        if cursor.peek() == "," {
                            cursor.advance()
                            continue
                        }
                        break
                    }
                }
                guard cursor.peek() == ")" else { throw AwkError(message: "missing ')' after \(name)(…)") }
                cursor.advance()
                guard functions.contains(name) else {
                    throw AwkError(message: "unsupported function '\(name)' (supported: \(functions.joined(separator: ", ")))")
                }
                return .call(name, arguments)
            }
            return .variable(name)
        }
        throw AwkError(message: "unexpected character '\(character)' in expression")
    }

    private static func parseStringLiteral(_ cursor: AwkCursor) throws -> String {
        guard cursor.peek() == "\"" else { throw AwkError(message: "string literal expected") }
        cursor.advance()
        var text = ""
        while let c = cursor.peek() {
            if c == "\"" {
                cursor.advance()
                return text
            }
            if c == "\\", let next = cursor.peek(offset: 1) {
                switch next {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "r": text.append("\r")
                case "\"": text.append("\"")
                case "\\": text.append("\\")
                case "/": text.append("/")
                default:
                    text.append("\\")
                    text.append(next)
                }
                cursor.advance()
                cursor.advance()
            } else {
                text.append(c)
                cursor.advance()
            }
        }
        throw AwkError(message: "unterminated string literal")
    }

}

private enum AwkRuntimeHelpers {
    /// Splits one record for field access (FS semantics: " " for whitespace
    /// runs, "" per character, another single character literal).
    static func splitFields(_ line: String, fs: String) -> [String] {
        if fs == " " {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
        if fs.isEmpty {
            return line.map(String.init)
        }
        return line.components(separatedBy: fs)
    }
}

struct AwkCommand: ShellCommand {
    var name: String { "awk" }
    var aliases: [String] { [] }
    var usage: String { "awk [-F SEP] [-v VAR=VAL]… 'PROGRAM' [file…]" }
    var help: String { "text processor subset: /re/, BEGIN, END and `$N OP num` patterns; print/printf, vars, fields $0…$NF, NR, NF, arithmetic, concat, length/substr/toupper/tolower/index" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var fieldSeparator = " "
        var preAssignments: [(name: String, value: String)] = []
        var operands: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-F", index + 1 < args.count {
                fieldSeparator = args[index + 1]
                index += 1
            } else if arg.hasPrefix("-F"), arg.count > 2 {
                fieldSeparator = String(arg.dropFirst(2))
            } else if arg == "-v", index + 1 < args.count {
                guard let equals = args[index + 1].firstIndex(of: "=") else {
                    io.printError("awk: -v needs VAR=VALUE")
                    return 2
                }
                let name = String(args[index + 1][..<equals])
                let value = String(args[index + 1][args[index + 1].index(after: equals)...])
                guard !name.isEmpty else {
                    io.printError("awk: -v needs VAR=VALUE")
                    return 2
                }
                preAssignments.append((name, value))
                index += 1
            } else if ShellArgs.isFlag(arg) {
                io.printError("awk: unsupported flag \(arg) (supported: -F SEP -v VAR=VALUE)")
                return 2
            } else {
                operands.append(arg)
            }
            index += 1
        }
        guard let program = operands.first else {
            io.printError("awk: usage: \(usage)")
            return 2
        }
        guard fieldSeparator == " " || fieldSeparator.isEmpty || fieldSeparator.count == 1 else {
            io.printError("awk: unsupported FS '\(fieldSeparator)' (single character, \" \" or \"\")")
            return 2
        }

        let rules: [AwkRule]
        do {
            rules = try AwkParser.parse(program)
        } catch let error as AwkError {
            io.printError("awk: \(error.message)")
            return 2
        } catch {
            io.printError("awk: \(String(describing: error))")
            return 2
        }

        var source = ""
        if operands.count > 1 {
            for file in operands.dropFirst() {
                do {
                    source += try engine.fs.readText(file, relativeTo: engine.cwd).text
                } catch {
                    let description = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
                    io.printError("awk: can't open file '\(file)': \(description)")
                    return 1
                }
            }
        } else {
            source = io.stdin
        }

        var context = AwkContext()
        context.vars["FS"] = .str(fieldSeparator)
        context.vars["OFS"] = .str(" ")
        for assignment in preAssignments {
            context.vars[assignment.name] = .str(assignment.value)
        }

        var output = ""
        do {
            for rule in rules {
                if case .begin = rule.pattern {
                    try execute(rule.statements, context: &context, output: &output)
                }
            }
            for (lineNumber, line) in TextLines.list(source).enumerated() {
                context.line = line
                context.number = lineNumber + 1
                let separator = context.vars["FS"]?.asString ?? " "
                let fields = AwkRuntimeHelpers.splitFields(line, fs: separator)
                context.fields = fields
                for rule in rules {
                    let matched: Bool
                    switch rule.pattern {
                    case .begin, .end:
                        continue
                    case .everything:
                        matched = true
                    case .regex(let regex):
                        matched = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                    case .expression(let expression):
                        let value = try evaluate(expression, context: &context)
                        matched = value.truthy
                    }
                    if matched {
                        try execute(rule.statements, context: &context, output: &output)
                    }
                }
            }
            for rule in rules {
                if case .end = rule.pattern {
                    try execute(rule.statements, context: &context, output: &output)
                }
            }
        } catch let error as AwkError {
            io.printError("awk: \(error.message)")
            return 2
        } catch {
            io.printError("awk: \(String(describing: error))")
            return 2
        }
        io.writeOutput(output)
        return 0
    }

    private struct AwkContext {
        var vars: [String: AwkVal] = [:]
        var fields: [String] = []
        var line = ""
        var number = 0
    }

    private func execute(
        _ statements: [AwkStatement],
        context: inout AwkContext,
        output: inout String
    ) throws {
        for statement in statements {
            switch statement {
            case .print(let expressions):
                var list = expressions
                var values: [String] = []
                if list.isEmpty { list = [.field(.number(0))] }
                for expression in list {
                    let value = try evaluate(expression, context: &context)
                    values.append(value.asString)
                }
                let separator = context.vars["OFS"]?.asString ?? " "
                output += values.joined(separator: separator) + "\n"
            case .printf(let format, let expressions):
                var arguments: [String] = []
                for expression in expressions {
                    let value = try evaluate(expression, context: &context)
                    arguments.append(value.asString)
                }
                let rendered = ShellFormat.render(format, arguments: arguments[...])
                output += rendered.text
                if let error = rendered.error {
                    throw AwkError(message: error)
                }
            case .assign(let target, let expression):
                let value = try evaluate(expression, context: &context)
                switch target {
                case .variable(let name):
                    context.vars[name] = value
                case .field(let indexExpression):
                    let indexValue = try evaluate(indexExpression, context: &context)
                    let position = Int(indexValue.asNumber)
                    guard position >= 0 else {
                        throw AwkError(message: "field index must not be negative")
                    }
                    if position == 0 {
                        context.line = value.asString
                    } else {
                        while context.fields.count < position {
                            context.fields.append("")
                        }
                        context.fields[position - 1] = value.asString
                        let separator = context.vars["FS"]?.asString ?? " "
                        context.line = context.fields.joined(separator: separator == " " ? " " : separator)
                    }
                }
            case .bare(let expression):
                _ = try evaluate(expression, context: &context)
            }
        }
    }

    private func evaluate(_ expression: AwkExpr, context: inout AwkContext) throws -> AwkVal {
        switch expression {
        case .number(let value):
            return .num(value)
        case .string(let text):
            return .str(text)
        case .variable(let name):
            switch name {
            case "NR": return .num(Double(context.number))
            case "NF": return .num(Double(context.fields.count))
            case "FS": return context.vars["FS"] ?? .str(" ")
            case "OFS": return context.vars["OFS"] ?? .str(" ")
            default: return context.vars[name] ?? .str("")
            }
        case .field(let indexExpression):
            let indexValue = try evaluate(indexExpression, context: &context)
            let position = Int(indexValue.asNumber)
            guard position >= 0 else {
                throw AwkError(message: "field index must not be negative")
            }
            if position == 0 { return .str(context.line) }
            if position > context.fields.count { return .str("") }
            return .str(context.fields[position - 1])
        case .binary(let op, let left, let right):
            let leftValue = try evaluate(left, context: &context)
            let rightValue = try evaluate(right, context: &context)
            switch op {
            case "+": return .num(leftValue.asNumber + rightValue.asNumber)
            case "-": return .num(leftValue.asNumber - rightValue.asNumber)
            case "*": return .num(leftValue.asNumber * rightValue.asNumber)
            case "/":
                guard rightValue.asNumber != 0 else { throw AwkError(message: "division by zero") }
                return .num(leftValue.asNumber / rightValue.asNumber)
            case "%":
                guard rightValue.asNumber != 0 else { throw AwkError(message: "division by zero") }
                return .num(leftValue.asNumber.truncatingRemainder(dividingBy: rightValue.asNumber))
            default:
                throw AwkError(message: "unsupported operator '\(op)'")
            }
        case .comparison(let op, let left, let right):
            let leftValue = try evaluate(left, context: &context)
            let rightValue = try evaluate(right, context: &context)
            let result: Bool
            if leftValue.isNumericString && rightValue.isNumericString {
                let a = leftValue.asNumber
                let b = rightValue.asNumber
                switch op {
                case "==": result = a == b
                case "!=": result = a != b
                case "<": result = a < b
                case "<=": result = a <= b
                case ">": result = a > b
                case ">=": result = a >= b
                default: throw AwkError(message: "unsupported operator '\(op)'")
                }
            } else {
                let a = leftValue.asString
                let b = rightValue.asString
                switch op {
                case "==": result = a == b
                case "!=": result = a != b
                case "<": result = a < b
                case "<=": result = a <= b
                case ">": result = a > b
                case ">=": result = a >= b
                default: throw AwkError(message: "unsupported operator '\(op)'")
                }
            }
            return result ? .num(1) : .num(0)
        case .concatenate(let terms):
            var text = ""
            for term in terms {
                let value = try evaluate(term, context: &context)
                text += value.asString
            }
            return .str(text)
        case .negate(let inner):
            let value = try evaluate(inner, context: &context)
            return .num(-value.asNumber)
        case .call(let name, let arguments):
            var evaluated: [AwkVal] = []
            for argument in arguments {
                evaluated.append(try evaluate(argument, context: &context))
            }
            switch (name, evaluated.count) {
            case ("length", 0):
                return .num(Double(context.line.count))
            case ("length", 1):
                return .num(Double(evaluated[0].asString.count))
            case ("substr", 2), ("substr", 3):
                let text = evaluated[0].asString
                let start = max(1, Int(evaluated[1].asNumber))
                let length = evaluated.count >= 3 ? Int(evaluated[2].asNumber) : text.count
                if length < 0 || start > text.count { return .str("") }
                let characters = Array(text)
                let lower = start - 1
                let upper = min(lower + length, characters.count)
                guard upper >= lower else { return .str("") }
                return .str(String(characters[lower..<upper]))
            case ("toupper", 1):
                return .str(evaluated[0].asString.uppercased())
            case ("tolower", 1):
                return .str(evaluated[0].asString.lowercased())
            case ("index", 2):
                let haystack = evaluated[0].asString
                if let range = haystack.range(of: evaluated[1].asString) {
                    return .num(Double(haystack.distance(from: haystack.startIndex, to: range.lowerBound) + 1))
                }
                return .num(0)
            default:
                throw AwkError(message: "unsupported call '\(name)' with \(evaluated.count) arguments")
            }
        }
    }
}

// MARK: - diff

enum DiffEngine {
    private enum Event {
        case equal(a: Int, b: Int)
        case delete(a: Int)
        case add(b: Int)
    }

    struct Block {
        enum Kind { case change, equal }
        var kind: Kind
        var aStart: Int       // 1-based start line in file A (or boundary position)
        var bStart: Int
        var aLines: [String]  // deletions / context line
        var bLines: [String]  // additions / context line
    }

    static func blocks(_ a: [String], _ b: [String]) throws -> [Block] {
        let n = a.count
        let m = b.count
        // LCS dynamic table (suffix lengths). 2001×2001 UInt16 ≈ 8 MB.
        guard n <= 2000, m <= 2000 else {
            throw FileSystemErrorKind(message: "input too large (limit: 2000 lines per file)")
        }
        var table = Array(repeating: Array(repeating: UInt16(0), count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] &+ 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var events: [Event] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                events.append(.equal(a: i, b: j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                events.append(.delete(a: i))
                i += 1
            } else {
                events.append(.add(b: j))
                j += 1
            }
        }
        while i < n { events.append(.delete(a: i)); i += 1 }
        while j < m { events.append(.add(b: j)); j += 1 }

        var blocks: [Block] = []
        var equalRun: [(a: Int, b: Int)] = []
        var deletions: [Int] = []
        var additions: [Int] = []
        var aConsumed = 0
        var bConsumed = 0
        func flushChange() {
            if deletions.isEmpty && additions.isEmpty { return }
            if deletions.isEmpty {
                // Pure addition after a-line aConsumed.
                let bStart = (additions.min() ?? 0) + 1
                blocks.append(Block(kind: .change, aStart: aConsumed, bStart: bStart,
                                    aLines: [], bLines: additions.map { b[$0] }))
            } else if additions.isEmpty {
                // Pure deletion before b-line bConsumed.
                let aStart = (deletions.min() ?? 0) + 1
                blocks.append(Block(kind: .change, aStart: aStart, bStart: bConsumed,
                                    aLines: deletions.map { a[$0] }, bLines: []))
            } else {
                let aStart = (deletions.min() ?? 0) + 1
                let bStart = (additions.min() ?? 0) + 1
                blocks.append(Block(kind: .change, aStart: aStart, bStart: bStart,
                                    aLines: deletions.map { a[$0] },
                                    bLines: additions.map { b[$0] }))
            }
            deletions.removeAll()
            additions.removeAll()
        }
        func flushEqual() {
            guard !equalRun.isEmpty else { return }
            blocks.append(Block(kind: .equal,
                                aStart: equalRun[0].a + 1,
                                bStart: equalRun[0].b + 1,
                                aLines: equalRun.map { a[$0.a] },
                                bLines: equalRun.map { b[$0.b] }))
            equalRun.removeAll()
        }

        for event in events {
            switch event {
            case .equal(let aIndex, let bIndex):
                flushChange()
                equalRun.append((aIndex, bIndex))
                aConsumed += 1
                bConsumed += 1
            case .delete(let aIndex):
                flushEqual()
                deletions.append(aIndex)
                aConsumed += 1
            case .add(let bIndex):
                flushEqual()
                additions.append(bIndex)
                bConsumed += 1
            }
        }
        flushChange()
        flushEqual()
        return blocks
    }
}

private struct FileSystemErrorKind: Error { let message: String }

struct DiffCommand: ShellCommand {
    var name: String { "diff" }
    var aliases: [String] { [] }
    var usage: String { "diff [-u] FILE1 FILE2" }
    var help: String { "compare two text files (default normal format; -u unified with 3 context lines; max 2000 lines per file)" }

    func run(_ engine: ShellEngine, args: [String], io: CommandIO) -> Int {
        var unified = false
        let operands = args.filter { arg in
            if arg == "-u" || arg == "--unified" {
                unified = true
                return false
            }
            return !ShellArgs.isFlag(arg)
        }
        guard operands.count == 2 else {
            io.printError("diff: usage: \(usage)")
            return 2
        }
        for operand in operands where engine.fs.isDirectory(operand, relativeTo: engine.cwd) {
            io.printError("diff: directories are not supported in the sandbox diff (\(operand))")
            return 2
        }

        func read(_ operand: String) throws -> [String] {
            let file = try engine.fs.readText(operand, relativeTo: engine.cwd)
            if file.truncated {
                throw FileSystemErrorKind(message: "file too large to read (limit 8 MB): \(operand)")
            }
            return TextLines.list(file.text)
        }

        let first: [String]
        let second: [String]
        do {
            first = try read(operands[0])
            second = try read(operands[1])
        } catch let error as FileSystemErrorKind {
            io.printError("diff: \(error.message)")
            return 2
        } catch {
            let description = (error as? FileSystemError)?.errorDescription ?? String(describing: error)
            io.printError("diff: \(description)")
            return 2
        }

        let blocks: [DiffEngine.Block]
        do {
            blocks = try DiffEngine.blocks(first, second)
        } catch {
            io.printError("diff: \(String(describing: error))")
            return 2
        }

        let different = blocks.contains { $0.kind == .change }
        guard different else { return 0 }

        var output = ""
        if unified {
            output += "--- \(operands[0])\n"
            output += "+++ \(operands[1])\n"
            output += Self.unified(blocks, context: 3)
        } else {
            output += Self.normal(blocks)
        }
        io.writeOutput(output)
        return 1
    }

    /// Default `a/c/d` normal-format output.
    static func normal(_ blocks: [DiffEngine.Block]) -> String {
        var output = ""
        func rangeText(_ start: Int, _ count: Int) -> String {
            count <= 1 ? String(start) : "\(start),\(start + count - 1)"
        }
        for block in blocks where block.kind == .change {
            switch (block.aLines.isEmpty, block.bLines.isEmpty) {
            case (true, false): // pure addition after a-line aStart
                output += "\(block.aStart)a\(rangeText(block.bStart, block.bLines.count))\n"
                output += block.bLines.map { "> \($0)\n" }.joined()
            case (false, true): // pure deletion before b-line bStart
                output += "\(rangeText(block.aStart, block.aLines.count))d\(block.bStart)\n"
                output += block.aLines.map { "< \($0)\n" }.joined()
            default:            // change block
                output += "\(rangeText(block.aStart, block.aLines.count))c\(rangeText(block.bStart, block.bLines.count))\n"
                output += block.aLines.map { "< \($0)\n" }.joined()
                output += "---\n"
                output += block.bLines.map { "> \($0)\n" }.joined()
            }
        }
        return output
    }

    /// Unified format with `context` surrounding lines per hunk.
    static func unified(_ blocks: [DiffEngine.Block], context: Int) -> String {
        var output = ""
        var hunkIndices: [Range<Int>] = []
        var position = 0
        while position < blocks.count {
            if blocks[position].kind == .change {
                // Walk back through context (merging neighboring changes).
                var start = position
                var countBack = 0
                while start > 0 {
                    let candidate = blocks[start - 1]
                    let lines = candidate.aLines.count
                    if candidate.kind == .change { start -= 1; continue }
                    if countBack + lines > context { break }
                    countBack += lines
                    start -= 1
                }
                var end = position
                var countForward = 0
                while end < blocks.count - 1 {
                    let candidate = blocks[end + 1]
                    let lines = candidate.aLines.count
                    if candidate.kind == .change { end += 1; continue }
                    if countForward + lines > context { break }
                    countForward += lines
                    end += 1
                }
                hunkIndices.append(start..<max(end + 1, start + 1))
                position = end + 1
            } else {
                position += 1
            }
        }

        for hunk in hunkIndices {
            var lines: [String] = []
            var aStart = 1
            var bStart = 1
            var first = true
            var aCount = 0
            var bCount = 0
            for index in hunk {
                let block = blocks[index]
                if first {
                    first = false
                    aStart = block.aStart
                    bStart = block.bStart
                }
                if block.kind == .equal {
                    for line in block.aLines {
                        lines.append(" " + line)
                        aCount += 1
                        bCount += 1
                    }
                } else {
                    for line in block.aLines {
                        lines.append("-" + line)
                        aCount += 1
                    }
                    for line in block.bLines {
                        lines.append("+" + line)
                        bCount += 1
                    }
                }
            }
            func header(_ start: Int, _ count: Int) -> Int {
                count == 0 ? max(0, start - 1) : start
            }
            output += "@@ -\(header(aStart, aCount)),\(aCount) +\(header(bStart, bCount)),\(bCount) @@\n"
            for line in lines { output += line + "\n" }
        }
        return output
    }
}
