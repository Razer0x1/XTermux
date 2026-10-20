// CommandScanner.swift
// XTermux -- Unix-style command line tokenizer.
//
// Pure Swift, no platform dependencies. Splits a raw input line into a
// pipeline of commands (separated by `|`), each with its optional
// redirection specs (`>`, `>>`, `<`), honouring quoting rules:
//
//   - single quotes: literal, no escapes
//   - double quotes: literal except \` \" \\ \$ \n \t escapes
//   - backslash (outside quotes): escapes the next character
//   - `|` outside quotes separates pipeline stages
//   - after `>` / `>>` / `<` the next completed token becomes that
//     redirection's target; further tokens return to normal argv
//     (POSIX `ls > a b` keeps `b` as an argument).

import Foundation

enum ScannerError: Error, Equatable {
    case unterminatedQuote(position: Int)
    case danglingRedirect(position: Int)
}

struct RedirectSpec: Equatable {
    enum Kind: String, Equatable {
        case overwrite = ">"
        case append = ">>"
        case infile = "<"
    }

    var kind: Kind
    var argument: String
}

struct ScannedCommand: Equatable {
    /// argv[0] is the command name.
    var argv: [String] = []
    var redirects: [RedirectSpec] = []

    var name: String? { argv.first }
    var arguments: [String] { Array(argv.dropFirst()) }
}

enum CommandScanner {
    /// Splits a line into pipeline stages. Empty stages are skipped so
    /// "a | | b" becomes two commands rather than an error (honest parser).
    static func scan(_ input: String) throws -> [ScannedCommand] {
        var stages: [ScannedCommand] = []
        var current = ScannedCommand()

        var inSingle = false
        var inDouble = false
        var escaped = false

        // Token accumulation. After a redirect operator, the next flushed
        // token becomes that operator's target instead of an argument.
        var token = ""
        var hadToken = false
        var pendingKind: RedirectSpec.Kind? = nil

        func flush() {
            guard hadToken else { return }
            let value = token
            token = ""
            hadToken = false
            if let kind = pendingKind {
                current.redirects.append(RedirectSpec(kind: kind, argument: value))
                pendingKind = nil
            } else {
                current.argv.append(value)
            }
        }

        var index = input.startIndex
        var position = 0

        while index < input.endIndex {
            let char = input[index]
            defer {
                index = input.index(after: index)
                position += 1
            }

            if inSingle {
                if char == "'" {
                    inSingle = false
                } else {
                    token.append(char)
                }
                hadToken = true
                continue
            }

            if inDouble {
                if escaped {
                    switch char {
                    case "n": token.append("\n")
                    case "t": token.append("\t")
                    case "r": token.append("\r")
                    case "\"", "\\", "`", "$": token.append(char)
                    default:
                        token.append("\\")
                        token.append(char)
                    }
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inDouble = false
                } else {
                    token.append(char)
                }
                hadToken = true
                continue
            }

            if escaped {
                token.append(char)
                escaped = false
                hadToken = true
                continue
            }

            switch char {
            case "\\":
                escaped = true

            case "'":
                inSingle = true
                hadToken = true

            case "\"":
                inDouble = true
                hadToken = true

            case " ", "\t", "\n":
                flush()

            case "|":
                flush()
                // A redirect operator without its target: "echo > | cat".
                if pendingKind != nil {
                    throw ScannerError.danglingRedirect(position: position)
                }
                stages.append(current)
                current = ScannedCommand()

            case ">":
                flush()
                // Consecutive operators: "echo > > f" is a syntax error.
                if pendingKind != nil {
                    throw ScannerError.danglingRedirect(position: position)
                }
                let nextIndex = input.index(after: index)
                if nextIndex < input.endIndex, input[nextIndex] == ">" {
                    // The loop's defer advances past the second '>' itself.
                    pendingKind = .append
                    index = nextIndex
                } else {
                    pendingKind = .overwrite
                }

            case "<":
                flush()
                if pendingKind != nil {
                    throw ScannerError.danglingRedirect(position: position)
                }
                pendingKind = .infile

            default:
                token.append(char)
                hadToken = true
            }
        }

        if inSingle || inDouble || escaped {
            throw ScannerError.unterminatedQuote(position: position)
        }

        // Flush any trailing token, or the target of a trailing operator
        // ("echo > log.txt" at end of line).
        flush()
        if pendingKind != nil {
            throw ScannerError.danglingRedirect(position: position)
        }

        // Quoted-but-empty targets ("> ''") are rejected like bash -- ambiguous.
        for redirect in current.redirects {
            if redirect.argument.isEmpty {
                throw ScannerError.danglingRedirect(position: position)
            }
        }

        if !current.argv.isEmpty || !current.redirects.isEmpty {
            stages.append(current)
        }

        guard !stages.isEmpty else { return [] }
        return stages
    }
}
