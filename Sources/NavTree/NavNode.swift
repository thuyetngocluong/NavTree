import SwiftUI

/// Awaiter pha "disappeared": giữ continuation + kết quả được chốt tại thời điểm màn bị gỡ.
/// @unchecked Sendable: `result` chỉ được mutate trên MainActor trước khi resume;
/// deinit của node/stack (nonisolated) resume phần còn sót với exclusive access.
final class NavDisappearAwaiter: @unchecked Sendable {

    let continuation: CheckedContinuation<(any Sendable)?, Never>
    var result: (any Sendable)? = nil

    init(continuation: CheckedContinuation<(any Sendable)?, Never>) {
        self.continuation = continuation
    }

    func resume() {
        continuation.resume(returning: result)
    }
}

/// Một màn trong cây. `pushed` là màn được push ngay sau nó (cùng NavigationStack),
/// `presented` là các modal (sheet/cover/popover) mọc ra từ nó — mỗi modal là một NavStack riêng.
@MainActor
protocol NavNode: AnyObject {
    var id: UUID { get }
    var debugTitle: String { get }
    var pushed: (any NavNode)? { get set }
    var presented: [NavStack] { get set }
    /// Continuation của các `await push(until: .removed)` đang chờ node này bị gỡ khỏi cây.
    /// Giá trị resume là `any Sendable` type-erased — bên gọi `await` tự cast về type mong đợi.
    var removalContinuations: [CheckedContinuation<(any Sendable)?, Never>] { get set }
    /// Awaiter của các `await push(until: .disappeared)` — resume sau khi animation đóng xong.
    var disappearAwaiters: [NavDisappearAwaiter] { get set }
    /// Kết quả sẽ trả cho awaiter khi node bị gỡ (set bởi pop(returning:)).
    var pendingResult: (any Sendable)? { get set }
    /// View của node có đang hiển thị không (onAppear/onDisappear cập nhật).
    var isVisible: Bool { get set }
    /// Node đã bị gỡ khỏi cây chưa — để onDisappear phân biệt "bị pop" với "bị che".
    var isRemoved: Bool { get set }
    /// Điểm type-erase duy nhất của hệ thống — bên trong NavScreenHost đã concrete hoàn toàn.
    func erasedHost(stack: NavStack, tree: NavTree?) -> AnyView
}

extension NavNode {

    @discardableResult
    func push(_ screen: some NavScreen) -> any NavNode {
        let node = NavScreenNode(screen)
        pushed = node
        return node
    }

    /// Gắn modal trực tiếp vào node này, KHÔNG chuyển tiếp.
    /// Đường điều hướng thật đi qua `Navigator.present`, nơi chọn đích bằng `NavStack.topmostPresenter(from:)`.
    @discardableResult
    func present(_ screen: some NavScreen, style: NavPresentationStyle, config: NavPresentationConfig = .default) -> NavStack {
        let stack = NavStack(root: NavScreenNode(screen), style: style, owner: self, config: config)
        presented.append(stack)
        return stack
    }

    /// Màn sâu nhất còn hiển thị trong cây con tính từ node này (chính nó, đuôi push phía sau, và mọi modal
    /// treo trên chuỗi đó), `nil` nếu không màn nào hiển thị. Modal được ưu tiên vì nó nằm trên cùng.
    var deepestVisibleInSubtree: (any NavNode)? {
        var visibleInChain: (any NavNode)? = nil
        var modal: NavStack? = nil
        var cursor: (any NavNode)? = self
        while let node = cursor {
            if node.isVisible { visibleInChain = node }
            if let presented = node.presented.last { modal = presented }
            cursor = node.pushed
        }
        return modal?.root.deepestVisibleInSubtree ?? visibleInChain
    }

