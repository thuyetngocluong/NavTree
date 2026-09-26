import SwiftUI

/// Phạm vi của `NavTree.reset`.
public enum NavResetScope: Sendable {
    /// Pop mọi tab về gốc (như vừa mở app).
    case allTabs
    /// Chỉ pop tab đang chọn; các tab khác giữ nguyên stack. Modal đang che màn hình vẫn bị đóng.
    case selectedTab
}

/// Tham chiếu weak tới một node — để chờ màn đóng mà không giữ nó sống.
@MainActor
struct NavWeakNode {
    weak var node: (any NavNode)?

    init(_ node: any NavNode) {
        self.node = node
    }
}

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

    // MARK: - Reset (deep link / universal link / push notification)

    /// Đưa cây về trạng thái sạch: đóng modal đang che màn hình và pop các stack về màn gốc.
    /// Tab đang chọn giữ nguyên — deep link tự chọn tab sau đó.
    ///
    /// Mọi `await push/present` trong phần bị gỡ đều resume với `nil`.
    /// Muốn present ngay sau khi reset, dùng `reset(_:until: .disappeared)` để chờ animation đóng xong,
    /// tránh lỗi "modal mới không hiện" của SwiftUI. Push ngay sau reset thì không cần chờ.
    public func reset(_ scope: NavResetScope = .allTabs) {
        _ = performReset(scope)
    }

    /// Như `reset(_:)`, rồi treo cho tới khi (với `.disappeared`) mọi màn đang hiển thị bị gỡ
    /// đã chạy xong animation đóng. `.removed` trả về ngay sau khi gỡ.
    ///
    /// Chỉ giữ weak các màn cần chờ: màn bị giải phóng (view đã mất, cây bị huỷ) thì không chờ nữa.
    public func reset(_ scope: NavResetScope = .allTabs, until moment: NavAwaitUntil) async {
        let closing = performReset(scope)
        guard moment == .disappeared else { return }
        for ref in closing {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<(any Sendable)?, Never>) in
                // Màn đã khuất (hoặc đã giải phóng) trong lúc chờ màn trước → không còn gì để chờ.
                guard let node = ref.node, node.isVisible else {
                    continuation.resume(returning: nil)
                    return
                }
                node.disappearAwaiters.append(NavDisappearAwaiter(continuation: continuation))
            }
        }
    }

    /// Gỡ modal che màn hình + pop stack theo `scope`. Trả về các màn đang hiển thị vừa bị gỡ (weak).
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
            // Modal che cả TabView dù do tab nào mở, nên luôn đóng nó, kể cả với `.selectedTab`.
            covering = tabs.presentedModal
        }
        covering?.dismissSelf()
        stacks.forEach { $0.popToRoot() }

        return visibleBefore.filter { $0.node?.isRemoved == true }
    }

    /// Mọi node còn trong cây.
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

    /// Toàn bộ cây điều hướng, dạng text để quan sát / debug.
    public func treeLines() -> [String] {
        switch root {
        case .stack(let stack): stack.treeLines()
        case .tabs(let tabs): tabs.treeLines()
        }
    }
}
