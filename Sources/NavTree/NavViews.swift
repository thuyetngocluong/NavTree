import SwiftUI

/// The single root view of a window. Renders a NavigationStack, or a TabView with one stack per tab.
///
/// - `init(tree:)`: you own the tree (e.g. a scene root view), usable before any view appears.
/// - `init(root:)`: shortcut, the view creates and owns the tree.
public struct NavRootView: View {

    private let externalTree: NavTree?

    /// Set only when the view owns the tree. An external tree must NOT go into @State:
    /// @State keeps its first value forever, so swapping trees (e.g. logout) would keep the old one alive.
    @State private var ownedTree: NavTree?

    @MainActor
    public init(tree: NavTree) {
        externalTree = tree
        _ownedTree = State(initialValue: nil)
    }

    @MainActor
    public init(root: some NavRootScreen) {
        externalTree = nil
        _ownedTree = State(initialValue: NavTree(root: root))
    }

    @MainActor
    public init(root: some NavTabBarScreen) {
        externalTree = nil
        _ownedTree = State(initialValue: NavTree(root: root))
    }

    public var body: some View {
        // Exactly one is set: init(tree:) sets externalTree, init(root:) sets ownedTree.
        if let tree = externalTree ?? ownedTree {
            Group {
                switch tree.root {
                case .stack(let stack):
                    NavStackView(stack: stack)
                case .tabs(let tabs):
                    NavTabsView(tabs: tabs)
                }
            }
            // Seed navigator carries only the tree; NavStackView / NavScreenHost fill in the rest.
            // Never inject the tree strongly with `.environment(tree)`: SwiftUI/UIKit cache environment
            // snapshots beyond the views' lifetime, which kept old trees alive. Read it via `\.navTree` (weak).
            .environment(\.navigator, Navigator(tree: tree))
            // New tree, new hierarchy: never reuse the old NavigationStack/TabView, which keeps
            // the environment it was created with (found with `leaks --traceTree`).
            .id(ObjectIdentifier(tree))
        }
    }
}

struct NavTabsView: View {

    @Bindable var tabs: NavTabs

    var body: some View {
        TabView(selection: $tabs.selection) {
            ForEach(tabs.tabs) { tab in
                NavStackView(stack: tab.stack)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab.id)
            }
        }
    }
}

struct NavStackView: View {

    @Bindable var stack: NavStack

    @Environment(\.navigator) private var parentNav

    var body: some View {
        // SwiftUI stores the destination closure and may keep it longer than this view,
        // so it captures weakly: `seed` is a (weak) Navigator and `stack` is [weak].
        let seed = parentNav
        NavigationStack(path: $stack.path) {
            stack.root.erasedHost(stack: stack, tree: seed.tree)
                .navigationDestination(for: AnyNavNode.self) { [weak stack] node in
                    if let stack {
                        node.base.erasedHost(stack: stack, tree: seed.tree)
                    }
                }
        }
    }
}

/// View for one screen. Holds its node strongly (needed for the sheet/cover/popover bindings)
/// plus a Navigator; stack and tree are reached weakly through the Navigator.
struct NavScreenHost<Screen: NavScreen>: View {

    @Bindable var node: NavScreenNode<Screen>
    let navigator: Navigator

    var body: some View {
        node.screen
            .onAppear {
                node.isVisible = true
            }
            .onDisappear {
                node.isVisible = false
                if node.isRemoved {
                    node.resumeDisappear()
                }
            }
            .sheet(item: $node.sheetStack) { presented in
                NavStackView(stack: presented)
                    .modifier(NavPresentationModifier(config: presented.config))
            }
            .fullScreenCover(item: $node.coverStack) { presented in
                NavStackView(stack: presented)
            }
            .popover(item: $node.popoverStack) { presented in
                NavStackView(stack: presented)
                    .modifier(NavPresentationModifier(config: presented.config))
            }
            .environment(\.navigator, navigator)
    }
}

/// Debug section that prints the live navigation tree; drop it into any List.
public struct NavTreeSection: View {

    @Environment(\.navigator) private var nav

    public init() {}

    public var body: some View {
        Section("Cây điều hướng hiện tại") {
            ForEach(Array(nav.treeLines().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .lineLimit(1)
            }
        }
    }
}