    /// - Parameter handoff: màn còn hiển thị sẽ nhận awaiter `.disappeared` nếu chính node này đã khuất
    ///   (ví dụ bị fullScreenCover che). Phải tính TRƯỚC khi cây con bị gỡ.
    func resumeRemoval(handoff: (any NavNode)? = nil) {
        isRemoved = true
        let result = pendingResult
        pendingResult = nil

        let continuations = removalContinuations
        removalContinuations = []
        continuations.forEach { $0.resume(returning: result) }

        // Chốt kết quả cho pha disappeared — chỉ khi node có kết quả thật,
        // để không ghi đè result của awaiter được stack dismiss chuyển sang.
        if let result {
            disappearAwaiters.forEach { $0.result = result }
        }
        // Node đã khuất: nếu trong cây con bị gỡ cùng lúc còn màn đang hiển thị (modal đè lên) thì chờ
        // animation đóng của màn đó; không có thì không còn animation nào liên quan — resume luôn.
        if !isVisible {
            if let handoff, handoff !== self {
                handoff.disappearAwaiters.append(contentsOf: disappearAwaiters)
                disappearAwaiters = []
            } else {
                resumeDisappear()
            }
        }
    }

    /// Gọi khi view của node đã khuất hẳn (onDisappear sau khi node bị gỡ).
    func resumeDisappear() {
        let awaiters = disappearAwaiters
        disappearAwaiters = []
        awaiters.forEach { $0.resume() }
    }

    /// Node này vừa bị gỡ khỏi cây: resume mọi awaiter của cả subtree
    /// (đuôi push phía sau + mọi modal treo dưới, đệ quy qua didSet của presented).
    func resumeRemovedSubtree() {
        var node: (any NavNode)? = self
        while let n = node {
            // Tính đích bàn giao trước khi gỡ modal của n (lúc đó cây con còn nguyên).
            let handoff = n.isVisible || n.disappearAwaiters.isEmpty ? nil : n.deepestVisibleInSubtree
            n.presented = []
            n.resumeRemoval(handoff: handoff)
            node = n.pushed
        }
    }
}

/// Node concrete bọc một màn cụ thể.
@MainActor
@Observable
final class NavScreenNode<Screen: NavScreen>: NavNode {

    let id = UUID()
    let screen: Screen

    var pushed: (any NavNode)? {
        didSet {
            guard let old = oldValue, old !== pushed else { return }
            old.resumeRemovedSubtree()
        }
    }

    var presented: [NavStack] = [] {
        didSet {
            for old in oldValue where !presented.contains(where: { $0 === old }) {
                old.resumeRemovedStack()
            }
        }
    }

    @ObservationIgnored var removalContinuations: [CheckedContinuation<(any Sendable)?, Never>] = []

    @ObservationIgnored var disappearAwaiters: [NavDisappearAwaiter] = []

    @ObservationIgnored var pendingResult: (any Sendable)? = nil

    @ObservationIgnored var isVisible = false

    @ObservationIgnored var isRemoved = false

    init(_ screen: Screen) {
        self.screen = screen
    }

    deinit {
        // Lưới an toàn: cây bị deallocate khi vẫn còn awaiter treo.
        removalContinuations.forEach { $0.resume(returning: nil) }
        disappearAwaiters.forEach { $0.resume() }
    }

    var debugTitle: String {
        String(describing: Screen.self)
    }

    var sheetStack: NavStack? {
        get { presented.first { $0.style == .sheet } }
        set { if newValue == nil { presented.removeAll { $0.style == .sheet } } }
    }

    var coverStack: NavStack? {
        get { presented.first { $0.style == .fullScreenCover } }
        set { if newValue == nil { presented.removeAll { $0.style == .fullScreenCover } } }
    }

    var popoverStack: NavStack? {
        get { presented.first { $0.style == .popover } }
        set { if newValue == nil { presented.removeAll { $0.style == .popover } } }
    }

    func erasedHost(stack: NavStack, tree: NavTree?) -> AnyView {
        AnyView(NavScreenHost(node: self, navigator: Navigator(stack: stack, node: self, tree: tree)))
    }
}

struct AnyNavNode: Identifiable, Hashable {

    let base: any NavNode
    let id: UUID

    @MainActor
    init(base: any NavNode) {
        self.base = base
        self.id = base.id
    }

    static func == (lhs: AnyNavNode, rhs: AnyNavNode) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
