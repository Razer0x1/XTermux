// SessionLifecycleTests.swift — the session lifecycle invariants that the iOS
// SessionStore depends on, exercised headlessly on Linux.

import Foundation
import Testing
@testable import XTermuxCore

@MainActor
private final class Probe: Identifiable {
    let id = UUID()
    private(set) var terminatedCount = 0

    func terminate() { terminatedCount += 1 }
}

@MainActor
struct SessionLifecycleTests {

    @Test func creationSelectsSessionAndLeavesHome() {
        let store = SessionStoreCore<Probe>()
        let first = Probe()
        #expect(store.append(first))
        #expect(store.sessions.count == 1)
        #expect(store.selected?.id == first.id)
        #expect(!store.showHome)
    }

    @Test func failedCreationNeverAddsGhost() {
        // "Failed creation" means append is simply never called; the UI must
        // stay on Home with zero sessions and no phantom selection.
        let store = SessionStoreCore<Probe>()
        #expect(store.sessions.isEmpty)
        #expect(store.selected == nil)
        #expect(store.showHome)
    }

    @Test func duplicateAppendIsRejected() {
        let store = SessionStoreCore<Probe>()
        let only = Probe()
        #expect(store.append(only))
        #expect(!store.append(only))
        #expect(store.sessions.count == 1)
        #expect(store.selected?.id == only.id)
    }

    @Test func selectingUnknownIdIsNoOp() {
        let store = SessionStoreCore<Probe>()
        let probe = Probe()
        #expect(store.append(probe))
        store.select(UUID()) // unknown
        #expect(store.selected?.id == probe.id)
        #expect(!store.showHome)
    }

    @Test func backHomeThenBackIntoSession() {
        let store = SessionStoreCore<Probe>()
        let probe = Probe()
        #expect(store.append(probe))
        store.select(nil)
        #expect(store.selected == nil)
        #expect(store.showHome)
        store.select(probe.id)
        #expect(store.selected?.id == probe.id)
        #expect(!store.showHome)
    }

    @Test func closingSelectedTerminatesOnceAndSurvivorStaysActive() {
        let store = SessionStoreCore<Probe>()
        let a = Probe(), b = Probe(), c = Probe()
        store.append(a); store.append(b); store.append(c)
        store.select(a.id)

        #expect(store.close(a.id) { $0.terminate() })
        #expect(a.terminatedCount == 1)
        #expect(b.terminatedCount == 0)
        #expect(c.terminatedCount == 0)
        #expect(store.sessions.count == 2)
        #expect(store.selected?.id == c.id) // newest survivor
        #expect(!store.showHome)
    }

    @Test func repeatedExitTapsAreHarmless() {
        let store = SessionStoreCore<Probe>()
        let only = Probe()
        store.append(only)

        #expect(store.close(only.id) { $0.terminate() })
        #expect(!store.close(only.id) { $0.terminate() }) // second tap: no-op
        #expect(store.showHome)
        #expect(store.sessions.isEmpty)
        #expect(only.terminatedCount == 1)
    }

    @Test func closingLastSessionShowsHomeImmediately() {
        let store = SessionStoreCore<Probe>()
        let only = Probe()
        store.append(only)
        store.close(only.id) { $0.terminate() }
        #expect(store.sessions.isEmpty)
        #expect(store.selectedID == nil)
        #expect(store.showHome)
        #expect(only.terminatedCount == 1)
    }

    @Test func cancelConfirmationLeavesSessionActive() {
        // A cancelled confirmation dialog means close() is never called —
        // model that by calling close on an unknown id and expecting no-op.
        let store = SessionStoreCore<Probe>()
        let probe = Probe()
        store.append(probe)
        store.select(probe.id)

        #expect(!store.close(UUID()) { $0.terminate() })
        #expect(store.selected?.id == probe.id)
        #expect(probe.terminatedCount == 0)
        #expect(!store.showHome)
    }

    @Test func preservingOthersWhenClosingOneOfMany() {
        let store = SessionStoreCore<Probe>()
        let a = Probe(), b = Probe(), c = Probe()
        store.append(a); store.append(b); store.append(c)

        #expect(store.close(b.id) { $0.terminate() })
        #expect(store.sessions.map(\.id) == [a.id, c.id])
        #expect(b.terminatedCount == 1)
        #expect(a.terminatedCount == 0)
        #expect(c.terminatedCount == 0)
        #expect(!store.showHome)
    }

    @Test func closeAllTerminatesEverythingOnce() {
        let store = SessionStoreCore<Probe>()
        let a = Probe(), b = Probe()
        store.append(a); store.append(b)

        #expect(store.closeAll { $0.terminate() })
        #expect(!store.closeAll { $0.terminate() }) // already home: no-op
        #expect(store.sessions.isEmpty)
        #expect(store.showHome)
        #expect(a.terminatedCount == 1)
        #expect(b.terminatedCount == 1)
    }

    @Test func pruneRemovesUnexpectedlyDeadSessions() {
        // Resources for a pruned session are already gone, so prune must not
        // call terminate again (double-termination avoidance).
        let store = SessionStoreCore<Probe>()
        let a = Probe(), b = Probe()
        store.append(a); store.append(b)

        store.prune([b.id])
        #expect(store.sessions.map(\.id) == [a.id])
        #expect(b.terminatedCount == 0)
        #expect(store.selected?.id == a.id)

        store.prune([a.id])
        #expect(store.sessions.isEmpty)
        #expect(store.showHome)
        #expect(a.terminatedCount == 0)
    }

    @Test func pruneKeepsSelectionWhenOthersDie() {
        let store = SessionStoreCore<Probe>()
        let a = Probe(), b = Probe(), c = Probe()
        store.append(a); store.append(b); store.append(c)
        store.select(c.id)

        store.prune([a.id, b.id])
        #expect(store.selected?.id == c.id)
        #expect(!store.showHome)
    }
}
