#if canImport(UIKit) // iOS app target: SwiftUI/UIKit only, empty module elsewhere
// ContentView.swift — root: five tabs + first-run welcome + honest chrome.

import SwiftUI
import XTermuxCore

struct ContentView: View {
    @EnvironmentObject private var services: AppServices
    @AppStorage("xtermux.seenWelcome") private var seenWelcome = false
    @State private var showWelcome = false

    init() {
        _showWelcome = State(initialValue: false)
    }

    var body: some View {
        TabView(selection: $services.selectedTab) {
            TerminalTabView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(AppTab.terminal)
            FilesView()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(AppTab.files)
            PackagesView()
                .tabItem { Label("Packages", systemImage: "shippingbox") }
                .tag(AppTab.packages)
            ProjectsView()
                .tabItem { Label("Projects", systemImage: "hammer") }
                .tag(AppTab.projects)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeView {
                seenWelcome = true
                showWelcome = false
            }
        }
        .onAppear {
            if !seenWelcome {
                showWelcome = true
            }
        }
    }
}

// MARK: welcome flow

struct WelcomeView: View {
    let done: () -> Void
    @State private var page = 0

    private let lastPage = 4

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                brandPage.tag(0)
                welcomePage(
                    icon: "shield.lefthroistotal",
                    title: "Your sandbox, honestly",
                    text: """
                    XTermux runs its commands inside this app's iOS sandbox. \
                    There is no fork/exec, no root, and the Darwin/XNU kernel \
                    stays fully under iOS control — by design, not by accident.
                    """
                ).tag(1)
                welcomePage(
                    icon: "terminal",
                    title: "A real shell, in-process",
                    text: """
                    Pipes, redirection, $VARS, exit codes, history, Tab \
                    completion. Try: echo hello | grep ell, then ls -la, \
                    then kern compare.
                    """
                ).tag(2)
                welcomePage(
                    icon: "cpu",
                    title: "Peek inside XNU",
                    text: """
                    The kernel behind iOS is XNU. Run kern info for the \
                    explainer, kern compare for iOS vs Android, and \
                    kern explore for exact steps to clone the open-source \
                    kernel into your computer.
                    """
                ).tag(3)
                welcomePage(
                    icon: "network",
                    title: "Full Linux via SSH",
                    text: """
                    The app never pretends a Linux VM is running. For bash, \
                    python, git and apt, connect to your own server over SSH \
                    (Settings → SSH, then Terminal → + → SSH).
                    """
                ).tag(4)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                done()
            } label: {
                Text(page == lastPage ? "Open the terminal" : "Skip")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .background(Color(.systemBackground))
    }

    /// First page: the app's logo, name, and honest developer credit.
    private var brandPage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(uiImage: loadLogo())
                .resizable()
                .scaledToFit()
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                .shadow(color: SwiftUI.Color.accentColor.opacity(0.45), radius: 16)
            Text("XTermux")
                .font(.largeTitle.weight(.bold))
            Text("A real terminal, in your pocket. Honest about what a sandboxed iOS app can — and cannot — do.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            VStack(spacing: 4) {
                Text("Developed by \(ShellInfo.developer)")
                    .font(.caption.weight(.semibold))
                Text(ShellInfo.inspirationNotice)
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func welcomePage(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(title)
                .font(.title2.weight(.bold))
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
    }

    /// Loads the bundled logo from the SwiftPM resource bundle; the empty
    /// fallback keeps the page rendering even if the asset is missing.
    private func loadLogo() -> UIImage {
        UIImage(named: "applogo.png", in: Bundle.module, compatibleWith: nil)
            ?? UIImage()
    }
}
#endif
