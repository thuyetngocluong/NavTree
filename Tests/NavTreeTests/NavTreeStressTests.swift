import Testing
import SwiftUI
@testable import NavTree

// MARK: - Fixtures

private struct DummyScreen: NavScreen {
    var body: some View { Text("dummy") }
}

/// Cho task con (await push/present) chạy tới điểm suspension trên MainActor.
@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
private func makeBranch() -> (NavBranch, Navigator) {
    let root = NavNodeItem(DummyScreen())
    let branch = NavBranch(root: root)
    let nav = Navigator(branch: branch, node: root, root: branch, forest: nil)
    return (branch, nav)
}

@MainActor
private func navigator(for node: any NavNode, in branch: NavBranch) -> Navigator {
    Navigator(branch: branch, node: node, root: branch, forest: nil)
}

// Helper sync để gọi đúng overload không-async từ trong hàm test async.
@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(DummyScreen())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ kind: NavBranchKind) {
    nav.present(DummyScreen(), as: kind)
}

// LCG tất định để fuzz có thể tái lập.
private struct SeededRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33) % bound
    }
}

// MARK: - Cấu trúc cây

@MainActor
struct TreeStructureTests {

    @Test func pushStormThenPopToRoot() {
        let (branch, _) = makeBranch()
        for _ in 0..<200 {
            branch.push(DummyScreen())
        }
        #expect(branch.path.count == 200)
        branch.popToRoot()
        #expect(branch.path.isEmpty)
        #expect(branch.root.next == nil)
    }

    @Test func pathSetterReattachesChain() {
        let (branch, _) = makeBranch()
        for _ in 0..<10 { branch.push(DummyScreen()) }
        let keep = Array(branch.path.prefix(4))
        branch.path = keep
        #expect(branch.path.count == 4)
        #expect(branch.path.map(\.id) == keep.map(\.id))
        branch.path = []
        #expect(branch.root.next == nil)
    }

    @Test func popMiddleNodeCutsTail() {
        let (branch, _) = makeBranch()
        for _ in 0..<5 { branch.push(DummyScreen()) }
        let middle = branch.path[2].base
        branch.pop(middle)
        #expect(branch.path.count == 2)
    }

    @Test func popRemovedNodeIsNoop() {
        let (branch, _) = makeBranch()
        branch.push(DummyScreen())
        let node = branch.path[0].base
        branch.pop(node)
        branch.pop(node) // lần 2: node đã ra khỏi cây
        #expect(branch.path.isEmpty)
    }

    @Test func presentForwardsToDeepestLeaf() {
        let (branch, nav) = makeBranch()
        nav.present(DummyScreen(), as: .sheet)
        nav.present(DummyScreen(), as: .sheet) // node gốc đã có sheet → forward xuống leaf
        let firstSheet = branch.root.presents.first
        #expect(branch.root.presents.count == 1)
        #expect(firstSheet?.root.presents.count == 1)
    }

    @Test func coverForwardsOnTopOfSheet() {
        let (branch, nav) = makeBranch()
        nav.present(DummyScreen(), as: .sheet)
        nav.present(DummyScreen(), as: .fullScreenCover)
        let sheet = branch.root.presents.first
        #expect(sheet?.kind == .sheet)
        #expect(sheet?.root.presents.first?.kind == .fullScreenCover)
    }

    @Test func dismissBranchPrunesNestedSubtree() {
        let (branch, nav) = makeBranch()
        nav.present(DummyScreen(), as: .sheet)
        let sheet = branch.root.presents[0]
        sheet.push(DummyScreen())
        sheet.push(DummyScreen())
        let innerNav = navigator(for: sheet.current, in: sheet)
        innerNav.present(DummyScreen(), as: .fullScreenCover)
        sheet.dismissSelf()
        #expect(branch.root.presents.isEmpty)
        #expect(branch.treeLines().count == 1)
    }

    @Test func nodesDeallocateAfterPop() {
        let (branch, _) = makeBranch()
        weak var weakNode: AnyObject?
        do {
            branch.push(DummyScreen())
            weakNode = branch.path[0].base
        }
        #expect(weakNode != nil)
        branch.popToRoot()
        #expect(weakNode == nil)
    }

    @Test func branchDeallocatesAfterDismiss() {
        let (branch, nav) = makeBranch()
        weak var weakBranch: NavBranch?
        nav.present(DummyScreen(), as: .sheet)
        weakBranch = branch.root.presents.first
        #expect(weakBranch != nil)
        weakBranch?.dismissSelf()
        #expect(branch.root.presents.isEmpty)
        #expect(weakBranch == nil)
    }
}

// MARK: - Await / continuation

@MainActor
struct AwaitTests {

