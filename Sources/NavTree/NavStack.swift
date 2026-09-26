import SwiftUI

/// Cách một stack được present lên — tương tự `modalPresentationStyle` của UIKit.
public enum NavPresentationStyle: String, Sendable {
    case sheet
    case fullScreenCover
    case popover
}

/// Một `NavigationStack`: màn gốc `root` và chuỗi `pushed` phía sau nó.
/// Stack gốc của app có `style == nil`; stack được present có `style` và `owner` là node đã present nó.
@MainActor
@Observable
final class NavStack: Identifiable {

    let id = UUID()
    let style: NavPresentationStyle?
    weak var owner: (any NavNode)?
    /// TabView chứa stack này (chỉ có ở stack gốc của một tab).
    @ObservationIgnored weak var tabs: NavTabs?
    let root: any NavNode
    let config: NavPresentationConfig

    /// Continuation của các `await present` đang chờ stack này bị dismiss.
    /// Giá trị resume là `any Sendable` type-erased — bên gọi `await` tự cast về type mong đợi.
    @ObservationIgnored var dismissContinuations: [CheckedContinuation<(any Sendable)?, Never>] = []

    /// Awaiter của các `await present(until: .disappeared)` — resume sau khi animation đóng xong.
    @ObservationIgnored var disappearAwaiters: [NavDisappearAwaiter] = []

    /// Kết quả sẽ trả cho awaiter khi stack bị dismiss (set bởi dismiss(returning:)).
    @ObservationIgnored var pendingResult: (any Sendable)? = nil

    init(root: any NavNode, style: NavPresentationStyle? = nil, owner: (any NavNode)? = nil, config: NavPresentationConfig = .default) {
        self.root = root
        self.style = style
        self.owner = owner
        self.config = config
    }

    deinit {
        // Lưới an toàn: cây bị deallocate khi vẫn còn awaiter treo.
        dismissContinuations.forEach { $0.resume(returning: nil) }
        disappearAwaiters.forEach { $0.resume() }
    }

    /// Stack vừa bị gỡ khỏi node cha: resume awaiter của stack + toàn bộ subtree bên trong.
    func resumeRemovedStack() {
        let result = pendingResult
        pendingResult = nil

        // Tính trước khi gỡ cây con: màn còn hiển thị của modal này (sẽ chạy animation đóng).
        let visibleTarget = root.deepestVisibleInSubtree
        owner?.closingModalScreen = visibleTarget

        let continuations = dismissContinuations
        dismissContinuations = []
        continuations.forEach { $0.resume(returning: result) }

        // Pha disappeared: chuyển awaiter sang màn sâu nhất còn hiển thị trong cây con của stack —
        // gồm cả modal đè lên nó (một fullScreenCover làm màn bên dưới nhận onDisappear sớm,
        // nên chỉ nhìn màn trên cùng của stack sẽ resume khi cover vẫn đang chạy animation đóng).
        // onDisappear của màn đó chính là lúc animation đóng kết thúc.
        // Không màn nào hiển thị (stack bị gỡ khi đang bị che hẳn) thì resume luôn.
        if !disappearAwaiters.isEmpty {
            let awaiters = disappearAwaiters
            disappearAwaiters = []
            awaiters.forEach { $0.result = result }
            if let target = visibleTarget {
                target.disappearAwaiters.append(contentsOf: awaiters)
            } else {
                awaiters.forEach { $0.resume() }
            }
        }

        root.resumeRemovedSubtree()
    }

    /// Modal đang được present từ stack này, bất kể màn nào trong chuỗi push đã present nó.
    /// Một NavigationStack chỉ present được một modal tại một thời điểm, nên phải xét cả chuỗi,
    /// không chỉ màn trên cùng hay màn đang gọi.
    var presentedModal: NavStack? {
        var found: NavStack? = nil
        var node: (any NavNode)? = root
        while let n = node {
            if let modal = n.presented.last { found = modal }
            node = n.pushed
        }
        return found
    }

