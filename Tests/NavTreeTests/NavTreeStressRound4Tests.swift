import Testing
import SwiftUI
@testable import NavTree

// MARK: - Round 4: fuzz có mô phỏng vòng đời view của SwiftUI
//
// Round 3 để màn bị gỡ deallocate ngay, nên `deinit` resume mọi awaiter và che mất lỗi "resume sai lúc".
// Ở đây một `UISim` đóng vai SwiftUI: giữ mạnh các màn đang "mounted", tính màn nào hiển thị
// (sheet/popover không che màn bên dưới, fullScreenCover thì che; tab không chọn thì khuất),
// và bắn onAppear/onDisappear sau mỗi thao tác. Bất biến kiểm tra:
//   1. Không resume trước khi màn bị gỡ.
//   2. `.disappeared` không resume ngay lúc gỡ nếu cây con bị gỡ còn màn đang hiển thị.
//   3. Sau khi UI ổn định (mọi màn bị gỡ đã onDisappear), không awaiter nào của màn đã gỡ còn treo.

private struct S: NavScreen {
    var body: some View { Text("s") }
}

private struct R: NavRootScreen {
    var body: some View { Text("r") }
}

private struct TA: NavTabScreen {
    let tabTitle = "A"
    let tabSystemImage = "a.circle"
    var body: some View { Text("A") }
}

private struct TB: NavTabScreen {
    let tabTitle = "B"
    let tabSystemImage = "b.circle"
    var body: some View { Text("B") }
}

private struct TwoTabs: NavTabBarScreen {
    var content: [any NavTabScreen] {
        TA()
        TB()
    }
}

private struct SeededRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33) % bound
    }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(S())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ style: NavPresentationStyle) {
    nav.present(S(), as: style)
}

@MainActor
private func walk(_ tree: NavTree) -> [(stack: NavStack, node: any NavNode)] {
    var out: [(stack: NavStack, node: any NavNode)] = []
    func visit(_ stack: NavStack) {
        var cursor: (any NavNode)? = stack.root
        while let node = cursor {
            out.append((stack, node))
            for modal in node.presented { visit(modal) }
            cursor = node.pushed
        }
    }
    switch tree.root {
    case .stack(let stack): visit(stack)
    case .tabs(let tabs): tabs.tabs.forEach { visit($0.stack) }
    }
    return out
}

/// Duyệt độc lập với thư viện: cây con (đuôi push + mọi modal, đệ quy) có màn nào đang hiển thị không.
@MainActor
private func subtreeHasVisible(_ node: any NavNode) -> Bool {
    var cursor: (any NavNode)? = node
    while let current = cursor {
        if current.isVisible { return true }
        for modal in current.presented where subtreeHasVisible(modal.root) { return true }
        cursor = current.pushed
    }
    return false
}

/// Một awaiter đang theo dõi. `target` là màn được push, hoặc màn gốc của modal được present.
@MainActor
private final class Entry {
    let disappeared: Bool
    weak var target: (any NavNode)?
    var finished = false
    /// Cây con của target còn màn hiển thị ngay trước thao tác hiện tại.
    var hadVisibleBeforeOp = false

    init(disappeared: Bool) {
        self.disappeared = disappeared
    }
}

/// Đóng vai SwiftUI: giữ màn mounted, bắn onAppear/onDisappear.
@MainActor
private final class UISim {
    var mounted: [ObjectIdentifier: any NavNode] = [:]

    /// Màn đang hiển thị theo quy tắc của SwiftUI.
    func visibleNodes(_ tree: NavTree) -> [any NavNode] {
        var stack: NavStack
        switch tree.root {
        case .stack(let root): stack = root
        case .tabs(let tabs):
            guard let selected = tabs.selectedTab else { return [] }
            stack = selected.stack
        }
        var out: [any NavNode] = []
        while true {
            let modal = stack.coveringModal
            if modal?.style != .fullScreenCover {
                out.append(stack.top)       // sheet/popover không làm màn bên dưới onDisappear
            }
            guard let next = modal else { break }
            stack = next
        }
        return out
    }

    func step(_ tree: NavTree) {
        let visible = visibleNodes(tree)
        let visibleIDs = Set(visible.map { ObjectIdentifier($0) })
        // onDisappear cho màn không còn hiển thị (kể cả màn đã bị gỡ).
        for (id, node) in mounted where !visibleIDs.contains(id) {
            node.isVisible = false
            if node.isRemoved {
                node.resumeDisappear()
            }
            mounted[id] = nil
        }
        // onAppear cho màn mới hiển thị.
        for node in visible where !node.isVisible {
            node.isVisible = true
            mounted[ObjectIdentifier(node)] = node
        }
        for node in visible {
            mounted[ObjectIdentifier(node)] = node
        }
    }
}

