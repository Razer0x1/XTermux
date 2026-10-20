#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// TerminalBridgeView.swift — SwiftUI bridge over SwiftTerm's TerminalView.
//
// Data flow:
//   - ExecutionSession events → `terminalView.feed(byteArray:)` (rendering)
//   - TerminalView keystrokes → delegate.send → InputPipe → ExecutionSession
//
// The local backend echoes typed input itself (echoMode == .localEcho), so
// SwiftTerm is never asked to pre-render user keystrokes.

import SwiftUI
import UIKit
@preconcurrency import SwiftTerm
import XTermuxCore

struct TerminalBridgeView: UIViewRepresentable {
    @ObservedObject var model: TerminalSessionModel
    var fontSize: CGFloat
    var theme: TerminalThemeID

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        // SwiftTerm's setup() installs its own input accessory bar (F-keys,
        // arrows, a full alternate keyboard…) unconditionally. XTermux renders
        // one shared accessory row from SwiftUI instead, so drop the built-in
        // one here — otherwise the device shows two stacked keyboard bars.
        view.inputAccessoryView = nil
        view.terminalDelegate = context.coordinator
        apply(theme: theme, to: view)
        applyFont(to: view)
        context.coordinator.bind(view: view)
        model.terminalView = view
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        apply(theme: theme, to: view)
        applyFont(to: view)
    }

    private func applyFont(to view: TerminalView) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if view.font.pointSize != font.pointSize {
            view.font = font
        }
    }

    private func apply(theme: TerminalThemeID, to view: TerminalView) {
        view.nativeBackgroundColor = theme.uiBackground()
        view.nativeForegroundColor = theme.uiForeground()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    final class Coordinator: NSObject {
        private unowned let model: TerminalSessionModel
        private weak var view: TerminalView?

        init(model: TerminalSessionModel) {
            self.model = model
        }

        func bind(view: TerminalView) {
            self.view = view
        }
    }
}

// TerminalViewDelegate conformance: UIKit invokes these on the main thread;
// the InputPipe is safe either way. @preconcurrency bridges SwiftTerm's
// Swift-5-mode nonisolated protocol requirements with our main-actor view.
extension TerminalBridgeView.Coordinator: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        model.pipe.send(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        model.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        Task { @MainActor in
            guard !title.isEmpty else { return }
            model.title = title
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // ignored: virtual sandbox paths are what the shell displays
    }

    func scrolled(source: TerminalView, position: Double) {
        // nothing to do: SwiftTerm manages its own scrolling UI
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Honest no-op: terminal links are not auto-opened; use copy.
    }

    func bell(source: TerminalView) {
        // no audible bell in v1
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        UIPasteboard.general.string?.data(using: .utf8)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        // unsupported iTerm2 extensions are ignored
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // accessibility update hook, unused in v1
    }
}
#endif
