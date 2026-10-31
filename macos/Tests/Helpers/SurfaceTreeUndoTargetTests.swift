import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct SurfaceTreeUndoTargetTests {
    private final class Pane {}

    private final class Controller {
        var panes: [Pane]

        init(_ panes: [Pane]) {
            self.panes = panes
        }
    }

    private final class Session {
        var source: Controller?
        var destination: Controller?
        var restoredSource: Controller?
        var undoCount = 0
        var redoCount = 0
        var pending: [() -> Void] = []

        func owner(of pane: Pane) -> Controller? {
            [source, destination].compactMap { $0 }.first { controller in
                controller.panes.contains { $0 === pane }
            }
        }

        func drain() {
            while !pending.isEmpty { pending.removeFirst()() }
        }
    }

    @Test func sourceCloseRestoreRetargetsPromotionAndPreservesRedo() throws {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        defer { manager.removeAllActions() }
        let app = NSObject()
        let session = Session()
        let first = Pane()
        let second = Pane()
        let moved = Pane()
        session.source = Controller([first, second])
        session.destination = Controller([moved])
        weak var oldSource = session.source

        manager.beginUndoGrouping()
        SurfaceTreeUndoTarget(surfaces: [first, second], owner: session.owner(of:))
            .registerDeferredUndo(
                in: manager,
                withOwner: app,
                expiresAfter: .seconds(60),
                undo: { source in
                    session.undoCount += 1
                    session.restoredSource = source
                    session.destination?.panes = []
                    source.panes = [first, second, moved]
                },
                redo: { source in
                    session.redoCount += 1
                    source.panes = [first, second]
                    session.destination = Controller([moved])
                },
                schedule: { session.pending.append($0) })
        manager.endUndoGrouping()

        // Closing removes all old-controller actions. Its own close undo is
        // app-owned and recreates the controller with the same surviving panes.
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: app, expiresAfter: .seconds(60)) { _ in
            session.source = Controller([first, second])
        }
        manager.endUndoGrouping()
        manager.removeAllActions(withTarget: try #require(session.source))
        session.source = nil
        #expect(oldSource == nil)
        manager.undo()
        let replacement = try #require(session.source)
        #expect(manager.canUndo)

        manager.undo()
        #expect(session.undoCount == 0)
        session.drain()
        #expect(session.undoCount == 1)
        #expect(session.restoredSource === replacement)
        #expect(replacement.panes.count == 3)
        #expect(session.destination?.panes.isEmpty == true)
        manager.redo()
        session.drain()
        #expect(session.redoCount == 1)
        #expect(replacement.panes.count == 2)
        #expect(session.destination?.panes.first === moved)
        manager.undo()
        session.drain()
        #expect(session.undoCount == 2)
    }

    @Test func resolutionOccursAfterSchedulingAndRejectsMissingOrDivergentOwners() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        defer { manager.removeAllActions() }
        let app = NSObject()
        let session = Session()
        let first = Pane()
        let second = Pane()
        session.source = Controller([first, second])
        let target = SurfaceTreeUndoTarget(surfaces: [first, second], owner: session.owner(of:))
        manager.beginUndoGrouping()
        target.registerDeferredUndo(
            in: manager,
            withOwner: app,
            expiresAfter: .seconds(60),
            undo: { session.restoredSource = $0 },
            redo: { _ in session.redoCount += 1 },
            schedule: { session.pending.append($0) })
        manager.endUndoGrouping()
        manager.undo()
        let replacement = Controller([first, second])
        session.source = replacement
        session.drain()
        #expect(session.restoredSource === replacement)

        session.source = nil
        #expect(target.currentOwner == nil)
        session.source = Controller([first])
        session.destination = Controller([second])
        #expect(target.currentOwner == nil)
        manager.redo()
        session.drain()
        #expect(session.redoCount == 0)
    }

    @Test func clearingHistoryReleasesPaneSnapshots() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let app = NSObject()
        weak var retainedPane: Pane?
        do {
            let pane = Pane()
            retainedPane = pane
            manager.beginUndoGrouping()
            SurfaceTreeUndoTarget<Pane, Controller>(surfaces: [pane], owner: { _ in nil })
                .registerDeferredUndo(
                    in: manager,
                    withOwner: app,
                    expiresAfter: .seconds(60),
                    undo: { _ in },
                    redo: { _ in })
            manager.endUndoGrouping()
        }
        #expect(retainedPane != nil)
        manager.removeAllActions()
        #expect(retainedPane == nil)
    }

    @Test func expirationReleasesPaneSnapshots() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        defer { manager.removeAllActions() }
        let app = NSObject()
        weak var retainedPane: Pane?
        do {
            let pane = Pane()
            retainedPane = pane
            manager.beginUndoGrouping()
            SurfaceTreeUndoTarget<Pane, Controller>(surfaces: [pane], owner: { _ in nil })
                .registerDeferredUndo(
                    in: manager,
                    withOwner: app,
                    expiresAfter: .milliseconds(1),
                    undo: { _ in },
                    redo: { _ in })
            manager.endUndoGrouping()
        }
        #expect(retainedPane != nil)
        let deadline = Date().addingTimeInterval(1)
        while retainedPane != nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        #expect(retainedPane == nil)
        #expect(!manager.canUndo)
    }
}
