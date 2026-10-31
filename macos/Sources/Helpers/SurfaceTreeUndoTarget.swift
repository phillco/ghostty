import Foundation

/// Resolves a split-tree controller by pane identity across close/restore cycles.
/// Retaining panes preserves their running terminals, while controller lifetimes
/// remain independent of the app-owned, expiring undo history.
struct SurfaceTreeUndoTarget<Surface: AnyObject, Controller: AnyObject> {
    let surfaces: [Surface]
    let owner: (Surface) -> Controller?

    /// All source panes must still belong to one live controller. A stale or
    /// partially restored source must not pull panes out of unrelated windows.
    var currentOwner: Controller? {
        guard let first = surfaces.first, let result = owner(first) else { return nil }
        guard surfaces.allSatisfy({ owner($0) === result }) else { return nil }
        return result
    }

    /// Keep history on a stable owner (the app), then resolve the current
    /// controller only when the deferred mutation runs. Neither closure should
    /// capture a controller, so window close cleanup cannot invalidate this action.
    func registerDeferredUndo<Owner: AnyObject>(
        in manager: ExpiringUndoManager,
        withOwner stableOwner: Owner,
        expiresAfter duration: Duration,
        undo: @escaping (Controller) -> Void,
        redo: @escaping (Controller) -> Void,
        schedule: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: DispatchWorkItem(block: work))
        }
    ) {
        manager.registerDeferredUndo(
            withTarget: stableOwner,
            expiresAfter: duration,
            undo: { _ in
                guard let currentOwner = self.currentOwner else { return }
                undo(currentOwner)
            },
            redo: { _ in
                guard let currentOwner = self.currentOwner else { return }
                redo(currentOwner)
            },
            schedule: schedule)
    }
}