@MainActor
private func runLifecycleStorm(makeTree: () -> NavTree, seed: UInt64, steps: Int) async {
    var rng = SeededRandom(state: seed)
    var entries: [Entry] = []
    var zombies: [Navigator] = []
    var snapshots: [(NavStack, [AnyNavNode])] = []
    let sim = UISim()
    var holder: NavTree? = makeTree()
    weak var weakTree: NavTree? = holder
    let styles: [NavPresentationStyle] = [.sheet, .fullScreenCover, .popover]

    if let tree = holder { sim.step(tree) }

    for step in 0..<steps {
        guard let tree = holder else { break }
        let all = walk(tree)
        let pick = all[rng.next(all.count)]
        let nav = Navigator(stack: pick.stack, node: pick.node, tree: tree)
        if rng.next(4) == 0 { zombies.append(nav) }
        let op = rng.next(14)
        let context = "seed \(seed) step \(step) op \(op)"

        for entry in entries where !entry.finished {
            entry.hadVisibleBeforeOp = entry.target.map(subtreeHasVisible) ?? false
        }
        let finishedBefore = Set(entries.indices.filter { entries[$0].finished })
        let countBefore = entries.count

        switch op {
        case 0, 1:
            syncPush(nav)
        case 2:
            syncPresent(nav, styles[rng.next(3)])
        case 3:
            nav.pop(returning: step)
        case 4:
            nav.popToRoot()
        case 5:
            nav.dismiss(returning: step)
        case 6:
            tree.selectTab(rng.next(3))
        case 7, 8:
            let entry = Entry(disappeared: rng.next(3) != 0)
            entries.append(entry)
            let moment: NavAwaitUntil = entry.disappeared ? .disappeared : .removed
            if op == 7 {
                Task {
                    _ = await nav.push(S(), until: moment)
                    entry.finished = true
                }
                await settle()
                entry.target = pick.node.isRemoved ? nil : pick.node.pushed
            } else {
                let style = styles[rng.next(3)]
                Task {
                    _ = await nav.present(S(), as: style, until: moment)
                    entry.finished = true
                }
                await settle()
                // Present luôn chuyển tới ngữ cảnh sâu nhất → modal mới là stack của tree.current.
                entry.target = pick.node.isRemoved ? nil : tree.current.stack?.root
            }
        case 9:
            snapshots.append((pick.stack, pick.stack.path))
        case 10:
            if !snapshots.isEmpty {
                let (stack, path) = snapshots[rng.next(snapshots.count)]
                stack.path = path
            }
        case 11:
            // Vuốt tắt modal đang hiển thị (chỉ modal trên cùng mới vuốt được).
            let current = tree.current
            if let stack = current.stack, stack.style == .sheet || stack.style == .popover {
                stack.owner?.presented.removeAll { $0 === stack }
            }
        case 12:
            if !zombies.isEmpty {
                let zombie = zombies[rng.next(zombies.count)]
                if zombie.node == nil || zombie.node?.isRemoved == true {
                    let before = tree.treeLines()
                    switch rng.next(4) {
                    case 0: syncPush(zombie)
                    case 1: zombie.pop()
                    case 2: zombie.popToRoot()
                    default: zombie.dismiss()
                    }
                    #expect(tree.treeLines() == before, "zombie đổi cây — \(context)")
                }
            }
        default:
            if rng.next(2) == 0 { syncPush(tree.current) } else { syncPresent(tree.current, styles[rng.next(3)]) }
        }
        await settle()

        // Bất biến 1 + 2: xét awaiter có sẵn trước thao tác, vừa resume trong thao tác này (trước khi UI chạy).
        for index in 0..<countBefore where entries[index].finished && !finishedBefore.contains(index) {
            let entry = entries[index]
            if let target = entry.target {
                #expect(target.isRemoved, "resume khi màn còn trong cây — \(context)")
            }
            if entry.disappeared {
                #expect(!entry.hadVisibleBeforeOp, "`.disappeared` resume sớm khi còn màn hiển thị — \(context)")
            }
        }

        sim.step(tree)
        await settle()

        // Bất biến 3: UI đã ổn định → awaiter của màn đã gỡ không được treo.
        for entry in entries where !entry.finished {
            if let target = entry.target {
                #expect(!target.isRemoved, "awaiter treo sau khi màn đã gỡ và khuất — \(context)")
            } else {
                Issue.record("awaiter treo, màn đã giải phóng — \(context)")
            }
        }
        // Không có màn nào còn trong cây mà bị đánh dấu đã gỡ.
        for (_, node) in walk(tree) {
            #expect(!node.isRemoved, "màn đã gỡ còn trong cây — \(context)")
        }
    }

    zombies.removeAll()
    snapshots.removeAll()
    sim.mounted.removeAll()
    holder = nil
    for _ in 0..<5 { await settle() }
    #expect(weakTree == nil, "cây không được giải phóng — seed \(seed)")
    let hanging = entries.filter { !$0.finished }.count
    #expect(hanging == 0, "awaiter treo sau khi huỷ cây — seed \(seed)")
}

@MainActor
struct LifecycleFuzzRound4Tests {

    @Test(arguments: [UInt64(11), 101, 0xBEEF, 0xD00D, 31337, 2024])
    func stackRootLifecycleStorm(seed: UInt64) async {
        await runLifecycleStorm(makeTree: { NavTree(root: R()) }, seed: seed, steps: 600)
    }

    @Test(arguments: [UInt64(12), 202, 0xCAFE, 0xF00D, 4242, 2025])
    func tabRootLifecycleStorm(seed: UInt64) async {
        await runLifecycleStorm(makeTree: { NavTree(root: TwoTabs()) }, seed: seed, steps: 600)
    }
}