    @Test func awaitPushResumesOnPop() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.push(DummyScreen()) }
        await settle()
        #expect(branch.path.count == 1)
        branch.popToRoot()
        let result = await task.value
        #expect(result == nil)
    }

    @Test func awaitPushReceivesResult() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.push(DummyScreen()) }
        await settle()
        let pushedNav = navigator(for: branch.current, in: branch)
        pushedNav.pop(returning: "42")
        let result = await task.value
        #expect(result as? String == "42")
    }

    @Test func awaitPresentReceivesResultOnDismiss() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.present(DummyScreen(), as: .sheet) }
        await settle()
        let sheet = branch.root.presents[0]
        let sheetNav = navigator(for: sheet.root, in: sheet)
        sheetNav.dismissBranch(returning: "done")
        let result = await task.value
        #expect(result as? String == "done")
    }

    @Test func popAtBranchRootResolvesPresentAwaiter() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.present(DummyScreen(), as: .sheet) }
        await settle()
        let sheet = branch.root.presents[0]
        let sheetNav = navigator(for: sheet.root, in: sheet)
        sheetNav.pop(returning: "via-pop") // pop ở màn đầu nhánh present = dismiss
        let result = await task.value
        #expect(result as? String == "via-pop")
        #expect(branch.root.presents.isEmpty)
    }

    @Test func allAwaitersResumeWhenSubtreeCollapses() async {
        let (branch, nav) = makeBranch()
        var tasks: [Task<(any Sendable)?, Never>] = []
        for _ in 0..<5 {
            let current = branch.current
            let currentNav = navigator(for: current, in: branch)
            tasks.append(Task { await currentNav.push(DummyScreen()) })
            await settle()
        }
        let midNode = branch.path[2].base
        let midNav = navigator(for: midNode, in: branch)
        tasks.append(Task { await midNav.present(DummyScreen(), as: .sheet) })
        await settle()

        nav.popToRoot()
        for task in tasks {
            let result = await task.value
            #expect(result == nil)
        }
        #expect(branch.path.isEmpty)
        #expect(branch.root.presents.isEmpty)
    }

    @Test func replacingTailResumesOldAwaiter() async {
        let (branch, nav) = makeBranch()
        let first = Task { await nav.push(DummyScreen()) }
        await settle()
        let second = Task { await nav.push(DummyScreen()) }
        await settle()
        let firstResult = await first.value
        #expect(firstResult == nil)
        #expect(branch.path.count == 1)
        branch.popToRoot()
        _ = await second.value
    }

    @Test func zombiePushFromRemovedNodeReturnsImmediately() async {
        let (branch, nav) = makeBranch()
        syncPush(nav)
        let removed = branch.path[0].base
        let removedNav = navigator(for: removed, in: branch)
        branch.popToRoot()
        let result = await removedNav.push(DummyScreen())
        #expect(result == nil)
        #expect(branch.path.isEmpty)
        let presentResult = await removedNav.present(DummyScreen(), as: .sheet)
        #expect(presentResult == nil)
        #expect(branch.root.presents.isEmpty)
    }

    @Test func disappearedAwaiterResumesImmediatelyWhenNodeInvisible() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.push(DummyScreen(), until: .disappeared) }
        await settle()
        let pushedNav = navigator(for: branch.current, in: branch)
        pushedNav.pop(returning: "gone")
        let result = await task.value
        #expect(result as? String == "gone")
    }

    @Test func disappearedAwaiterWaitsForVisibleNode() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.push(DummyScreen(), until: .disappeared) }
        await settle()
        let pushed = branch.current
        pushed.isVisible = true
        let pushedNav = navigator(for: pushed, in: branch)
        pushedNav.pop(returning: "animated")
        await settle()
        #expect(pushed.isRemoved)
        #expect(!pushed.disappearAwaiters.isEmpty)
        pushed.isVisible = false
        pushed.resumeDisappear()
        let result = await task.value
        #expect(result as? String == "animated")
    }

    @Test func branchDisappearedTransfersToVisibleTop() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.present(DummyScreen(), as: .sheet, until: .disappeared) }
        await settle()
        let sheet = branch.root.presents[0]
        sheet.push(DummyScreen())
        let top = sheet.current
        top.isVisible = true
        sheet.pendingResult = "closed"
        sheet.dismissSelf()
        await settle()
        #expect(!top.disappearAwaiters.isEmpty)
        top.isVisible = false
        top.resumeDisappear()
        let result = await task.value
        #expect(result as? String == "closed")
    }
}

// MARK: - Fuzz tất định

@MainActor
struct FuzzTests {

    @Test func randomOperationStormKeepsTreeConsistent() async {
        let (rootBranch, _) = makeBranch()
        var rng = SeededRandom(state: 0xDEADBEEF)
        var awaitTasks: [Task<(any Sendable)?, Never>] = []

        func liveBranches() -> [NavBranch] {
            var result: [NavBranch] = []
            func walk(_ branch: NavBranch) {
                result.append(branch)
                var node: (any NavNode)? = branch.root
                while let n = node {
                    for presented in n.presents { walk(presented) }
                    node = n.next
                }
            }
            walk(rootBranch)
            return result
        }

        for i in 0..<500 {
            let branches = liveBranches()
            let branch = branches[rng.next(branches.count)]
            let nav = navigator(for: branch.current, in: branch)
            switch rng.next(7) {
            case 0, 1:
                syncPush(nav)
            case 2:
                syncPresent(nav, [.sheet, .fullScreenCover, .popover][rng.next(3)])
            case 3:
                nav.pop(returning: i)
            case 4:
                nav.popToRoot()
            case 5:
                nav.dismissBranch(returning: i)
            default:
                let node = branch.current
                let nodeNav = navigator(for: node, in: branch)
                awaitTasks.append(Task { await nodeNav.push(DummyScreen()) })
                await settle()
            }
            let lines = rootBranch.treeLines()
            #expect(!lines.isEmpty)
            var count = 0
            var node = rootBranch.root.next
            while let n = node { count += 1; node = n.next }
            #expect(rootBranch.path.count == count)
        }

        rootBranch.popToRoot()
        rootBranch.root.presents = []
        for task in awaitTasks {
            _ = await task.value
        }
        #expect(rootBranch.treeLines().count == 1)
    }
}
