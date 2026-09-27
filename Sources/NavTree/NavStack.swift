import SwiftUI

/// How a stack is presented, like UIKit's `modalPresentationStyle`.
public enum NavPresentationStyle: String, Sendable {
    case sheet
    case fullScreenCover
    case popover
}

/// One `NavigationStack`: a `root` screen and the `pushed` chain after it.
/// Root stacks have `style == nil`; presented stacks have a `style` and an `owner` (the presenting node).
@MainActor
@Observable
final class NavStack: Identifiable {

    let id = UUID()
    let style: NavPresentationStyle?
    weak var owner: (any NavNode)?
    /// The TabView holding this stack (tab root stacks only).
    @ObservationIgnored weak var tabs: NavTabs?
    let root: any NavNode
    let config: NavPresentationConfig

    /// `await present` callers waiting for this stack to be dismissed.
    @ObservationIgnored var dismissContinuations: [CheckedContinuation<(any Sendable)?, Never>] = []

    /// `await present(until: .disappeared)` callers, resumed after the close animation.
    @ObservationIgnored var disappearAwaiters: [NavDisappearAwaiter] = []

    /// Result handed to awaiters on dismissal (set by `dismiss(returning:)`).
    @ObservationIgnored var pendingResult: (any Sendable)? = nil

    init(root: any NavNode, style: NavPresentationStyle? = nil, owner: (any NavNode)? = nil, config: NavPresentationConfig = .default) {
        self.root = root
        self.style = style
        self.owner = owner
        self.config = config
    }

    deinit {
        // Safety net: released while awaiters are still pending.
        dismissContinuations.forEach { $0.resume(returning: nil) }
        disappearAwaiters.forEach { $0.resume() }
    }

    /// This stack was just removed from its owner: resume its awaiters and its whole subtree.
    func resumeRemovedStack() {
        let result = pendingResult
        pendingResult = nil

        // Before tearing down: the visible screen of this modal (it is about to animate out).
        let visibleTarget = root.deepestVisibleInSubtree
        owner?.closingModalScreen = visibleTarget

        let continuations = dismissContinuations
        dismissContinuations = []
        continuations.forEach { $0.resume(returning: result) }

        // `.disappeared`: hand awaiters to the deepest visible screen in the subtree, including a modal
        // on top (a fullScreenCover hides the screens below early). Its onDisappear marks the end of
        // the close animation. Nothing visible (stack was fully covered): resume now.
        if !disappearAwaiters.isEmpty {
            let awaiters = disappearAwaiters
            disappearAwaiters = []
            awaiters.forEach { $0.result = result }
            if let target = visibleTarget {
                target.disappearAwaiters.append(contentsOf: awaiters)
            } else {
                awaiters.forEach { $0.resume() }
            }
        }

        root.resumeRemovedSubtree()
    }

    /// The modal presented from any screen of this stack's push chain.
    /// A NavigationStack can present only one modal at a time, so the whole chain counts.
    var presentedModal: NavStack? {
        var found: NavStack? = nil
        var node: (any NavNode)? = root
        while let n = node {
            if let modal = n.presented.last { found = modal }
            node = n.pushed
        }
        return found
    }

    /// The modal covering this stack. For a tab stack the whole TabView counts,
    /// since a modal opened from another tab covers this one too.
    var coveringModal: NavStack? {
        tabs?.presentedModal ?? presentedModal
    }

    /// Where a present from `node` (in this stack) should land: inside the covering modal,
    /// recursively down to the deepest one's top screen; otherwise `node` itself.
    func topmostPresenter(from node: any NavNode) -> any NavNode {
        guard let modal = coveringModal else { return node }
        return modal.topmostPresenter(from: modal.top)
    }

    /// The deepest visible stack, following covering modals down.
    var deepestVisibleStack: NavStack {
        var stack = self
        while let modal = stack.coveringModal { stack = modal }
        return stack
    }

    /// The top screen (end of the pushed chain).
    var top: any NavNode {
        var node: any NavNode = root
        while let next = node.pushed { node = next }
        return node
    }

    /// The pushed chain after root. SwiftUI sets it on back gestures; the setter relinks the chain.
    var path: [AnyNavNode] {
        get {
            var result: [AnyNavNode] = []
            var node = root.pushed
            while let n = node {
                result.append(AnyNavNode(base: n))
                node = n.pushed
            }
            return result
        }
        set {
            // A path containing a removed screen was built from stale UI (e.g. code popped and pushed
            // while the user swiped back). Ignore the whole write: re-attaching would show a dead screen,
            // truncating would drop the new one. The model wins; SwiftUI re-reads the getter.
            guard !newValue.contains(where: { $0.base.isRemoved }) else { return }
            var current: any NavNode = root
            for wrapper in newValue {
                // Skip identical assignments to avoid spurious Observation updates.
                if current.pushed !== wrapper.base {
                    current.pushed = wrapper.base
                }
                current = wrapper.base
            }
            if current.pushed != nil {
                current.pushed = nil
            }
        }
    }

    func push(_ screen: some NavScreen) {
        top.push(screen)
    }

    /// Popping a presented stack's root dismisses the stack; popping a root stack's root is a no-op.
    func pop(_ node: any NavNode, returning result: (any Sendable)? = nil) {
        node.pendingResult = result
        if node === root {
            pendingResult = result
            dismissSelf()
            return
        }
        var prev: any NavNode = root
        while let n = prev.pushed {
            if n === node {
                prev.pushed = nil
                return
            }
            prev = n
        }
    }

    func popToRoot() {
        root.pushed = nil
    }

    func dismissSelf() {
        owner?.presented.removeAll { $0 === self }
    }

    func treeLines(edge: String = "root", indent: String = "") -> [String] {
        var lines: [String] = []
        var node: (any NavNode)? = root
        var isFirst = true
        while let n = node {
            lines.append("\(indent)[\(isFirst ? edge : "push")] \(n.debugTitle)")
            for modal in n.presented {
                let label: String = switch modal.style {
                case .sheet: "sheet"
                case .fullScreenCover: "cover"
                case .popover: "popover"
                case nil: "root"
                }
                lines.append(contentsOf: modal.treeLines(edge: label, indent: indent + "    "))
            }
            isFirst = false
            node = n.pushed
        }
        return lines
    }
}
