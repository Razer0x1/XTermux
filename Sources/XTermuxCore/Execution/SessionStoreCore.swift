// SessionStoreCore.swift — generic, UI-agnostic session lifecycle state.
//
// XTermux's iOS `SessionStore` adapts over this so the only meaningful session
// state machine — creation dedupe, selection, idempotent termination, "close
// the last one → show Home" logic — is fully unit-testable on Linux without
// UIKit. The app layer owns view-specific concerns (status observation,
// backend backends, SSH reconnects); this type guarantees the invariants.

import Foundation

/// One authoritative source of truth for: which sessions exist, which one is
/// selected, and whether the UI should show the "no sessions" home screen.
@MainActor
public final class SessionStoreCore<Session: Identifiable> {
    public private(set) var sessions: [Session] = []
    public private(set) var selectedID: Session.ID?
    /// True while the UI presents the home/empty state instead of a session.
    public private(set) var showHome: Bool

    public init(showHome: Bool = true) {
        self.showHome = showHome
    }

    /// The selected session, or nil while on home. Never returns an unselected
    /// fallback — the store does not silently activate some other tab.
    public var selected: Session? {
        guard !showHome else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    public func contains(_ id: Session.ID) -> Bool {
        sessions.contains { $0.id == id }
    }

    /// Selects a session (entering it), or `nil` to return Home. Selecting an
    /// unknown id is a no-op: only successfully created sessions are shown.
    public func select(_ id: Session.ID?) {
        if let id {
            guard contains(id) else { return }
            selectedID = id
            showHome = false
        } else {
            showHome = true
        }
    }

    /// Registers a fresh session, selects it, and leaves Home. Duplicate
    /// registration (same id) is rejected — repeated Exit/open taps and
    /// double-creation code paths cannot produce ghosts.
    @discardableResult
    public func append(_ session: Session) -> Bool {
        guard !contains(session.id) else { return false }
        sessions.append(session)
        selectedID = session.id
        showHome = false
        return true
    }

    /// Terminates and removes exactly one session. The terminator runs at most
    /// once per id: closing an already-closed session is a harmless no-op, so
    /// repeated Exit taps are safe. Closing all of them shows Home; otherwise
    /// the newest survivor stays active.
    @discardableResult
    public func close(_ id: Session.ID, terminate: (Session) -> Void) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        let session = sessions.remove(at: index)
        terminate(session)
        if selectedID == id {
            if sessions.isEmpty {
                selectedID = nil
                showHome = true
            } else {
                selectedID = sessions.last?.id
            }
        }
        return true
    }

    /// Terminates and removes every session. Second call from Home: no-op.
    @discardableResult
    public func closeAll(terminate: (Session) -> Void) -> Bool {
        guard !sessions.isEmpty else { return false }
        for session in sessions { terminate(session) }
        sessions.removeAll()
        selectedID = nil
        showHome = true
        return true
    }

    /// Removes sessions whose processes died on their own (unexpected
    /// disconnect without an explicit close). Resources are assumed released
    /// by the time ids reach here; termination callbacks are NOT invoked.
    public func prune(_ ids: Set<Session.ID>) {
        guard !ids.isEmpty else { return }
        sessions.removeAll { ids.contains($0.id) }
        if let selectedID, ids.contains(selectedID) {
            if sessions.isEmpty {
                self.selectedID = nil
                showHome = true
            } else {
                self.selectedID = sessions.last?.id
            }
        }
    }
}
