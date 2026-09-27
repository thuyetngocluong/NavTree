import SwiftUI

/// A pending `until: .disappeared` await: the continuation plus the result captured at removal.
/// @unchecked Sendable: `result` is only mutated on the MainActor before resuming;
/// a nonisolated deinit resumes leftovers with exclusive access.
final class NavDisappearAwaiter: @unchecked Sendable {

    let continuation: CheckedContinuation<(any Sendable)?, Never>
    var result: (any Sendable)? = nil

    init(continuation: CheckedContinuation<(any Sendable)?, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation.resume(returning: result)
    }
}

/// One screen in the tree. `pushed` is the next screen in the same NavigationStack;
/// `presented` holds the modals (sheet/cover/popover) opened from it, each its own NavStack.
@MainActor
protocol NavNode: AnyObject {
    var id: UUID { get }
    var debugTitle: String { get }
    var pushed: (any NavNode)? { get set }
    var presented: [NavStack] { get set }
    /// `await push(until: .removed)` callers waiting for this node to leave the tree.
    var removalContinuations: [CheckedContinuation<(any Sendable)?, Never>] { get set }
    /// `await push(until: .disappeared)` callers, resumed after the close animation.
    var disappearAwaiters: [NavDisappearAwaiter] { get set }
    /// Result handed to awaiters on removal (set by `pop(returning:)`).
    var pendingResult: (any Sendable)? { get set }
    /// Whether the node's view is on screen (updated by onAppear/onDisappear).
    var isVisible: Bool { get set }
    /// Whether the node has left the tree, so onDisappear can tell "popped" from "covered".
    var isRemoved: Bool { get set }
    /// Still-visible screen of a modal this node just closed (weak, cleared by that screen's onDisappear).
    /// If this node is removed in the same tick (e.g. dismiss then popToRoot), its `.disappeared`
    /// awaiters must still wait for that modal's close animation.
    var closingModalScreen: (any NavNode)? { get set }
    /// The only type-erasure point; everything inside NavScreenHost is concrete.
    func erasedHost(stack: NavStack, tree: NavTree?) -> AnyView
}

extension NavNode {

    @discardableResult
    func push(_ screen: some NavScreen) -> any NavNode {
        let node = NavScreenNode(screen)
        pushed = node
        return node
    }

    /// Attaches a modal directly to this node, with NO forwarding.
    /// Real navigation goes through `Navigator.present`, which picks the target via `NavStack.topmostPresenter(from:)`.
    @discardableResult
    func present(_ screen: some NavScreen, style: NavPresentationStyle, config: NavPresentationConfig = .default) -> NavStack {
        let stack = NavStack(root: NavScreenNode(screen), style: style, owner: self, config: config)
        presented.append(stack)
        return stack
    }

    /// Deepest visible screen in this node's subtree (itself, the pushed tail, and modals on that chain),
    /// or `nil` if nothing is visible. Modals win because they sit on top.
    var deepestVisibleInSubtree: (any NavNode)? {
        var visibleInChain: (any NavNode)? = nil
        var modal: NavStack? = nil
        var closingModal: (any NavNode)? = nil
        var cursor: (any NavNode)? = self
        while let node = cursor {
            if node.isVisible { visibleInChain = node }
            if let presented = node.presented.last {
                modal = presented
            } else if let closing = node.closingModalScreen, closing.isVisible {
                closingModal = closing          // left the tree but still animating out
            }
            cursor = node.pushed
        }
        return modal?.root.deepestVisibleInSubtree ?? closingModal ?? visibleInChain
    }

    /// - Parameter handoff: visible screen that takes over `.disappeared` awaiters when this node
    ///   is already hidden (e.g. under a fullScreenCover). Must be computed BEFORE the subtree is removed.
    func resumeRemoval(handoff: (any NavNode)? = nil) {
        isRemoved = true
        let result = pendingResult
        pendingResult = nil

        let continuations = removalContinuations
        removalContinuations = []
        continuations.forEach { $0.resume(returning: result) }

        // Only stamp a real result, so a result handed over by a dismissed stack isn't overwritten.
        if let result {
            disappearAwaiters.forEach { $0.result = result }
        }
        // Hidden node: wait for the visible screen closing with it, if any; otherwise nothing animates, resume now.
        if !isVisible {
            if let handoff, handoff !== self {
                handoff.disappearAwaiters.append(contentsOf: disappearAwaiters)
                disappearAwaiters = []
            } else {
                resumeDisappear()
            }
        }
    }

    /// Called once the node's view is gone (onDisappear after removal).
    func resumeDisappear() {
        let awaiters = disappearAwaiters
        disappearAwaiters = []
        awaiters.forEach { $0.resume() }
    }

    /// This node just left the tree: resume every awaiter in its subtree
    /// (pushed tail plus all modals, recursively via `presented`'s didSet).
    func resumeRemovedSubtree() {
        var node: (any NavNode)? = self
        while let n = node {
            // Pick the handoff target while n's subtree is still intact.
            let handoff = n.isVisible || n.disappearAwaiters.isEmpty ? nil : n.deepestVisibleInSubtree
            n.presented = []
            n.resumeRemoval(handoff: handoff)
            node = n.pushed
        }
    }
}

/// Concrete node wrapping one screen.
@MainActor
@Observable
final class NavScreenNode<Screen: NavScreen>: NavNode {

    let id = UUID()
    let screen: Screen

    var pushed: (any NavNode)? {
        didSet {
            guard let old = oldValue, old !== pushed else { return }
            old.resumeRemovedSubtree()
        }
    }

    var presented: [NavStack] = [] {
        didSet {
            for old in oldValue where !presented.contains(where: { $0 === old }) {
                old.resumeRemovedStack()
            }
        }
    }

    @ObservationIgnored var removalContinuations: [CheckedContinuation<(any Sendable)?, Never>] = []

    @ObservationIgnored var disappearAwaiters: [NavDisappearAwaiter] = []

    @ObservationIgnored var pendingResult: (any Sendable)? = nil

    @ObservationIgnored var isVisible = false

    @ObservationIgnored var isRemoved = false

    @ObservationIgnored weak var closingModalScreen: (any NavNode)?

    init(_ screen: Screen) {
        self.screen = screen
    }

    deinit {
        // Safety net: released while awaiters are still pending.
        removalContinuations.forEach { $0.resume(returning: nil) }
        disappearAwaiters.forEach { $0.resume() }
    }

    var debugTitle: String {
        String(describing: Screen.self)
    }

    var sheetStack: NavStack? {
        get { presented.first { $0.style == .sheet } }
        set { if newValue == nil { presented.removeAll { $0.style == .sheet } } }
    }

    var coverStack: NavStack? {
        get { presented.first { $0.style == .fullScreenCover } }
        set { if newValue == nil { presented.removeAll { $0.style == .fullScreenCover } } }
    }

    var popoverStack: NavStack? {
        get { presented.first { $0.style == .popover } }
        set { if newValue == nil { presented.removeAll { $0.style == .popover } } }
    }

    func erasedHost(stack: NavStack, tree: NavTree?) -> AnyView {
        AnyView(NavScreenHost(node: self, navigator: Navigator(stack: stack, node: self, tree: tree)))
    }
}

struct AnyNavNode: Identifiable, Hashable {

    let base: any NavNode
    let id: UUID

    @MainActor
    init(base: any NavNode) {
        self.base = base
        self.id = base.id
    }

    static func == (lhs: AnyNavNode, rhs: AnyNavNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
