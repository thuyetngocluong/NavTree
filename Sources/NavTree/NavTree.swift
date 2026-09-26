import SwiftUI

/// Toàn bộ cây điều hướng của một Scene — gốc là một NavStack (app không tab)
/// hoặc một NavTabs (app có tab bar).
///
/// Tạo ở tầng App (hoặc bất kỳ nơi nào sống lâu hơn view) rồi đưa vào `NavRootView(tree:)`.
/// Cây tồn tại ngay từ lúc khởi tạo, nên deep link / push notification / view model
/// dùng được trước cả khi màn đầu xuất hiện. Mỗi cửa sổ (Scene) nên có một NavTree riêng.
@MainActor
@Observable
public final class NavTree {

    enum Root {
        case stack(NavStack)
        case tabs(NavTabs)
    }

    let root: Root

    /// App không tab bar: gốc là một NavigationStack.
    public init(root screen: some NavRootScreen) {
        root = .stack(NavStack(root: NavScreenNode(screen)))
    }

    /// App có tab bar: gốc là TabView, mỗi tab một NavigationStack riêng.
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

    /// Stack đang là ngữ cảnh gốc của người dùng: stack gốc, hoặc stack của tab đang chọn.
    private var activeRootStack: NavStack? {
        switch root {
        case .stack(let stack): stack
        case .tabs(let tabs): tabs.selectedTab?.stack
        }
    }

    /// Navigator của ngữ cảnh người dùng đang thấy: tab đang chọn → modal sâu nhất → màn trên cùng.
    ///
    /// Dùng khi không có `@Environment` (deep link, notification, view model).
    /// Trong view luôn ưu tiên `@Environment(\.navigator)`.
    public var current: Navigator {
        guard let rootStack = activeRootStack else { return Navigator(tree: self) }
        let stack = rootStack.deepestVisibleStack
        return Navigator(stack: stack, node: stack.top, tree: self)
    }

    /// Index của tab đang chọn. Quan sát được (Observation), nên dùng được với
    /// `onChange(of: tree.selectedTab)` hoặc bind qua `$tree.selectedTab`.
    /// Gán index ngoài phạm vi thì bị bỏ qua. Gốc không phải tab bar: luôn là 0, gán là no-op.
    public var selectedTab: Int {
        get {
            guard let tabs else { return 0 }
            return tabs.tabs.firstIndex { $0.id == tabs.selection } ?? 0
        }
        set {
            selectTab(newValue)
        }
    }

    /// Chuyển tab theo index (chỉ có tác dụng khi gốc là tab bar).
    public func selectTab(_ index: Int) {
        guard let tabs, tabs.tabs.indices.contains(index) else { return }
        tabs.selection = tabs.tabs[index].id
    }

    /// Toàn bộ cây điều hướng, dạng text để quan sát / debug.
    public func treeLines() -> [String] {
        switch root {
        case .stack(let stack): stack.treeLines()
        case .tabs(let tabs): tabs.treeLines()
        }
    }
}
