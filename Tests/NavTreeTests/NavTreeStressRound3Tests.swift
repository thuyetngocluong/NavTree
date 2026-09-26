import Testing
import SwiftUI
@testable import NavTree

// MARK: - Fixtures (round 3: fuzz cấp NavTree với kiểm tra bất biến)

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

private struct TC: NavTabScreen {
    let tabTitle = "C"
    let tabSystemImage = "c.circle"
    var body: some View { Text("C") }
}

private struct ThreeTabs: NavTabBarScreen {
    var content: [any NavTabScreen] {
        TA()
        TB()
        TC()
    }
}

private struct SeededRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33) % bound
    }
}

/// Đếm awaiter đã bắt đầu / đã resume — không `await task.value` để test không bao giờ treo.
@MainActor
private final class AwaitLedger {
    var started = 0
    var finished = 0
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

/// Mọi (stack, node) còn trong cây, theo thứ tự duyệt.
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

@MainActor
private func modalCount(inChainOf stack: NavStack) -> Int {
    var count = 0
    var cursor: (any NavNode)? = stack.root
    while let node = cursor {
        count += node.presented.count
        cursor = node.pushed
    }
    return count
}

@MainActor
private func checkInvariants(_ tree: NavTree, _ context: String) {
    let all = walk(tree)
    var stacks: [ObjectIdentifier: NavStack] = [:]
    for (stack, node) in all {
        stacks[ObjectIdentifier(stack)] = stack
        #expect(!node.isRemoved, "màn đã gỡ còn trong cây — \(context)")
        for modal in node.presented {
            #expect(modal.owner === node, "owner sai — \(context)")
            #expect(modal.style != nil, "modal không có style — \(context)")
        }
    }
    // Một NavigationStack chỉ present được một modal; với tab là một modal cho cả TabView.
    for stack in stacks.values where stack.tabs == nil {
        #expect(modalCount(inChainOf: stack) <= 1, "stack có >1 modal — \(context)")
    }
    if case .tabs(let tabs) = tree.root {
        let total = tabs.tabs.map { modalCount(inChainOf: $0.stack) }.reduce(0, +)
        #expect(total <= 1, "TabView có >1 modal — \(context)")
    }
    for stack in stacks.values {
        var length = 0
        var cursor = stack.root.pushed
        while let node = cursor { length += 1; cursor = node.pushed }
        #expect(stack.path.count == length, "path lệch chuỗi pushed — \(context)")
    }
    // tree.current phải là màn trên cùng của ngữ cảnh không bị che.
    let current = tree.current
    #expect(current.node != nil, "current rỗng — \(context)")
    #expect(current.node?.isRemoved == false, "current trỏ màn đã gỡ — \(context)")
    if let stack = current.stack {
        #expect(current.node === stack.top, "current không phải top — \(context)")
        #expect(stack.coveringModal == nil, "current đang bị modal che — \(context)")
    }
}

@MainActor
private func runStorm(makeTree: () -> NavTree, seed: UInt64, steps: Int) async {
    var rng = SeededRandom(state: seed)
    let ledger = AwaitLedger()
    var zombiePool: [Navigator] = []
    var pathSnapshots: [(NavStack, [AnyNavNode])] = []
    var treeHolder: NavTree? = makeTree()
    weak var weakTree: NavTree? = treeHolder
    let styles: [NavPresentationStyle] = [.sheet, .fullScreenCover, .popover]

    for step in 0..<steps {
        guard let tree = treeHolder else { break }
        let all = walk(tree)
        let pick = all[rng.next(all.count)]
        let nav = Navigator(stack: pick.stack, node: pick.node, tree: tree)
        if rng.next(4) == 0 { zombiePool.append(nav) }
        let op = rng.next(16)
        let context = "seed \(seed) step \(step) op \(op)"

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
            tree.selectTab(rng.next(4)) // có cả index ngoài phạm vi
        case 7:
            pick.node.isVisible.toggle()
        case 8:
            let moment: NavAwaitUntil = rng.next(2) == 0 ? .removed : .disappeared
            ledger.started += 1
            Task {
                _ = await nav.push(S(), until: moment)
                ledger.finished += 1
            }
            await settle()
        case 9:
            let moment: NavAwaitUntil = rng.next(2) == 0 ? .removed : .disappeared
            let style = styles[rng.next(3)]
            ledger.started += 1
            Task {
                _ = await nav.present(S(), as: style, until: moment)
                ledger.finished += 1
            }
            await settle()
        case 10:
            pathSnapshots.append((pick.stack, pick.stack.path))
        case 11:
            // SwiftUI ghi lại một path cũ bất kỳ.
            if !pathSnapshots.isEmpty {
                let (stack, path) = pathSnapshots[rng.next(pathSnapshots.count)]
                stack.path = path
            }
        case 12:
            // Vuốt tắt: binding của SwiftUI set nil.
            pick.node.presented.removeAll { $0.style == styles[rng.next(3)] }
        case 13:
            // Navigator zombie: mọi lệnh phải là no-op.
            if !zombiePool.isEmpty {
                let zombie = zombiePool[rng.next(zombiePool.count)]
                if zombie.node == nil || zombie.node?.isRemoved == true {
                    let before = tree.treeLines()
                    switch rng.next(5) {
                    case 0: syncPush(zombie)
                    case 1: syncPresent(zombie, styles[rng.next(3)])
                    case 2: zombie.pop(returning: "zombie")
                    case 3: zombie.popToRoot()
                    default: zombie.dismiss(returning: "zombie")
                    }
                    #expect(tree.treeLines() == before, "zombie đổi cây — \(context)")
                }
            }
        case 14:
            // Deep link qua tree.current.
            if rng.next(2) == 0 { syncPush(tree.current) } else { syncPresent(tree.current, styles[rng.next(3)]) }
        default:
            tree.selectedTab = rng.next(3)
        }
        checkInvariants(tree, context)
    }

    // Huỷ cây: mọi awaiter phải resume (qua gỡ màn hoặc deinit), không cái nào treo.
    zombiePool.removeAll()
    pathSnapshots.removeAll()
    treeHolder = nil
    for _ in 0..<5 { await settle() }
    #expect(weakTree == nil, "cây không được giải phóng — seed \(seed)")
    #expect(ledger.finished == ledger.started, "awaiter treo: \(ledger.started - ledger.finished)/\(ledger.started) — seed \(seed)")
}

@MainActor
struct TreeFuzzRound3Tests {

    @Test(arguments: [UInt64(1), 42, 0xFEEDFACE, 0xABCDEF, 777])
    func stackRootStorm(seed: UInt64) async {
        await runStorm(makeTree: { NavTree(root: R()) }, seed: seed, steps: 800)
    }

    @Test(arguments: [UInt64(2), 43, 0xC0FFEE, 0x5EED, 888])
    func tabRootStorm(seed: UInt64) async {
        await runStorm(makeTree: { NavTree(root: ThreeTabs()) }, seed: seed, steps: 800)
    }
}
