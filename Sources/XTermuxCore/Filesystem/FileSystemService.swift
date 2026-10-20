// FileSystemService.swift
// XTermux — all real filesystem operations under the app sandbox.
//
// iOS note: this uses the standard sandboxed FileManager API available to
// stock App Store apps. It can neverbrowse arbitrary protected iOS
// directories; `SandboxPath` rejects anything outside the configured root.

import Foundation

public struct FSEntry: Identifiable, Equatable, Sendable {
    public var id: String { virtualPath }
    public let virtualPath: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int?
    public let modified: Date?
    public let isHidden: Bool
    public let permissions: String
}

public enum FileSystemError: LocalizedError, Equatable {
    case notFound(String)
    case notADirectory(String)
    case alreadyExists(String)
    case isDirectory(String)
    case notEmpty(String)
    case permissionDenied
    case parentMissing(String)
    case directoryTooLargeForPreview
    case unsupportedSymlink

    public var errorDescription: String? {
        switch self {
        case .notFound(let p): return "no such file or directory: \(p)"
        case .notADirectory(let p): return "not a directory: \(p)"
        case .alreadyExists(let p): return "already exists: \(p)"
        case .isDirectory(let p): return "is a directory: \(p)"
        case .notEmpty(let p): return "directory not empty: \(p)"
        case .permissionDenied: return "permission denied"
        case .parentMissing(let p): return "parent directory does not exist: \(p)"
        case .directoryTooLargeForPreview: return "file too large to preview (limit 8 MB)"
        case .unsupportedSymlink: return "symbolic links are not supported inside the sandbox"
        }
    }
}

