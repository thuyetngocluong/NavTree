import SwiftUI

public enum NavBranchKind: String, Sendable {
    case sheet
    case fullScreenCover
    case popover
}

/// Awaiter pha "disappeared": giữ continuation + kết quả được chốt tại thời điểm màn bị gỡ.
/// @unchecked Sendable: `result` chỉ được mutate trên MainActor trước khi resume;
/// deinit của node/branch (nonisolated) resume phần còn sót với exclusive access.
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

@MainActor
protocol NavNode: AnyObject {
    var id: UUID { get }
    var debugTitle: String { get }
    var next: (any NavNode)? { get set }
    var presents: [NavBranch] { get set }
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
    /// Điểm type-erase duy nhất của hệ thống — bên trong NavNodeHost đã concrete hoàn toàn.
    func erasedHost(branch: NavBranch, root: NavBranch, forest: NavForest?) -> AnyView
}

extension NavNode {

    var presentationLeaf: any NavNode {
        guard let presented = presents.last else { return self }
        return presented.current.presentationLeaf
    }

    @discardableResult
    func push(_ screen: some NavScreen) -> any NavNode {
        let item = NavNodeItem(screen)
        next = item
        return item
    }

    /// Node đang present sẵn thì tự chuyển tiếp xuống ngữ cảnh sâu nhất,
    /// vì một view trong SwiftUI không thể present hai modal cùng lúc.
    @discardableResult
    func present(_ screen: some NavScreen, kind: NavBranchKind, config: NavPresentationConfig = .default) -> NavBranch {
        let target = presentationLeaf
        let branch = NavBranch(root: NavNodeItem(screen), kind: kind, owner: target, config: config)
        target.presents.append(branch)
        return branch
    }

    func resumeRemoval() {
        isRemoved = true
        let result = pendingResult
        pendingResult = nil

        let continuations = removalContinuations
        removalContinuations = []
        continuations.forEach { $0.resume(returning: result) }

        // Chốt kết quả cho pha disappeared — chỉ khi node có kết quả thật,
        // để không ghi đè result của awaiter được nhánh dismiss chuyển sang.
        if let result {
            disappearAwaiters.forEach { $0.result = result }
        }
        // Node đang bị che (không visible) thì không còn animation nào của riêng nó — resume luôn.
        if !isVisible {
            resumeDisappear()
        }
    }

    /// Gọi khi view của node đã khuất hẳn (onDisappear sau khi node bị gỡ).
    func resumeDisappear() {
        let awaiters = disappearAwaiters
        disappearAwaiters = []
        awaiters.forEach { $0.resume() }
    }

    /// Node này vừa bị gỡ khỏi cây: resume mọi awaiter của cả subtree
    /// (đuôi push phía sau + mọi nhánh present treo dưới, đệ quy qua didSet của presents).
    func resumeRemovedSubtree() {
        var node: (any NavNode)? = self
        while let n = node {
            n.presents = []
            n.resumeRemoval()
            node = n.next
        }
    }
}

@MainActor
@Observable
final class NavNodeItem<Screen: NavScreen>: NavNode {

    let id = UUID()
    let screen: Screen

    var next: (any NavNode)? {
        didSet {
            guard let old = oldValue, old !== next else { return }
            old.resumeRemovedSubtree()
        }
    }

    var presents: [NavBranch] = [] {
        didSet {
            for old in oldValue where !presents.contains(where: { $0 === old }) {
                old.resumeRemovedBranch()
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

    var sheetBranch: NavBranch? {
        get { presents.first { $0.kind == .sheet } }
        set { if newValue == nil { presents.removeAll { $0.kind == .sheet } } }
    }

    var coverBranch: NavBranch? {
        get { presents.first { $0.kind == .fullScreenCover } }
        set { if newValue == nil { presents.removeAll { $0.kind == .fullScreenCover } } }
    }

    var popoverBranch: NavBranch? {
        get { presents.first { $0.kind == .popover } }
        set { if newValue == nil { presents.removeAll { $0.kind == .popover } } }
    }

    func erasedHost(branch: NavBranch, root: NavBranch, forest: NavForest?) -> AnyView {
        AnyView(NavNodeHost(item: self, branch: branch, root: root, forest: forest))
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
