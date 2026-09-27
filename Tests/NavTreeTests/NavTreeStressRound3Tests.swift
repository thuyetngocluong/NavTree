import Testing
import SwiftUI
@testable import NavTree

// MARK: - Fixtures (round 3: NavTree-level fuzz with invariant checks)

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

/// Counts started / resumed awaiters. No `await task.value`, so the test never hangs.
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

/// Every (stack, node) still in the tree, in traversal order.
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
        #expect(!node.isRemoved, "removed screen still in tree, \(context)")
        for modal in node.presented {
            #expect(modal.owner === node, "wrong owner, \(context)")
            #expect(modal.style != nil, "modal has no style, \(context)")
        }
    }
    // A NavigationStack can present only one modal; with tabs, one modal for the whole TabView.
    for stack in stacks.values where stack.tabs == nil {
        #expect(modalCount(inChainOf: stack) <= 1, "stack has >1 modal, \(context)")
    }
    if case .tabs(let tabs) = tree.root {
        let total = tabs.tabs.map { modalCount(inChainOf: $0.stack) }.reduce(0, +)
        #expect(total <= 1, "TabView has >1 modal, \(context)")
    }
    for stack in stacks.values {
        var length = 0
        var cursor = stack.root.pushed
        while let node = cursor { length += 1; cursor = node.pushed }
        #expect(stack.path.count == length, "path out of sync with pushed chain, \(context)")
    }
    // tree.current must be the top screen of the uncovered context.
    let current = tree.current
    #expect(current.node != nil, "current is empty, \(context)")
    #expect(current.node?.isRemoved == false, "current points to a removed screen, \(context)")
    if let stack = current.stack {
        #expect(current.node === stack.top, "current is not top, \(context)")
        #expect(stack.coveringModal == nil, "current is covered by a modal, \(context)")
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
            tree.selectTab(rng.next(4)) // includes out-of-range indexes
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
            // SwiftUI writes back some stale path.
            if !pathSnapshots.isEmpty {
                let (stack, path) = pathSnapshots[rng.next(pathSnapshots.count)]
                stack.path = path
            }
        case 12:
            // Swipe to dismiss: SwiftUI binding sets nil.
            pick.node.presented.removeAll { $0.style == styles[rng.next(3)] }
        case 13:
            // Zombie Navigator: every call must be a no-op.
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
                    #expect(tree.treeLines() == before, "zombie changed the tree, \(context)")
                }
            }
        case 14:
            // Deep link via tree.current.
            if rng.next(2) == 0 { syncPush(tree.current) } else { syncPresent(tree.current, styles[rng.next(3)]) }
        default:
            tree.selectedTab = rng.next(3)
        }
        checkInvariants(tree, context)
    }

    // Drop the tree: every awaiter must resume (via removal or deinit), none may hang.
    zombiePool.removeAll()
    pathSnapshots.removeAll()
    treeHolder = nil
    for _ in 0..<5 { await settle() }
    #expect(weakTree == nil, "tree was not released, seed \(seed)")
    #expect(ledger.finished == ledger.started, "pending awaiters: \(ledger.started - ledger.finished)/\(ledger.started), seed \(seed)")
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
