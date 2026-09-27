import Testing
import SwiftUI
@testable import NavTree

// MARK: - Round 4: fuzz with simulated SwiftUI view lifecycle
//
// Round 3 let removed screens deallocate at once, so `deinit` resumed every awaiter and hid "resumed at the wrong time" bugs.
// Here a `UISim` plays SwiftUI: it strongly holds "mounted" screens, computes which are visible
// (sheet/popover don't cover the screen below, fullScreenCover does; unselected tabs are hidden),
// and fires onAppear/onDisappear after each op. Invariants checked:
//   1. No resume before the screen is removed.
//   2. `.disappeared` doesn't resume at removal if the removed subtree still has a visible screen.
//   3. Once the UI settles (every removed screen got onDisappear), no awaiter of a removed screen is pending.

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

/// Library-independent walk: does the subtree (push tail + all modals, recursive) have a visible screen.
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

@MainActor
private final class Flag {
    var value = false
}

/// A tracked awaiter. `target` is the pushed screen, or the root screen of the presented modal.
@MainActor
private final class Entry {
    let disappeared: Bool
    weak var target: (any NavNode)?
    var finished = false
    /// Target's subtree had a visible screen right before the current op.
    var hadVisibleBeforeOp = false

    init(disappeared: Bool) {
        self.disappeared = disappeared
    }
}

/// Plays SwiftUI: holds mounted screens, fires onAppear/onDisappear.
@MainActor
private final class UISim {
    var mounted: [ObjectIdentifier: any NavNode] = [:]

    /// Visible screens per SwiftUI rules.
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
                out.append(stack.top)       // sheet/popover don't trigger onDisappear below
            }
            guard let next = modal else { break }
            stack = next
        }
        return out
    }

    func step(_ tree: NavTree) {
        let visible = visibleNodes(tree)
        let visibleIDs = Set(visible.map { ObjectIdentifier($0) })
        // onDisappear for screens no longer visible (including removed ones).
        for (id, node) in mounted where !visibleIDs.contains(id) {
            node.isVisible = false
            if node.isRemoved {
                node.resumeDisappear()
            }
            mounted[id] = nil
        }
        // onAppear for newly visible screens.
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
    var resetWaits: [Flag] = []
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
        let op = rng.next(16)
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
                // Present always forwards to the deepest context, so the new modal is tree.current's stack.
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
            // Swipe to dismiss the visible modal (only the top modal can be swiped).
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
                    #expect(tree.treeLines() == before, "zombie changed the tree, \(context)")
                }
            }
        case 13:
            if rng.next(2) == 0 { syncPush(tree.current) } else { syncPresent(tree.current, styles[rng.next(3)]) }
        case 14:
            tree.reset(rng.next(2) == 0 ? .allTabs : .selectedTab)
            #expect(tree.current.isPresented == false, "modal still present after reset, \(context)")
        default:
            let flag = Flag()
            resetWaits.append(flag)
            let scope: NavResetScope = rng.next(2) == 0 ? .allTabs : .selectedTab
            Task {
                await tree.reset(scope, until: .disappeared)
                flag.value = true
            }
        }
        await settle()

        // Invariants 1 + 2: awaiters that existed before the op and resumed during it (before the UI ran).
        for index in 0..<countBefore where entries[index].finished && !finishedBefore.contains(index) {
            let entry = entries[index]
            if let target = entry.target {
                #expect(target.isRemoved, "resumed while screen still in tree, \(context)")
            }
            if entry.disappeared {
                #expect(!entry.hadVisibleBeforeOp, "`.disappeared` resumed early while a screen was visible, \(context)")
            }
        }

        sim.step(tree)
        await settle()

        // Invariant 3: UI has settled, so awaiters of removed screens must not hang.
        for flag in resetWaits {
            #expect(flag.value, "reset(until: .disappeared) pending after UI settled, \(context)")
        }
        for entry in entries where !entry.finished {
            if let target = entry.target {
                #expect(!target.isRemoved, "awaiter pending after screen was removed and hidden, \(context)")
            } else {
                Issue.record("awaiter pending, screen already released, \(context)")
            }
        }
        // No screen still in the tree may be marked removed.
        for (_, node) in walk(tree) {
            #expect(!node.isRemoved, "removed screen still in tree, \(context)")
        }
    }

    zombies.removeAll()
    snapshots.removeAll()
    sim.mounted.removeAll()
    holder = nil
    for _ in 0..<5 { await settle() }
    #expect(weakTree == nil, "tree was not released, seed \(seed)")
    let hanging = entries.filter { !$0.finished }.count
    #expect(hanging == 0, "awaiters pending after tree was released, seed \(seed)")
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
