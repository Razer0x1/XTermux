#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// TextEditorView.swift — sandbox file editor (8 MB honest preview limit).

import SwiftUI
import XTermuxCore

struct TextEditorView: View {
    let entry: FSEntry
    let services: AppServices

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var truncated = false
    @State private var dirty = false
    @State private var errorText: String?
    @State private var confirmDiscard = false

    private static let sizeLimitBytes = 8 * 1024 * 1024

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView("Loading…")
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if dirty {
                            confirmDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!loaded || tooLarge)
                }
            }
            .overlay {
                if tooLarge {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("File too large to edit")
                            .font(.headline)
                        Text("Editing is disabled for files over 8 MB (\(sizeLabel)). Use the terminal (head/tail/wc) or export the file instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
            .confirmationDialog(
                "Discard unsaved changes?",
                isPresented: $confirmDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChangeCompat(of: text) {
                if loaded { dirty = true }
            }
            .onAppear(perform: load)
        }
        .interactiveDismissDisabled(dirty)
    }

    private var tooLarge: Bool {
        (entry.size ?? 0) > Self.sizeLimitBytes
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(entry.size ?? 0), countStyle: .file)
    }

    private func load() {
        guard !loaded else { return }
        do {
            let (loadedText, wasTruncated) = try services.fs.readText(entry.virtualPath, relativeTo: "/")
            text = loadedText
            truncated = wasTruncated
            dirty = false
        } catch let error as FileSystemError {
            errorText = error.errorDescription
            text = ""
        } catch {
            errorText = String(describing: error)
        }
        loaded = true
    }

    private func save() {
        do {
            try services.fs.writeText(entry.virtualPath, relativeTo: "/", content: text, createParents: false)
            dirty = false
        } catch let error as FileSystemError {
            errorText = error.errorDescription
        } catch {
            errorText = String(describing: error)
        }
    }
}
#endif
