import SwiftUI

/// Giữ root duy nhất của app để `Navigator.current` truy cập được từ ngoài view
/// (deep link, push notification, view model...).
///
/// Chỉ đăng ký từ `body`/`onAppear` — KHÔNG đăng ký trong `init` của view, vì
/// `@State(initialValue:)` khởi tạo lại object mỗi lần view struct được dựng
/// và chỉ giữ lần đầu; đăng ký trong init sẽ ghi nhận instance bị loại bỏ.
@MainActor
enum NavRegistry {

    private(set) static var forest: NavForest?
    private(set) static var rootBranch: NavBranch?

    static func register(forest newForest: NavForest) {
        guard forest !== newForest else { return }
        assert(
            forest == nil && rootBranch == nil,
            "NavTree hỗ trợ đúng một root cho mỗi app — đã có root khác được đăng ký."
        )
        forest = newForest
        rootBranch = nil
    }

    static func register(rootBranch newRoot: NavBranch) {
        guard rootBranch !== newRoot else { return }
        assert(
            forest == nil && rootBranch == nil,
            "NavTree hỗ trợ đúng một root cho mỗi app — đã có root khác được đăng ký."
        )
        rootBranch = newRoot
        forest = nil
    }

    /// Dùng trong test để reset giữa các case.
    static func reset() {
        forest = nil
        rootBranch = nil
    }
}

public extension Navigator {

    /// Navigator của ngữ cảnh người dùng đang thấy: tab đang chọn → nhánh modal
    /// sâu nhất → màn trên cùng của nhánh đó.
    ///
    /// Dùng khi không có `@Environment` (deep link, notification, view model).
    /// Trong view luôn ưu tiên `@Environment(\.navigator)`.
    /// Chưa có root nào hiển thị thì trả navigator rỗng (mọi lệnh là no-op an toàn).
    @MainActor
    static var current: Navigator {
        if let forest = NavRegistry.forest {
            let tab = forest.tabs.first { $0.id == forest.selection } ?? forest.tabs.first
            guard let tab else { return Navigator() }
            return deepest(from: tab.branch, root: tab.branch, forest: forest)
        }
        if let rootBranch = NavRegistry.rootBranch {
            return deepest(from: rootBranch, root: rootBranch, forest: nil)
        }
        return Navigator()
    }

    @MainActor
    private static func deepest(from branch: NavBranch, root: NavBranch, forest: NavForest?) -> Navigator {
        var branch = branch
        while let presented = branch.current.presents.last {
            branch = presented
        }
        return Navigator(branch: branch, node: branch.current, root: root, forest: forest)
    }
}
