#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// FilesView.swift — sandbox file browser: navigation, create, edit, rename,
// duplicate, move, delete (with confirmation), import & export, search.

import SwiftUI
import UniformTypeIdentifiers
import XTermuxCore

enum FilesSort: String, CaseIterable, Identifiable {
    case name, modified, size
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date modified"
        case .size: return "Size"
        }
    }
}

/// FileDocument wrapper so `fileExporter` can export arbitrary sandbox files.
struct BinaryFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let data: Data
    let suggestedName: String

    init(data: Data, name: String) {
        self.data = data
        self.suggestedName = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        suggestedName = configuration.file.filename ?? "export.bin"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct FilesView: View {
    @EnvironmentObject private var services: AppServices
    @State private var path = SandboxPath.homePrefix
    @State private var entries: [FSEntry] = []
    @State private var showHidden = false
    @State private var sort: FilesSort = .name
    @State private var searchText = ""
    @State private var searchResults: [FSEntry] = []
    @State private var editorTarget: FSEntry?
    @State private var confirmDelete: FSEntry?
    @State private var renameTarget: FSEntry?
    @State private var moveTarget: FSEntry?
    @State private var copyTarget: FSEntry?
    @State private var targetText = ""
    @State private var createAlert = false
    @State private var createIsFolder = false
    @State private var createText = ""
    @State private var importVisible = false
    @State private var exportTarget: FSEntry?
    @State private var exportDocument: BinaryFileDocument?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    entryList
                } else {
                    resultView
                }
            }
            .navigationTitle(SandboxPath.display(path))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear(perform: reload)
            .onChangeCompat(of: path) { reload() }
            .onChangeCompat(of: showHidden) { reload() }
            .onChangeCompat(of: sort) { reload() }
            .onChangeCompat(of: searchText) { runSearch() }
            .fileImporter(
                isPresented: $importVisible,
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                if let url = try? result.get().first {
                    importFile(url: url)
                }
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { if !$0 { exportDocument = nil; exportTarget = nil } }
                ),
                document: exportDocument ?? BinaryFileDocument(data: Data(), name: "file"),
                contentType: .data,
                defaultFilename: exportTarget?.name ?? "file"
            ) { _ in
                exportDocument = nil
                exportTarget = nil
            }
            .alert("Delete \"\(confirmDelete?.name ?? "")\"? This cannot be undone.", isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    guard let target = confirmDelete else { return }
                    do {
                        try services.fs.delete(
                            target.virtualPath,
                            relativeTo: "/",
                            recursive: target.isDirectory
                        )
                        reload()
                        runSearch()
                    } catch let error as FileSystemError {
                        errorText = error.errorDescription
                    } catch {
                        errorText = String(describing: error)
                    }
                    confirmDelete = nil
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
            }
            .alert("Create", isPresented: $createAlert) {
                TextField(createIsFolder ? "Folder name" : "File name", text: $createText)
                Button("Create") { performCreate() }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Rename / move", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("New path", text: $targetText)
                Button("Apply") { performMove(source: renameTarget, destination: targetText) }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            } message: {
                Text("Full virtual path, e.g. /home/xtermux/newname.md")
            }
            .alert("Duplicate / copy to", isPresented: Binding(
                get: { copyTarget != nil },
                set: { if !$0 { copyTarget = nil } }
            )) {
                TextField("Destination path", text: $targetText)
                Button("Copy") { performCopy(source: copyTarget, destination: targetText) }
                Button("Cancel", role: .cancel) { copyTarget = nil }
            }
            .alert("Error", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorText ?? "")
            }
            .sheet(item: $editorTarget) { entry in
                TextEditorView(entry: entry, services: services)
            }
        }
    }

    @State private var lastImport: URL?

    /// Stages a copy of a sandbox file into the app's tmp directory so the
    /// system share sheet can attach a real file. iOS purges tmp automatically.
    private static func stagedShareURL(name: String, data: Data) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xtermux-share-\(UUID().uuidString)-\(safe)")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: main list

    private var entryList: some View {
        List {
            if path != "/" {
                Button {
                    descend(to: (path as NSString).deletingLastPathComponent == "" ? "/" : (path as NSString).deletingLastPathComponent)
                } label: {
                    Label("..", systemImage: "arrow.up").foregroundStyle(.secondary)
                }
            }
            ForEach(entries) { entry in
                row(entry: entry)
            }
            if entries.isEmpty {
                Text("Empty folder")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private var resultView: some View {
        List(searchResults) { entry in
            row(entry: entry)
        }
        .overlay {
            if searchResults.isEmpty {
                Text("No matches in this folder tree")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(entry: FSEntry) -> some View {
        Button {
            if entry.isDirectory {
                descend(to: entry.virtualPath)
            } else {
                editorTarget = entry
            }
        } label: {
            HStack {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .foregroundStyle(entry.isHidden ? .secondary : .primary)
                        .font(.callout)
                    if let size = entry.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !entry.isDirectory, (entry.size ?? 0) > 8 * 1024 * 1024 {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("Larger than the 8 MB preview/editor limit")
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                confirmDelete = entry
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                targetText = entry.virtualPath
                copyTarget = entry
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            .tint(.blue)
            Button {
                targetText = entry.virtualPath
                renameTarget = entry
            } label: {
                Label("Rename / move", systemImage: "pencil")
            }
            .tint(.indigo)
        }
        .contextMenu {
            Button {
                editorTarget = entry // files only; harmless no-op for folders
            } label: { Label("Open", systemImage: "doc") }
            Button {
                targetText = entry.virtualPath
                renameTarget = entry
            } label: { Label("Rename / move", systemImage: "pencil") }
            Button {
                targetText = entry.virtualPath
                copyTarget = entry
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button {
                doExport(entry)
            } label: { Label("Export…", systemImage: "square.and.arrow.up") }
            if !entry.isDirectory,
               let data = try? services.fs.readData(entry.virtualPath, relativeTo: "/"),
               let staged = Self.stagedShareURL(name: entry.name, data: data) {
                ShareLink(item: staged, preview: SharePreview(entry.name)) {
                    Label("Share", systemImage: "square.and.arrow.up.on.square")
                }
            }
            Button(role: .destructive) {
                confirmDelete = entry
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Button {
                    createIsFolder = false
                    createText = ""
                    createAlert = true
                } label: { Label("New file", systemImage: "doc.badge.plus") }
                Button {
                    createIsFolder = true
                    createText = ""
                    createAlert = true
                } label: { Label("New folder", systemImage: "folder.badge.plus") }
                Button {
                    importVisible = true
                } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Divider()
                Picker("Sort", selection: $sort) {
                    ForEach(FilesSort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                Toggle("Show hidden files", isOn: $showHidden)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: actions

    private func descend(to target: String) {
        path = target
        searchText = ""
    }

    private func reload() {
        do {
            var list = try services.fs.listEntries(path, relativeTo: "/", includeHidden: showHidden)
            switch sort {
            case .name: break
            case .modified:
                list.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            case .size:
                list.sort { ($0.size ?? -1) > ($1.size ?? -1) }
            }
            entries = list
        } catch let error as FileSystemError {
            entries = []
            errorText = error.errorDescription
        } catch {
            errorText = String(describing: error)
        }
    }

    private func runSearch() {
        guard !searchText.isEmpty else { searchResults = []; return }
        searchResults = (try? services.fs.search(
            nameContaining: searchText,
            under: path,
            relativeTo: "/",
            includeHidden: showHidden
        )) ?? []
    }

    private func performCreate() {
        let name = createText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            if createIsFolder {
                try services.fs.createDirectory(name, relativeTo: path, recursive: false)
            } else {
                try services.fs.touchFile(name, relativeTo: path)
            }
            reload()
        } catch let error as FileSystemError {
            errorText = error.errorDescription
        } catch {
            errorText = String(describing: error)
        }
    }

    private func performMove(source: FSEntry?, destination raw: String) {
        guard let source else { return }
        let destination = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, destination != source.virtualPath else { return }
        do {
            if services.fs.exists(destination, relativeTo: "/") {
                try services.fs.delete(destination, relativeTo: "/")
            }
            _ = try services.fs.move(source.virtualPath, to: destination, relativeTo: "/")
            reload()
            runSearch()
        } catch let error as FileSystemError {
            errorText = error.errorDescription
        } catch {
            errorText = String(describing: error)
        }
        renameTarget = nil
    }

    private func performCopy(source: FSEntry?, destination raw: String) {
        guard let source else { return }
        let destination = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, destination != source.virtualPath else { return }
        do {
            if services.fs.exists(destination, relativeTo: "/") {
                try services.fs.delete(destination, relativeTo: "/")
            }
            _ = try services.fs.copy(source.virtualPath, to: destination, relativeTo: "/")
            reload()
            runSearch()
        } catch let error as FileSystemError {
            errorText = error.errorDescription
        } catch {
            errorText = String(describing: error)
        }
        copyTarget = nil
    }

    private func doExport(_ entry: FSEntry) {
        guard !entry.isDirectory,
              let data = try? services.fs.readData(entry.virtualPath, relativeTo: "/") else { return }
        exportDocument = BinaryFileDocument(data: data, name: entry.name)
        exportTarget = entry
    }

    private func importFile(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let target = path + "/" + url.lastPathComponent
            if services.fs.exists(target, relativeTo: "/") {
                try services.fs.delete(target, relativeTo: "/")
            }
            try services.fs.writeText(
                target,
                relativeTo: "/",
                content: String(decoding: data, as: UTF8.self),
                createParents: true
            )
            reload()
        } catch let error as FileSystemError {
            errorText = error.errorDescription
        } catch {
            errorText = error.localizedDescription
        }
    }
}
#endif
