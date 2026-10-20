#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// ProjectsView.swift — project folders in the sandbox with starter templates.
//
// Projects live at /home/xtermux/Projects. Building real binaries needs a
// toolchain iOS does not provide; the UI says so honestly and points at SSH.

import SwiftUI
import XTermuxCore

enum ProjectTemplate: String, CaseIterable, Identifiable {
    case terminalStarter = "Terminal starter"
    case plainNotes = "Plain notes"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .terminalStarter:
            return "README.md + main.sh script text + src/ folder"
        case .plainNotes:
            return "notes.md + todo.md"
        }
    }
}

struct ProjectsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var projects: [FSEntry] = []
    @State private var createAlert = false
    @State private var newNameText = ""
    @State private var selectedTemplate: ProjectTemplate = .terminalStarter
    @State private var confirmDelete: FSEntry?
    @State private var openProject: FSEntry?
    @State private var errorText: String?

    private var projectsRoot: String { SandboxPath.homePrefix + "/Projects" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    honestNote
                } header: {
                    Text("What projects are")
                }

                Section {
                    ForEach(projects) { project in
                        projectRow(project)
                    }
                    if projects.isEmpty {
                        Text("No projects yet")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Your projects")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newNameText = ""
                        createAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New project")
                }
            }
            .onAppear(perform: reload)
            .alert("New project", isPresented: $createAlert) {
                TextField("Project name", text: $newNameText)
                Picker("Template", selection: $selectedTemplate) {
                    ForEach(ProjectTemplate.allCases) { template in
                        Text(template.rawValue).tag(template)
                    }
                }
                Button("Create") { create() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(selectedTemplate.description)
            }
            .alert("Delete \"\(confirmDelete?.name ?? "")\" and everything inside?", isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let target = confirmDelete {
                        run {
                            try services.fs.delete(target.virtualPath, relativeTo: "/", recursive: true)
                        }
                    }
                    confirmDelete = nil
                    reload()
                }
                Button("Cancel", role: .cancel) { confirmDelete = nil }
            }
            .alert("Error", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .sheet(item: Binding(
                get: { openProject },
                set: { if $0 == nil { openProject = nil; reload() } }
            )) { project in
                ProjectDetailView(project: project, services: services)
            }
        }
    }

    private var honestNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sandbox folders, not build targets", systemImage: "folder")
                .font(.subheadline.weight(.semibold))
            Text("Xcode-class compilers cannot run inside iOS, so projects here hold source files you edit and operate through the terminal or your SSH server. No toolchains are faked.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func projectRow(_ project: FSEntry) -> some View {
        Button {
            openProject = project
        } label: {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.callout.weight(.semibold))
                    Text(project.modified.map { Self.detailedFormatter.string(from: $0) } ?? "-")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                confirmDelete = project
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func reload() {
        do {
            projects = try services.fs.listEntries(projectsRoot, relativeTo: "/", includeHidden: false)
        } catch {
            projects = []
        }
    }

    private func create() {
        let name = newNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        run {
            let root = projectsRoot + "/" + name
            try services.fs.createDirectory(root, relativeTo: "/", recursive: true)
            switch selectedTemplate {
            case .terminalStarter:
                try services.fs.createDirectory(root + "/src", relativeTo: "/", recursive: true)
                try services.fs.writeText(root + "/README.md", relativeTo: "/", content: """
                # \(name)

                Created with XTermux. Work with these files using:

                - the built-in shell (Terminal tab) for pipes, redirects, search
                - your SSH server (Settings > SSH, then Terminal > + > SSH)
                  for full Linux tooling such as bash scripts, git, python, gcc

                Note: iOS does not give App Store apps fork/exec, so this app
                runs its own in-process commands and never fake-executes
                binaries. `main.sh` is plain script text you can run on a real
                Linux server.
                """, createParents: true)
                try services.fs.writeText(root + "/main.sh", relativeTo: "/", content: """
                #!/usr/bin/env bash
                # Run this file on a real Linux machine (XShell > + > SSH),
                # or read it with `cat main.sh` locally.

                echo "hello from \\(name)"
                """, createParents: true)
            case .plainNotes:
                try services.fs.writeText(root + "/notes.md", relativeTo: "/", content: "# Notes\n\n", createParents: true)
                try services.fs.writeText(root + "/todo.md", relativeTo: "/", content: "# TODO\n\n- [ ] first\n", createParents: true)
            }
        }
        reload()
    }

    private func run(_ body: () throws -> Void) {
        do {
            try body()
        } catch let error as FileSystemError {
            errorText = error.errorDescription
        } catch {
            errorText = String(describing: error)
        }
    }

    static let detailedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: project detail

struct ProjectDetailView: View {
    let project: FSEntry
    let services: AppServices

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FSEntry] = []
    @State private var fileTarget: FSEntry?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    Button {
                        if !entry.isDirectory {
                            fileTarget = entry
                        }
                    } label: {
                        // Typed locals: bare ternaries here blow up the SwiftUI
                        // type checker ("unable to type-check in reasonable time").
                        let iconName: String = entry.isDirectory ? "folder.fill" : "doc"
                        let iconColor: Color = entry.isDirectory ? .accentColor : .secondary
                        HStack {
                            Image(systemName: iconName)
                                .foregroundStyle(iconColor)
                            Text(entry.virtualPath.replacingOccurrences(of: project.virtualPath + "/", with: ""))
                                .font(.system(.callout, design: .monospaced))
                            Spacer()
                            if let size = entry.size, !entry.isDirectory {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if entries.isEmpty {
                    Text("Empty project").foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: reload)
            .sheet(item: Binding(
                get: { fileTarget },
                set: { fileTarget = $0 }
            )) { entry in
                TextEditorView(entry: entry, services: services)
            }
            .alert("Error", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
        }
    }

    private func reload() {
        do {
            entries = try services.fs.search(
                nameContaining: "",
                under: project.virtualPath,
                relativeTo: "/",
                includeHidden: true,
                maxResults: 500
            )
        } catch {
            entries = []
        }
    }
}
#endif
