import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct ExpiringUndoManagerTests {
    private final class State {
        var applied: [String] = []
        var unexpectedUndoCount = 0
        var redoWasDisabled = false
    }

    private final class MutationQueue {
        var pending: [() -> Void] = []

        func schedule(_ work: @escaping () -> Void) {
            pending.append(work)
        }

        func drain() {
            while !pending.isEmpty { pending.removeFirst()() }
        }
    }

    private func registerPromotion(
        _ name: String,
        manager: ExpiringUndoManager,
        state: State,
        queue: MutationQueue
    ) {
        state.applied.append(name)
        manager.beginUndoGrouping()
        manager.registerDeferredUndo(
            withTarget: state,
            expiresAfter: .seconds(60),
            undo: { $0.applied.removeAll { $0 == name } },
            redo: { $0.applied.append(name) },
            schedule: queue.schedule)
        manager.endUndoGrouping()
    }

    @Test func redoPreservesLaterRedoOperations() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        defer { manager.removeAllActions() }
        let state = State()
        let queue = MutationQueue()
        registerPromotion("first", manager: manager, state: state, queue: queue)
        registerPromotion("second", manager: manager, state: state, queue: queue)

        manager.undo()
        manager.undo()
        #expect(state.applied == ["first", "second"])
        #expect(queue.pending.count == 2)
        queue.drain()
        #expect(state.applied.isEmpty)

        manager.redo()
        queue.drain()
        #expect(state.applied == ["first"])
        #expect(manager.canRedo)
        manager.redo()
        queue.drain()
        #expect(state.applied == ["first", "second"])
        #expect(!manager.canRedo)
    }

    @Test func deferredRedoSuppressesNestedUndoRegistration() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        defer { manager.removeAllActions() }
        let state = State()
        state.applied = ["promotion"]
        let queue = MutationQueue()
        manager.beginUndoGrouping()
        manager.registerDeferredUndo(
            withTarget: state,
            expiresAfter: .seconds(60),
            undo: { $0.applied.removeAll() },
            redo: { target in
                target.redoWasDisabled = !manager.isUndoRegistrationEnabled
                target.applied.append("promotion")
                manager.registerUndo(withTarget: target, expiresAfter: .seconds(60)) {
                    $0.unexpectedUndoCount += 1
                }
            },
            schedule: queue.schedule)
        manager.endUndoGrouping()

        manager.undo()
        queue.drain()
        manager.redo()
        queue.drain()
        #expect(state.redoWasDisabled)
        #expect(state.applied == ["promotion"])
        manager.undo()
        queue.drain()
        #expect(state.applied.isEmpty)
        #expect(state.unexpectedUndoCount == 0)
        #expect(manager.isUndoRegistrationEnabled)
    }

    @Test func fastUndoAndRedoPreserveMutationOrder() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        defer { manager.removeAllActions() }
        let state = State()
        let queue = MutationQueue()
        registerPromotion("promotion", manager: manager, state: state, queue: queue)

        manager.undo()
        manager.redo()
        #expect(queue.pending.count == 2)
        #expect(state.applied == ["promotion"])
        queue.pending.removeFirst()()
        #expect(state.applied.isEmpty)
        queue.pending.removeFirst()()
        #expect(state.applied == ["promotion"])
        #expect(manager.canUndo)
        #expect(!manager.canRedo)
    }

    @Test func clearingHistoryReleasesExpiryRecordsWithoutReentrantMutation() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let state = State()
        let queue = MutationQueue()
        registerPromotion("promotion", manager: manager, state: state, queue: queue)
        manager.undo()
        queue.drain()
        #expect(manager.canRedo)

        manager.removeAllActions()
        #expect(!manager.canUndo)
        #expect(!manager.canRedo)
        #expect(queue.pending.isEmpty)

        registerPromotion("next", manager: manager, state: state, queue: queue)
        manager.undo()
        queue.drain()
        #expect(state.applied.isEmpty)
        manager.removeAllActions()
    }

    @Test func zeroExpirationDoesNotRegisterOrSchedule() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let state = State()
        let queue = MutationQueue()
        manager.beginUndoGrouping()
        manager.registerDeferredUndo(
            withTarget: state,
            expiresAfter: .zero,
            undo: { $0.applied.append("undo") },
            redo: { $0.applied.append("redo") },
            schedule: queue.schedule)
        manager.endUndoGrouping()

        #expect(!manager.canUndo)
        #expect(queue.pending.isEmpty)
        #expect(state.applied.isEmpty)
    }

    @Test func disabledRegistrationDoesNotRegisterOrSchedule() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let state = State()
        let queue = MutationQueue()
        manager.disableUndoRegistration {
            manager.registerDeferredUndo(
                withTarget: state,
                expiresAfter: .seconds(60),
                undo: { $0.applied.append("undo") },
                redo: { $0.applied.append("redo") },
                schedule: queue.schedule)
        }

        #expect(!manager.canUndo)
        #expect(queue.pending.isEmpty)
        #expect(manager.isUndoRegistrationEnabled)
    }
}
