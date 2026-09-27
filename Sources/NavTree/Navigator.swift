import SwiftUI

/// When an `await push/present` resumes.
public enum NavAwaitUntil: Sendable {
    /// As soon as the screen leaves the tree (default).
    case removed
    /// After the close animation finishes. Resumes at removal if nothing visible was closed.
    case disappeared
}

/// Navigation handle for ONE screen; push/pop/present/dismiss are relative to that screen.
/// Nonisolated so `@Entry` can build a default; every mutating API is `@MainActor`.
///
/// All references are weak: the tree owns the model. Strong refs would form the cycle
/// Task -> Navigator -> node -> child -> continuation -> Task during an await, so a torn-down
/// tree (root swap, window closed) would never be freed and its awaiters would never resume.
public struct Navigator {

    weak var stack: NavStack?
    weak var node: (any NavNode)?
    weak var tree: NavTree?

    init(stack: NavStack? = nil, node: (any NavNode)? = nil, tree: NavTree? = nil) {
        self.stack = stack
        self.node = node
        self.tree = tree
    }

    /// The node if it is still in the tree. Blocks "zombie" navigation from removed screens
    /// (e.g. a Task still holding the navigator after a pop).
    @MainActor
    private var liveNode: (any NavNode)? {
        guard let node, !node.isRemoved else { return nil }
        return node
    }

    /// Pushes a screen after this one.
    @MainActor
    public func push(_ screen: some NavScreen) {
        liveNode?.push(screen)
    }

    /// Presents a screen in a new stack (with its own NavigationStack).
    /// If a modal already covers this stack, it forwards into the deepest one:
    /// a NavigationStack can present only one modal at a time.
    @MainActor
    public func present(_ screen: some NavScreen, as style: NavPresentationStyle, config: NavPresentationConfig = .default) {
        presentTarget?.present(screen, style: style, config: config)
    }

    @MainActor
    private var presentTarget: (any NavNode)? {
        guard let node = liveNode else { return nil }
        return stack?.topmostPresenter(from: node) ?? node
    }

    /// Pushes and waits until the screen is removed (pop, popToRoot, its stack dismissed),
    /// or until its close animation ends with `until: .disappeared`.
    /// Returns the `pop(returning:)` value as `(any Sendable)?`; cast it at the call site.
    ///
    /// Cancelling the Task does NOT end the wait: the screen is still up, so an early `nil` would lie
    /// (e.g. `.task` is cancelled as soon as its own cover hides it). The wait always ends when the
    /// screen is removed or the tree is released.
    @discardableResult
    @MainActor
    public func push(_ screen: some NavScreen, until moment: NavAwaitUntil = .removed) async -> (any Sendable)? {
        // Strong refs live only inside this synchronous closure, never across the suspension,
        // so a released tree can deinit the child and resume the awaiter with nil.
        await withCheckedContinuation { continuation in
            guard let node = liveNode else {
                continuation.resume(returning: nil)
                return
            }
            let pushed = node.push(screen)
            switch moment {
            case .removed:
                pushed.removalContinuations.append(continuation)
            case .disappeared:
                pushed.disappearAwaiters.append(NavDisappearAwaiter(continuation: continuation))
            }
        }
    }

    /// Presents and waits until the stack is dismissed (dismiss, swipe-down, or an ancestor removed),
    /// or until its close animation ends with `until: .disappeared`.
    /// Returns the `dismiss(returning:)` value as `(any Sendable)?`; cast it at the call site.
    ///
    /// Cancelling the Task does NOT end the wait (see `push(_:until:)`).
    @discardableResult
    @MainActor
    public func present(_ screen: some NavScreen, as style: NavPresentationStyle, config: NavPresentationConfig = .default, until moment: NavAwaitUntil = .removed) async -> (any Sendable)? {
        await withCheckedContinuation { continuation in
            guard let target = presentTarget else {
                continuation.resume(returning: nil)
                return
            }
            let presented = target.present(screen, style: style, config: config)
            switch moment {
            case .removed:
                presented.dismissContinuations.append(continuation)
            case .disappeared:
                presented.disappearAwaiters.append(NavDisappearAwaiter(continuation: continuation))
            }
        }
    }

    /// Whether this screen is inside a modal (sheet/cover/popover), not a root or tab stack.
    @MainActor
    public var isPresented: Bool {
        stack?.style != nil
    }

    /// Pops this screen, handing `result` to an `await push` caller.
    /// On the first screen of a modal it dismisses the modal.
    @MainActor
    public func pop(returning result: (any Sendable)? = nil) {
        guard let stack, let node = liveNode else { return }
        stack.pop(node, returning: result)
    }

    /// Pops to the first screen of this stack.
    /// No-op from a removed screen, so a late Task can't pop screens opened afterwards.
    @MainActor
    public func popToRoot() {
        guard liveNode != nil else { return }
        stack?.popToRoot()
    }

    /// Closes the modal containing this screen, handing `result` to an `await present` caller.
    /// No-op on a root stack.
    @MainActor
    public func dismiss(returning result: (any Sendable)? = nil) {
        // A removed screen (e.g. popped out of the sheet) must not close the sheet the user is on.
        guard let stack, liveNode != nil else { return }
        stack.pendingResult = result
        stack.dismissSelf()
    }

    /// Selects a tab by index (tab bar roots only).
    @MainActor
    public func selectTab(_ index: Int) {
        tree?.selectTab(index)
    }

    /// The whole tree as text, for debugging.
    @MainActor
    public func treeLines() -> [String] {
        tree?.treeLines() ?? stack?.treeLines() ?? []
    }
}

// Identity comparison, so the environment value doesn't invalidate views needlessly.
extension Navigator: Equatable {
    public static func == (lhs: Navigator, rhs: Navigator) -> Bool {
        lhs.stack === rhs.stack && lhs.node === rhs.node && lhs.tree === rhs.tree
    }
}

public extension EnvironmentValues {
    @Entry var navigator = Navigator()

    /// The tree of the window containing this view, for whole-tree work (`current`, `selectedTab`, `reset`).
    /// Weak: the tree is owned by your scene root or `NavRootView`. `nil` outside a `NavRootView`.
    /// Reading its properties in `body` is still tracked by Observation.
    var navTree: NavTree? {
        navigator.tree
    }
}
