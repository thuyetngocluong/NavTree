import SwiftUI

@MainActor
@Observable
final class NavBranch: Identifiable {

    let id = UUID()
    let kind: NavBranchKind?
    weak var owner: (any NavNode)?
    let root: any NavNode
    let config: NavPresentationConfig

    /// Continuation của các `await present` đang chờ nhánh này bị dismiss.
    /// Giá trị resume là `any Sendable` type-erased — bên gọi `await` tự cast về type mong đợi.
    @ObservationIgnored var dismissContinuations: [CheckedContinuation<(any Sendable)?, Never>] = []

    /// Awaiter của các `await present(until: .disappeared)` — resume sau khi animation đóng xong.
    @ObservationIgnored var disappearAwaiters: [NavDisappearAwaiter] = []

    /// Kết quả sẽ trả cho awaiter khi nhánh bị dismiss (set bởi dismissBranch(returning:)).
    @ObservationIgnored var pendingResult: (any Sendable)? = nil

    init(root: any NavNode, kind: NavBranchKind? = nil, owner: (any NavNode)? = nil, config: NavPresentationConfig = .default) {
        self.root = root
        self.kind = kind
        self.owner = owner
        self.config = config
    }

    deinit {
        // Lưới an toàn: cây bị deallocate khi vẫn còn awaiter treo.
        dismissContinuations.forEach { $0.resume(returning: nil) }
        disappearAwaiters.forEach { $0.resume() }
    }

    /// Nhánh vừa bị gỡ khỏi node cha: resume awaiter của nhánh + toàn bộ subtree bên trong.
    func resumeRemovedBranch() {
        let result = pendingResult
        pendingResult = nil

        let continuations = dismissContinuations
        dismissContinuations = []
        continuations.forEach { $0.resume(returning: result) }

        // Pha disappeared: chuyển awaiter sang node đang hiển thị của nhánh —
        // onDisappear của nó chính là lúc animation đóng kết thúc.
        // Không node nào visible (nhánh bị gỡ khi đang bị che) thì resume luôn.
        if !disappearAwaiters.isEmpty {
            let awaiters = disappearAwaiters
            disappearAwaiters = []
            awaiters.forEach { $0.result = result }
            let visibleTop = current
            if visibleTop.isVisible {
                visibleTop.disappearAwaiters.append(contentsOf: awaiters)
            } else {
                awaiters.forEach { $0.resume() }
            }
        }

        root.resumeRemovedSubtree()
    }

    var current: any NavNode {
        var node: any NavNode = root
        while let next = node.next { node = next }
        return node
    }

    /// Chuỗi `next` tính từ root; set (khi hệ thống pop/back) gắn lại chuỗi theo path mới.
    var path: [AnyNavNode] {
        get {
            var result: [AnyNavNode] = []
            var node = root.next
            while let n = node {
                result.append(AnyNavNode(base: n))
                node = n.next
            }
            return result
        }
        set {
            var current: any NavNode = root
            for wrapper in newValue {
                current.next = wrapper.base
                current = wrapper.base
            }
            current.next = nil
        }
    }

    func push(_ screen: some NavScreen) {
        current.push(screen)
    }

    /// Pop node là root của nhánh present → dismiss cả nhánh; root của nhánh gốc → no-op.
    func pop(_ node: any NavNode, returning result: (any Sendable)? = nil) {
        node.pendingResult = result
        if node === root {
            pendingResult = result
            dismissSelf()
            return
        }
        var prev: any NavNode = root
        while let n = prev.next {
            if n === node {
                prev.next = nil
                return
            }
            prev = n
        }
    }

    func popToRoot() {
        root.next = nil
    }

    func dismissSelf() {
        owner?.presents.removeAll { $0 === self }
    }

    func treeLines(edge: String = "root", indent: String = "") -> [String] {
        var lines: [String] = []
        var node: (any NavNode)? = root
        var isFirst = true
        while let n = node {
            lines.append("\(indent)[\(isFirst ? edge : "push")] \(n.debugTitle)")
            for branch in n.presents {
                let label: String = switch branch.kind {
                case .sheet: "sheet"
                case .fullScreenCover: "cover"
                case .popover: "popover"
                case nil: "root"
                }
                lines.append(contentsOf: branch.treeLines(edge: label, indent: indent + "    "))
            }
            isFirst = false
            node = n.next
        }
        return lines
    }
}
