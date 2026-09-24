import SwiftUI

/// Entry point cho app không dùng tab bar.
public struct NavRootView: View {

    @State private var branch: NavBranch

    @MainActor
    public init(root: some NavRootScreen) {
        _branch = State(initialValue: NavBranch(root: NavNodeItem(root)))
    }

    public var body: some View {
        NavBranchView(branch: branch)
            .onAppear { NavRegistry.register(rootBranch: branch) }
    }
}

/// Thân ngầm của NavTabBarScreen: dựng forest từ content và giữ nó sống qua các lần render.
struct NavTabBarHost: View {

    @State private var forest: NavForest

    @MainActor
    init(tabs: [any NavTabScreen]) {
        _forest = State(initialValue: NavForest(tabs: tabs.map { Self.makeTab($0) }))
    }

    @MainActor
    private static func makeTab(_ screen: some NavTabScreen) -> NavTab {
        NavTab(screen.tabTitle, systemImage: screen.tabSystemImage, root: NavNodeItem(screen))
    }

    var body: some View {
        NavForestView(forest: forest)
            .onAppear { NavRegistry.register(forest: forest) }
    }
}

struct NavForestView: View {

    @Bindable var forest: NavForest

    var body: some View {
        TabView(selection: $forest.selection) {
            ForEach(forest.tabs) { tab in
                NavBranchView(branch: tab.branch)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab.id)
            }
        }
        // Navigator "hạt giống" chỉ mang forest — NavBranchView con tự lần ra phần còn lại.
        .environment(\.navigator, Navigator(forest: forest))
    }
}

struct NavBranchView: View {

    @Bindable var branch: NavBranch

    @Environment(\.navigator) private var parentNav

    var body: some View {
        let root = parentNav.root ?? branch
        let forest = parentNav.forest
        NavigationStack(path: $branch.path) {
            branch.root.erasedHost(branch: branch, root: root, forest: forest)
                .navigationDestination(for: AnyNavNode.self) { node in
                    node.base.erasedHost(branch: branch, root: root, forest: forest)
                }
        }
    }
}

struct NavNodeHost<Screen: NavScreen>: View {

    @Bindable var item: NavNodeItem<Screen>
    var branch: NavBranch
    var root: NavBranch
    var forest: NavForest?

    var body: some View {
        item.screen
            .onAppear {
                item.isVisible = true
            }
            .onDisappear {
                item.isVisible = false
                if item.isRemoved {
                    item.resumeDisappear()
                }
            }
            .sheet(item: $item.sheetBranch) { presented in
                NavBranchView(branch: presented)
                    .modifier(NavPresentationModifier(config: presented.config))
            }
            .fullScreenCover(item: $item.coverBranch) { presented in
                NavBranchView(branch: presented)
            }
            .popover(item: $item.popoverBranch) { presented in
                NavBranchView(branch: presented)
                    .modifier(NavPresentationModifier(config: presented.config))
            }
            .environment(\.navigator, Navigator(branch: branch, node: item, root: root, forest: forest))
    }
}

/// Section debug: in cây điều hướng hiện tại — nhúng được vào List của mọi màn.
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