    /// Modal đang che ngữ cảnh của stack này: stack của một tab thì xét cả TabView
    /// (modal do tab khác mở vẫn che tab này), stack thường thì xét chính nó.
    var coveringModal: NavStack? {
        tabs?.presentedModal ?? presentedModal
    }

    /// Node nên nhận lệnh present khi `node` (thuộc stack này) muốn present:
    /// ngữ cảnh đang bị modal che thì chuyển tiếp vào modal đó (đệ quy tới tầng sâu nhất, về màn trên cùng của nó);
    /// chưa có thì chính `node`.
    func topmostPresenter(from node: any NavNode) -> any NavNode {
        guard let modal = coveringModal else { return node }
        return modal.topmostPresenter(from: modal.top)
    }

    /// Stack sâu nhất đang hiển thị tính từ stack này (đi theo modal che phủ từng tầng).
    var deepestVisibleStack: NavStack {
        var stack = self
        while let modal = stack.coveringModal { stack = modal }
        return stack
    }

    /// Màn trên cùng của stack (cuối chuỗi pushed).
    var top: any NavNode {
        var node: any NavNode = root
        while let next = node.pushed { node = next }
        return node
    }

    /// Chuỗi `pushed` tính từ root; set (khi hệ thống pop/back) gắn lại chuỗi theo path mới.
    var path: [AnyNavNode] {
        get {
            var result: [AnyNavNode] = []
            var node = root.pushed
            while let n = node {
                result.append(AnyNavNode(base: n))
                node = n.pushed
            }
            return result
        }
        set {
            // SwiftUI có thể ghi lại một path dựng từ giao diện đã cũ (ví dụ code pop rồi push màn mới
            // đúng lúc người dùng vuốt back). Path chứa màn đã bị gỡ là path cũ → bỏ qua cả lần ghi:
            // gắn lại màn đã gỡ thì nó hiện ra với nút chết, còn cắt đuôi thì xoá mất màn vừa push.
            // Model là nguồn sự thật; SwiftUI sẽ đọc lại path từ getter.
            guard !newValue.contains(where: { $0.base.isRemoved }) else { return }
            var current: any NavNode = root
            for wrapper in newValue {
                // So sánh identity để không bắn thông báo Observation thừa khi SwiftUI ghi lại path y hệt.
                if current.pushed !== wrapper.base {
                    current.pushed = wrapper.base
                }
                current = wrapper.base
            }
            if current.pushed != nil {
                current.pushed = nil
            }
        }
    }

    func push(_ screen: some NavScreen) {
        top.push(screen)
    }

    /// Pop node là root của stack present → dismiss cả stack; root của stack gốc → no-op.
    func pop(_ node: any NavNode, returning result: (any Sendable)? = nil) {
        node.pendingResult = result
        if node === root {
            pendingResult = result
            dismissSelf()
            return
        }
        var prev: any NavNode = root
        while let n = prev.pushed {
            if n === node {
                prev.pushed = nil
                return
            }
            prev = n
        }
    }

    func popToRoot() {
        root.pushed = nil
    }

    func dismissSelf() {
        owner?.presented.removeAll { $0 === self }
    }

    func treeLines(edge: String = "root", indent: String = "") -> [String] {
        var lines: [String] = []
        var node: (any NavNode)? = root
        var isFirst = true
        while let n = node {
            lines.append("\(indent)[\(isFirst ? edge : "push")] \(n.debugTitle)")
            for modal in n.presented {
                let label: String = switch modal.style {
                case .sheet: "sheet"
                case .fullScreenCover: "cover"
                case .popover: "popover"
                case nil: "root"
                }
                lines.append(contentsOf: modal.treeLines(edge: label, indent: indent + "    "))
            }
            isFirst = false
            node = n.pushed
        }
        return lines
    }
}