public final class FileSystemService: @unchecked Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private var fm: FileManager { FileManager.default }

    // MARK: path mapping

    /// Converts a virtual path (optionally relative to `cwd`) to a real URL.
    public func realURL(_ virtual: String, relativeTo cwd: String) throws -> URL {
        try SandboxPath.realURL(
            forVirtual: try SandboxPath.resolve(virtual, relativeTo: cwd),
            base: baseURL
        )
    }

    public func virtualPath(of url: URL) -> String {
        let normalized = url.standardizedFileURL.path
        let base = baseURL.standardizedFileURL.path
        let suffix = normalized.hasPrefix(base) ? String(normalized.dropFirst(base.count)) : ""
        let relative = "/" + suffix.drop(while: { $0 == "/" })
        return relative == "//" ? "/" : relative
    }

    // MARK: queries

    public func exists(_ virtual: String, relativeTo cwd: String) -> Bool {
        guard let url = try? realURL(virtual, relativeTo: cwd) else { return false }
        return fm.fileExists(atPath: url.path)
    }

    public func isDirectory(_ virtual: String, relativeTo cwd: String) -> Bool {
        guard let url = try? realURL(virtual, relativeTo: cwd) else { return false }
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func stat(_ virtual: String, relativeTo cwd: String) throws -> FSEntry {
        let resolved = try SandboxPath.resolve(virtual, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        guard fm.fileExists(atPath: url.path) else { throw FileSystemError.notFound(resolved) }
        return entry(for: url, resolvedPath: resolved)
    }

    private func entry(for url: URL, resolvedPath: String) -> FSEntry {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let name = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        let size = attributes?[.size] as? NSNumber
        let modified = attributes?[.modificationDate] as? Date
        let posix = attributes?[.posixPermissions] as? NSNumber
        let permissionText = permissionString(isDirectory: isDir.boolValue, posix: posix?.intValue)
        return FSEntry(
            virtualPath: url == baseURL ? "/" : resolvedPath,
            name: url == baseURL ? "/" : name,
            isDirectory: exists && isDir.boolValue,
            size: (exists && !isDir.boolValue) ? size?.intValue : nil,
            modified: modified,
            isHidden: SandboxPath.isHidden(name),
            permissions: permissionText
        )
    }

    private func permissionString(isDirectory: Bool, posix: Int?) -> String {
        guard let posix else { return isDirectory ? "d---------" : "----------" }
        var result = isDirectory ? "d" : "-"
        func rwx(bit: Int) -> String {
            let r = (posix >> bit) & 4 == 4 ? "r" : "-"
            let w = (posix >> bit) & 2 == 2 ? "w" : "-"
            let x = (posix >> bit) & 1 == 1 ? "x" : "-"
            return r + w + x
        }
        // user, group, other
        result += rwx(bit: 6) + rwx(bit: 3) + rwx(bit: 0)
        return result
    }

    public func listEntries(
        _ directory: String,
        relativeTo cwd: String = SandboxPath.homePrefix,
        includeHidden: Bool = false
    ) throws -> [FSEntry] {
        let resolvedDir = try SandboxPath.resolve(directory, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolvedDir, base: baseURL)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(resolvedDir)
        }
        guard isDir.boolValue else { throw FileSystemError.notADirectory(resolvedDir) }

        let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        var entries = children.map { child in
            entry(for: child, resolvedPath: virtualPath(of: child))
        }
        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.lowercased() < b.name.lowercased()
        }
        if !includeHidden {
            entries = entries.filter { !$0.isHidden }
        }
        return entries
    }

    // MARK: mutations

    public func createDirectory(
        _ virtual: String,
        relativeTo cwd: String,
        recursive: Bool = false
    ) throws {
        let resolved = try SandboxPath.resolve(virtual, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        if fm.fileExists(atPath: url.path) {
            throw FileSystemError.alreadyExists(resolved)
        }
        if !recursive, let parent = url.deletingLastPathComponent() as URL? {
            if resolved != "/", !fm.fileExists(atPath: parent.path) {
                throw FileSystemError.parentMissing(resolved)
            }
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: recursive, attributes: nil)
        } catch {
            throw FileSystemError.permissionDenied
        }
    }

    public func createFile(_ virtual: String, relativeTo cwd: String) throws {
        let resolved = try SandboxPath.resolve(virtual, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        if fm.fileExists(atPath: url.path) {
            throw FileSystemError.alreadyExists(resolved)
        }
        guard fm.createFile(atPath: url.path, contents: Data(), attributes: nil) else {
            throw FileSystemError.permissionDenied
        }
    }

    /// POSIX `touch`: create when missing, otherwise refresh the modification time.
    public func touchFile(_ virtual: String, relativeTo cwd: String) throws {
        let resolved = try SandboxPath.resolve(virtual, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        if fm.fileExists(atPath: url.path) {
            do {
                try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } catch {
                throw FileSystemError.permissionDenied
            }
        } else {
            try createFile(virtual, relativeTo: cwd)
        }
    }

    /// Applies numeric POSIX permission bits (used by `chmod`; iOS keeps real
    /// ownership under its own control — this only affects the sandbox files).
    public func setPermissions(_ virtual: String, relativeTo cwd: String, posix: Int) throws {
        let resolved = try SandboxPath.resolve(virtual, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        guard fm.fileExists(atPath: url.path) else { throw FileSystemError.notFound(resolved) }
        do {
            try fm.setAttributes([.posixPermissions: NSNumber(value: posix)], ofItemAtPath: url.path)
        } catch {
            throw FileSystemError.permissionDenied
        }
    }

    public func readData(_ virtual: String, relativeTo cwd: String, maxBytes: Int = 8 * 1024 * 1024) throws -> Data {
        let resolved = try SandboxPath.resolve(virtual, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        guard fm.fileExists(atPath: url.path) else { throw FileSystemError.notFound(resolved) }
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int
        if let size, size > maxBytes { throw FileSystemError.directoryTooLargeForPreview }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw FileSystemError.permissionDenied
        }
    }

    public func readText(_ virtual: String, relativeTo cwd: String) throws -> (text: String, truncated: Bool) {
        let data = try readData(virtual, relativeTo: cwd)
        guard let utf8 = String(data: data, encoding: .utf8) else {
            return (String(decoding: data, as: UTF8.self), true)
        }
        return (utf8, false)
    }

    public func writeText(_ virtual: String, relativeTo cwd: String, content: String, createParents: Bool = false) throws {
        try writeData(virtual, relativeTo: cwd, content: Data(content.utf8), createParents: createParents)
    }

    /// Writes raw bytes (used by file import/export and future features).
    public func writeData(_ virtual: String, relativeTo cwd: String, content: Data, createParents: Bool = false) throws {
        let resolved = try SandboxPath.resolve(virtual, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        if createParents {
            let parent = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
        }
        do {
            try content.write(to: url, options: .atomic)
        } catch {
            throw FileSystemError.permissionDenied
        }
    }

    public func delete(_ virtual: String, relativeTo cwd: String, recursive: Bool = false) throws {
        let resolved = try SandboxPath.resolve(virtual, relativeTo: cwd)
        guard resolved != "/" else { throw FileSystemError.permissionDenied }
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        guard fm.fileExists(atPath: url.path) else { throw FileSystemError.notFound(resolved) }
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue && !recursive {
            let children = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            if !children.isEmpty { throw FileSystemError.notEmpty(resolved) }
        }
        do {
            try fm.removeItem(at: url)
        } catch {
            throw FileSystemError.permissionDenied
        }
    }

    @discardableResult
    public func copy(_ from: String, to: String, relativeTo cwd: String) throws -> String {
        let resolvedFrom = try SandboxPath.resolve(from, relativeTo: cwd)
        let resolvedTo = try SandboxPath.resolve(to, relativeTo: cwd)
        let sourceURL = try SandboxPath.realURL(forVirtual: resolvedFrom, base: baseURL)
        let targetURL = try SandboxPath.realURL(forVirtual: resolvedTo, base: baseURL)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(resolvedFrom)
        }
        guard !targetURL.path.hasPrefix(sourceURL.path + "/") else {
            throw FileSystemError.permissionDenied
        }

        var actualTarget = targetURL
        // If target is an existing directory, copy INTO it.
        if fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue {
            actualTarget = targetURL.appendingPathComponent(sourceURL.lastPathComponent)
        } else if !fm.fileExists(atPath: targetURL.path) {
            // Ensure parent exists
            let parent = targetURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                throw FileSystemError.parentMissing(resolvedTo)
            }
        } else {
            throw FileSystemError.alreadyExists(resolvedTo)
        }
        do {
            try fm.copyItem(at: sourceURL, to: actualTarget)
        } catch {
            throw FileSystemError.permissionDenied
        }
        return virtualPath(of: actualTarget)
    }

    @discardableResult
    public func move(_ from: String, to: String, relativeTo cwd: String) throws -> String {
        let resolvedFrom = try SandboxPath.resolve(from, relativeTo: cwd)
        let resolvedTo = try SandboxPath.resolve(to, relativeTo: cwd)
        guard resolvedFrom != "/" else { throw FileSystemError.permissionDenied }
        let sourceURL = try SandboxPath.realURL(forVirtual: resolvedFrom, base: baseURL)
        let targetURL = try SandboxPath.realURL(forVirtual: resolvedTo, base: baseURL)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(resolvedFrom)
        }

        var actualTarget = targetURL
        if fm.fileExists(atPath: targetURL.path, isDirectory: &isDir), isDir.boolValue {
            actualTarget = targetURL.appendingPathComponent(sourceURL.lastPathComponent)
        } else {
            let parent = targetURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                throw FileSystemError.parentMissing(resolvedTo)
            }
            if fm.fileExists(atPath: actualTarget.path) {
                throw FileSystemError.alreadyExists(resolvedTo)
            }
        }
        do {
            try fm.moveItem(at: sourceURL, to: actualTarget)
        } catch {
            throw FileSystemError.permissionDenied
        }
        return virtualPath(of: actualTarget)
    }

    // MARK: search

    public func search(
        nameContaining needle: String,
        under dir: String,
        relativeTo cwd: String,
        includeHidden: Bool = true,
        maxResults: Int = 200
    ) throws -> [FSEntry] {
        let resolved = try SandboxPath.resolve(dir, relativeTo: cwd)
        let url = try SandboxPath.realURL(forVirtual: resolved, base: baseURL)
        var results: [FSEntry] = []
        let lowercaseNeedle = needle.lowercased()
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else {
            return results
        }
        for case let child as URL in enumerator {
            if results.count >= maxResults { break }
            let name = child.lastPathComponent
            guard SandboxPath.isHidden(name) != true || includeHidden else {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard name.lowercased().contains(lowercaseNeedle) else { continue }
            results.append(entry(for: child, resolvedPath: virtualPath(of: child)))
        }
        return results
    }

    // MARK: bootstrap

    /// Creates a friendly first-run layout inside the sandbox.
    public func bootstrapDefaultLayout() {
        let homeDirs = ["home", "home/xtermux", "home/xtermux/Projects", "home/xtermux/notes"]
        for dir in homeDirs {
            let url = baseURL.appendingPathComponent(dir)
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        if !fm.fileExists(atPath: baseURL.appendingPathComponent("home/xtermux/README.md").path) {
            let welcome = """
            # XTermux — local sandbox

            This is the app's *own* sandbox. Commands execute inside the iOS
            application container; nothing here can escape it and iOS controls
            the rest of the device.

            Try:
                ls -la
                echo Hello | grep ell
                cat README.md

            See Settings → Capabilities for the honest environment matrix.
            """
            try? welcome.write(to: baseURL.appendingPathComponent("home/xtermux/README.md"), atomically: true, encoding: .utf8)
        }
    }
}
