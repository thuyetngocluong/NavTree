import SwiftUI

/// Thời điểm resume của các API await.
public enum NavAwaitUntil: Sendable {
    /// Ngay khi màn bị gỡ khỏi cây (mặc định).
    case removed
    /// Sau khi animation đóng kết thúc (màn đã khuất hẳn).
    /// Màn bị gỡ khi đang bị che thì resume ngay lúc gỡ.
    case disappeared
}

/// Struct giữ nonisolated để @Entry tạo default value được; mọi API mutate đều @MainActor.
public struct Navigator {

    var branch: NavBranch? = nil
    var node: (any NavNode)? = nil
    var root: NavBranch? = nil
    var forest: NavForest? = nil

    /// Node còn sống trong cây không — chặn điều hướng "zombie" từ màn đã bị gỡ
    /// (ví dụ Task còn giữ navigator sau khi màn bị pop).
    @MainActor
    private var liveNode: (any NavNode)? {
        guard let node, !node.isRemoved else { return nil }
        return node
    }

    /// Push một màn ngay sau node hiện tại.
    @MainActor
    public func push(_ screen: some NavScreen) {
        liveNode?.push(screen)
    }

    /// Present một màn thành nhánh mới (luôn có NavigationStack riêng).
    @MainActor
    public func present(_ screen: some NavScreen, as kind: NavBranchKind, config: NavPresentationConfig = .default) {
        liveNode?.present(screen, kind: kind, config: config)
    }

    /// Push và treo cho tới khi màn đó bị gỡ khỏi cây
    /// (pop, popToRoot, hoặc nhánh chứa nó bị dismiss),
    /// hoặc tới khi animation đóng kết thúc nếu `until: .disappeared`.
    /// Kết quả trả về type-erased dạng `any Sendable` — bên gọi tự cast về type mong đợi.
    @discardableResult
    @MainActor
    public func push(_ screen: some NavScreen, until moment: NavAwaitUntil = .removed) async -> (any Sendable)? {
        guard let node = liveNode else { return nil }
        let pushed = node.push(screen)
        return await withCheckedContinuation { continuation in
            switch moment {
            case .removed:
                pushed.removalContinuations.append(continuation)
            case .disappeared:
                pushed.disappearAwaiters.append(NavDisappearAwaiter(continuation: continuation))
            }
        }
    }

    /// Present và treo cho tới khi nhánh đó bị dismiss
    /// (dismissBranch, vuốt tắt sheet, hoặc cả cành phía trên bị gỡ),
    /// hoặc tới khi animation đóng kết thúc nếu `until: .disappeared`.
    /// Kết quả trả về type-erased dạng `any Sendable` — bên gọi tự cast về type mong đợi.
    @discardableResult
    @MainActor
    public func present(_ screen: some NavScreen, as kind: NavBranchKind, config: NavPresentationConfig = .default, until moment: NavAwaitUntil = .removed) async -> (any Sendable)? {
        guard let node = liveNode else { return nil }
        let branch = node.present(screen, kind: kind, config: config)
        return await withCheckedContinuation { continuation in
            switch moment {
            case .removed:
                branch.dismissContinuations.append(continuation)
            case .disappeared:
                branch.disappearAwaiters.append(NavDisappearAwaiter(continuation: continuation))
            }
        }
    }

    /// Nhánh hiện tại có phải nhánh được present lên không (root / tab thì không).
    @MainActor
    public var isPresented: Bool {
        branch?.kind != nil
    }

    /// Pop màn hiện tại, kèm kết quả trả cho bên đang `await push` (nếu có).
    /// Đang ở màn đầu của nhánh present → dismiss cả nhánh.
    @MainActor
    public func pop(returning result: (any Sendable)? = nil) {
        guard let branch, let node else { return }
        branch.pop(node, returning: result)
    }

    /// Pop về màn đầu của nhánh hiện tại.
    @MainActor
    public func popToRoot() {
        branch?.popToRoot()
    }

    /// Đóng nhánh hiện tại (gỡ khỏi node cha), kèm kết quả trả cho bên đang `await present` (nếu có).
    @MainActor
    public func dismissBranch(returning result: (any Sendable)? = nil) {
        guard let branch else { return }
        branch.pendingResult = result
        branch.dismissSelf()
    }

    /// Chuyển tab theo index (chỉ có tác dụng trong NavTabBarScreen).
    @MainActor
    public func selectTab(_ index: Int) {
        guard let forest, forest.tabs.indices.contains(index) else { return }
        forest.selection = forest.tabs[index].id
    }

    /// Toàn bộ cây điều hướng, dạng text để quan sát / debug.
    @MainActor
    public func treeLines() -> [String] {
        if let forest {
            return forest.tabs.flatMap { tab -> [String] in
                let mark = tab.id == forest.selection ? "▶" : "•"
                return ["\(mark) [tab] \(tab.title)"] + tab.branch.treeLines(indent: "    ")
            }
        }
        return root?.treeLines() ?? []
    }
}

// So sánh theo identity để environment không invalidate oan.
extension Navigator: Equatable {
    public static func == (lhs: Navigator, rhs: Navigator) -> Bool {
        lhs.branch === rhs.branch && lhs.node === rhs.node && lhs.root === rhs.root && lhs.forest === rhs.forest
    }
}

public extension EnvironmentValues {
    @Entry var navigator = Navigator()
}
