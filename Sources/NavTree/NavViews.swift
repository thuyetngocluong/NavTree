import SwiftUI

/// Gốc duy nhất của mọi view trong một Scene. Tự chọn cách render theo gốc của cây:
/// NavigationStack cho app không tab, TabView (mỗi tab một stack) cho app có tab bar.
///
/// - `init(tree:)`: cây do bên ngoài tạo và giữ (App, coordinator) — dùng được từ trước khi view xuất hiện.
/// - `init(root:)`: đường tắt, view tự tạo và giữ cây.
public struct NavRootView: View {

    private let externalTree: NavTree?

    /// Chỉ có giá trị khi view tự tạo cây. Cây truyền từ ngoài KHÔNG được lưu vào @State:
    /// @State giữ giá trị lần đầu mãi mãi, nên đổi sang cây mới (đăng xuất…) sẽ giữ cây cũ sống
    /// cùng mọi awaiter đang treo trong đó.
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
        // Luôn có một trong hai: init(tree:) set externalTree, init(root:) set ownedTree.
        if let tree = externalTree ?? ownedTree {
            Group {
                switch tree.root {
                case .stack(let stack):
                    NavStackView(stack: stack)
                case .tabs(let tabs):
                    NavTabsView(tabs: tabs)
                }
            }
            // Navigator "hạt giống" chỉ mang tree — NavStackView / NavScreenHost bổ sung phần còn lại.
            // Cây KHÔNG được đưa vào environment bằng tham chiếu mạnh (`.environment(tree)`):
            // UIKit/SwiftUI chụp environment vào cache (trait collection của thanh nổi, initialEnvironment
            // của NavigationStack) và giữ bản chụp đó lâu hơn view. Đọc cây qua `\.navTree` (weak).
            .environment(\.navigator, Navigator(tree: tree))
            // Cây mới = hệ thống điều hướng mới: không tái sử dụng NavigationStack / TabView của cây cũ.
            // NavigationStack (UIKitNavigationController) chụp environment lúc tạo và giữ suốt đời
            // (`navigationAuthority.initialEnvironment`, đo bằng `leaks --traceTree`), nên tái sử dụng
            // nó sẽ mang theo trạng thái của cây cũ.
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
        // Phòng thủ: closure của navigationDestination do SwiftUI lưu và có thể sống lâu hơn view này,
        // nên nó chỉ capture weak — `seed` là Navigator (weak sẵn), còn stack capture [weak].
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

/// View của một màn. Chỉ giữ mạnh node (cần cho binding sheet/cover/popover) và Navigator;
/// stack và tree đi qua Navigator dưới dạng weak — cây mới là chủ sở hữu.
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
