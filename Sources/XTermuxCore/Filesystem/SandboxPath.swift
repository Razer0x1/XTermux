// SandboxPath.swift
// XTermux — chroot-style virtual filesystem path handling.
//
// The app's iOS sandbox "Documents" directory is the root of the virtual
// filesystem. All paths are virtual and always relative to that root:
//
//   /            → Documents/
//   /home/xtermux → Documents/  (the user's home inside the sandbox)
//   ~            → /home/xtermux
//
// `..` components are resolved textually; a path that would escape the
// sandbox root is rejected. This mirrors chroot semantics: no path from the
// terminal layer can ever leave the app container.

import Foundation

public enum SandboxPathError: Error, Equatable {
    case escapesRoot
    case emptyPath
}

public enum SandboxPath {
    /// The virtual absolute path of the home directory.
    public static let homePrefix = "/home/xtermux"

    /// Resolves `~` and returns a clean absolute virtual path.
    public static func expanded(_ path: String) -> String {
        if path == "~" || path.hasPrefix("~/") {
            return homePrefix + String(path.dropFirst(1))
        }
        return path
    }

    /// Normalizes `path` interpreted relative to `cwd`.
    /// Returns an absolute virtual path with no `..` or `.` components and
    /// no duplicate separators. Trailing slashes are removed.
    public static func resolve(_ path: String, relativeTo cwd: String = homePrefix) throws -> String {
        var candidate = expanded(path)
        if !candidate.hasPrefix("/") {
            let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
            guard !base.isEmpty else { throw SandboxPathError.emptyPath }
            candidate = base + "/" + candidate
        }

        var components: [String] = []
        for component in candidate.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if components.isEmpty {
                    throw SandboxPathError.escapesRoot
                }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }

        return "/" + components.joined(separator: "/")
    }

    /// Converts an absolute virtual path to a human display form (`~` shortening).
    public static func display(_ path: String) -> String {
        if path == homePrefix { return "~" }
        if path.hasPrefix(homePrefix + "/") {
            return "~" + path.dropFirst(homePrefix.count)
        }
        return path
    }

    /// Maps a normalized absolute virtual path onto the real sandbox URL.
    /// The virtual root `/` maps onto `base` itself.
    public static func realURL(forVirtual virtual: String, base: URL) throws -> URL {
        let normalized = virtual.isEmpty ? "/" : virtual
        guard normalized.hasPrefix("/") else { throw SandboxPathError.escapesRoot }
        if normalized == "/" {
            return base
        }
        return base.appendingPathComponent(String(normalized.dropFirst()), isDirectory: false)
    }

    /// True when the entry name should be hidden by default on `ls`.
    public static func isHidden(_ name: String) -> Bool {
        name.hasPrefix(".")
    }
}
