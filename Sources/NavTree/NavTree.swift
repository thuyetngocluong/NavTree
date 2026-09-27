import SwiftUI

/// What `NavTree.reset` pops.
public enum NavResetScope: Sendable {
    /// Pop every tab to its root, as on a fresh launch.
    case allTabs
    /// Pop only the selected tab; other tabs keep their stacks. The covering modal is still closed.
    case selectedTab
}

/// Weak node reference, to wait for a screen to close without keeping it alive.
@MainActor
struct NavWeakNode {
    weak var node: (any NavNode)?

    init(_ node: any NavNode) {
        self.node = node
    }
}

/// The whole navigation tree of one window. Its root is a NavStack (no tab bar) or NavTabs (tab bar).
///
/// Create it in a view inside `WindowGroup` and pass it to `NavRootView(tree:)`, one tree per window.
/// It works from `init`, so deep links, notifications and view models can use it before any screen appears.
@MainActor
@Observable
public final class NavTree {

    enum Root {
        case stack(NavStack)
        case tabs(NavTabs)
    }

    let root: Root

    /// App without a tab bar: the root is one NavigationStack.
    public init(root screen: some NavRootScreen) {
        root = .stack(NavStack(root: NavScreenNode(screen)))
    }

    /// App with a tab bar: the root is a TabView with one NavigationStack per tab.
    public init(root tabBar: some NavTabBarScreen) {
        root = .tabs(NavTabs(tabs: tabBar.content.map { Self.makeTab($0) }))
    }

    private static func makeTab(_ screen: some NavTabScreen) -> NavTab {
        NavTab(screen.tabTitle, systemImage: screen.tabSystemImage, root: NavScreenNode(screen))
    }

    var tabs: NavTabs? {
        if case .tabs(let tabs) = root { return tabs }
        return nil
    }

    /// The root stack, or the selected tab's stack.
    private var activeRootStack: NavStack? {
        switch root {
        case .stack(let stack): stack
        case .tabs(let tabs): tabs.selectedTab?.stack
        }
    }

    /// Navigator for what the user is looking at: selected tab, then deepest modal, then top screen.
    ///
    /// For code without `@Environment` (deep links, notifications, view models).
    /// Inside views prefer `@Environment(\.navigator)`.
    public var current: Navigator {
        guard let rootStack = activeRootStack else { return Navigator(tree: self) }
        let stack = rootStack.deepestVisibleStack
        return Navigator(stack: stack, node: stack.top, tree: self)
    }

    /// Index of the selected tab. Observable, so `onChange(of: tree.selectedTab)` works.
    /// Out-of-range values are ignored. Without a tab bar it is always 0 and setting it does nothing.
    public var selectedTab: Int {
        get {
            guard let tabs else { return 0 }
            return tabs.tabs.firstIndex { $0.id == tabs.selection } ?? 0
        }
        set {
            selectTab(newValue)
        }
    }

    /// Selects a tab by index (tab bar roots only).
    public func selectTab(_ index: Int) {
        guard let tabs, tabs.tabs.indices.contains(index) else { return }
        tabs.selection = tabs.tabs[index].id
    }

    // MARK: - Reset (deep links, universal links, notifications)

    /// Returns the tree to a clean state: closes the covering modal and pops stacks to their root.
    /// The selected tab is kept; set `selectedTab` afterwards.
    ///
    /// Pending `await push/present` calls in the removed part resume with `nil`.
    /// To present right after, use `reset(_:until: .disappeared)` so SwiftUI doesn't drop the new modal.
    /// Pushing right after needs no wait.
    public func reset(_ scope: NavResetScope = .allTabs) {
        _ = performReset(scope)
    }

    /// Like `reset(_:)`. With `.disappeared` it returns once every visible screen it removed has
    /// finished animating out; with `.removed` it returns right away.
    ///
    /// Waits on weak references only, so a released screen (view gone, window closed) ends the wait.
    public func reset(_ scope: NavResetScope = .allTabs, until moment: NavAwaitUntil) async {
        let closing = performReset(scope)
        guard moment == .disappeared else { return }
        for ref in closing {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<(any Sendable)?, Never>) in
                // Already hidden or released while waiting for an earlier one: nothing to wait for.
                guard let node = ref.node, node.isVisible else {
                    continuation.resume(returning: nil)
                    return
                }
                node.disappearAwaiters.append(NavDisappearAwaiter(continuation: continuation))
            }
        }
    }

    /// Closes the covering modal and pops stacks per `scope`. Returns the visible screens it removed (weak).
    private func performReset(_ scope: NavResetScope) -> [NavWeakNode] {
        let visibleBefore = allNodes().filter(\.isVisible).map(NavWeakNode.init)

        let stacks: [NavStack]
        let covering: NavStack?
        switch root {
        case .stack(let stack):
            stacks = [stack]
            covering = stack.presentedModal
        case .tabs(let tabs):
            switch scope {
            case .allTabs: stacks = tabs.tabs.map(\.stack)
            case .selectedTab: stacks = tabs.selectedTab.map { [$0.stack] } ?? []
            }
            // A modal covers the whole TabView whichever tab opened it, so always close it.
            covering = tabs.presentedModal
        }
        covering?.dismissSelf()
        stacks.forEach { $0.popToRoot() }

        return visibleBefore.filter { $0.node?.isRemoved == true }
    }

    /// Every node currently in the tree.
    private func allNodes() -> [any NavNode] {
        var out: [any NavNode] = []
        func visit(_ stack: NavStack) {
            var cursor: (any NavNode)? = stack.root
            while let node = cursor {
                out.append(node)
                node.presented.forEach(visit)
                cursor = node.pushed
            }
        }
        switch root {
        case .stack(let stack): visit(stack)
        case .tabs(let tabs): tabs.tabs.forEach { visit($0.stack) }
        }
        return out
    }

    /// The whole tree as text, for debugging.
    public func treeLines() -> [String] {
        switch root {
        case .stack(let stack): stack.treeLines()
        case .tabs(let tabs): tabs.treeLines()
        }
    }
}
