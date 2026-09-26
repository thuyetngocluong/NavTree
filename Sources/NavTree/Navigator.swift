import SwiftUI

/// Thời điểm resume của các API await.
public enum NavAwaitUntil: Sendable {
    /// Ngay khi màn bị gỡ khỏi cây (mặc định).
    case removed
    /// Sau khi animation đóng kết thúc (màn đã khuất hẳn).
    /// Màn bị gỡ khi đang bị che thì resume ngay lúc gỡ.
    case disappeared
}

/// Handle điều hướng của MỘT màn: mọi lệnh push/pop/present/dismiss đều tương đối so với màn đó.
/// Struct giữ nonisolated để @Entry tạo default value được; mọi API mutate đều @MainActor.
///
/// Mọi tham chiếu đều `weak`: cây mới là chủ sở hữu, Navigator chỉ là handle.
/// Nếu giữ mạnh, một `await push/present` đang treo sẽ tạo vòng
/// Task → Navigator → node → màn con → continuation → Task, khiến cả cây không bao giờ được giải phóng
/// và awaiter không bao giờ resume khi cây bị huỷ (đổi root, đóng cửa sổ).
public struct Navigator {

    weak var stack: NavStack?
    weak var node: (any NavNode)?
    weak var tree: NavTree?

    init(stack: NavStack? = nil, node: (any NavNode)? = nil, tree: NavTree? = nil) {
        self.stack = stack
        self.node = node
        self.tree = tree
    }

    /// Node còn sống trong cây không — chặn điều hướng "zombie" từ màn đã bị gỡ
    /// (ví dụ Task còn giữ navigator sau khi màn bị pop).
    @MainActor
    private var liveNode: (any NavNode)? {
        guard let node, !node.isRemoved else { return nil }
        return node
    }

    /// Push một màn ngay sau màn hiện tại.
    @MainActor
    public func push(_ screen: some NavScreen) {
        liveNode?.push(screen)
    }

    /// Present một màn thành stack mới (luôn có NavigationStack riêng).
    /// Stack chứa màn này đang có modal (dù do màn khác trong stack present) thì tự chuyển tiếp
    /// vào ngữ cảnh sâu nhất, vì một NavigationStack chỉ present được một modal cùng lúc.
    @MainActor
    public func present(_ screen: some NavScreen, as style: NavPresentationStyle, config: NavPresentationConfig = .default) {
        presentTarget?.present(screen, style: style, config: config)
    }

    @MainActor
    private var presentTarget: (any NavNode)? {
        guard let node = liveNode else { return nil }
        return stack?.topmostPresenter(from: node) ?? node
    }

    /// Push và treo cho tới khi màn đó bị gỡ khỏi cây
    /// (pop, popToRoot, hoặc stack chứa nó bị dismiss),
    /// hoặc tới khi animation đóng kết thúc nếu `until: .disappeared`.
    /// Kết quả trả về type-erased dạng `any Sendable` — bên gọi tự cast về type mong đợi.
    ///
    /// Huỷ Task KHÔNG kết thúc lệnh chờ: màn vẫn đang hiển thị nên trả `nil` sớm sẽ sai nghĩa
    /// (ví dụ `.task` bị huỷ ngay khi chính cover nó mở che lên). Lệnh chờ luôn kết thúc khi màn bị gỡ
    /// hoặc khi cây bị huỷ, nên thời gian treo bị giới hạn bởi vòng đời của màn.
    @discardableResult
    @MainActor
    public func push(_ screen: some NavScreen, until moment: NavAwaitUntil = .removed) async -> (any Sendable)? {
        // Mọi tham chiếu mạnh chỉ sống trong closure đồng bộ này, không vắt qua điểm treo —
        // để cây bị huỷ thì màn con deinit được và resume awaiter bằng nil.
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

    /// Present và treo cho tới khi stack đó bị dismiss
    /// (dismiss, vuốt tắt sheet, hoặc cả cành phía trên bị gỡ),
    /// hoặc tới khi animation đóng kết thúc nếu `until: .disappeared`.
    /// Kết quả trả về type-erased dạng `any Sendable` — bên gọi tự cast về type mong đợi.
    ///
    /// Huỷ Task KHÔNG kết thúc lệnh chờ: màn vẫn đang hiển thị nên trả `nil` sớm sẽ sai nghĩa
    /// (ví dụ `.task` bị huỷ ngay khi chính cover nó mở che lên). Lệnh chờ luôn kết thúc khi màn bị gỡ
    /// hoặc khi cây bị huỷ, nên thời gian treo bị giới hạn bởi vòng đời của màn.
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

    /// Màn hiện tại có nằm trong một modal (sheet/cover/popover) không — stack gốc / tab thì không.
    @MainActor
    public var isPresented: Bool {
        stack?.style != nil
    }

    /// Pop màn hiện tại, kèm kết quả trả cho bên đang `await push` (nếu có).
    /// Đang ở màn đầu của một modal → dismiss cả modal.
    @MainActor
    public func pop(returning result: (any Sendable)? = nil) {
        guard let stack, let node = liveNode else { return }
        stack.pop(node, returning: result)
    }

    /// Pop về màn đầu của stack hiện tại.
    /// Như mọi lệnh khác, no-op nếu màn này đã bị gỡ — một Task còn giữ navigator cũ
    /// không được phép pop những màn người dùng mở sau đó.
    @MainActor
    public func popToRoot() {
        guard liveNode != nil else { return }
        stack?.popToRoot()
    }

    /// Đóng modal đang chứa màn này (gỡ cả stack khỏi node đã present nó),
    /// kèm kết quả trả cho bên đang `await present` (nếu có). Ở stack gốc là no-op.
    @MainActor
    public func dismiss(returning result: (any Sendable)? = nil) {
        // Màn đã bị gỡ (ví dụ đã pop khỏi sheet) thì không được đóng sheet người dùng đang xem.
        guard let stack, liveNode != nil else { return }
        stack.pendingResult = result
        stack.dismissSelf()
    }

    /// Chuyển tab theo index (chỉ có tác dụng khi gốc cây là tab bar).
    @MainActor
    public func selectTab(_ index: Int) {
        tree?.selectTab(index)
    }

    /// Toàn bộ cây điều hướng, dạng text để quan sát / debug.
    @MainActor
    public func treeLines() -> [String] {
        tree?.treeLines() ?? stack?.treeLines() ?? []
    }
}

// So sánh theo identity để environment không invalidate oan.
extension Navigator: Equatable {
    public static func == (lhs: Navigator, rhs: Navigator) -> Bool {
        lhs.stack === rhs.stack && lhs.node === rhs.node && lhs.tree === rhs.tree
    }
}

public extension EnvironmentValues {
    @Entry var navigator = Navigator()

    /// Cây điều hướng của Scene chứa view này, cho các thao tác toàn cây (`current`, `selectedTab`…).
    /// Chỉ giữ weak — cây do `SceneRoot` / `NavRootView` sở hữu. `nil` ngoài một `NavRootView`.
    /// Đọc thuộc tính của nó trong `body` vẫn được Observation theo dõi như bình thường.
    var navTree: NavTree? {
        navigator.tree
    }
}
