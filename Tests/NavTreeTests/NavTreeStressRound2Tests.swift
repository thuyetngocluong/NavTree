import Testing
import SwiftUI
@testable import NavTree

// MARK: - Fixtures (round 2)

private struct DummyScreen: NavScreen {
    var body: some View { Text("dummy") }
}

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

@MainActor
private func syncPush(_ nav: Navigator) {
    nav.push(DummyScreen())
}

@MainActor
private func syncPresent(_ nav: Navigator, _ kind: NavBranchKind) {
    nav.present(DummyScreen(), as: kind)
}

private struct SeededRandom {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33) % bound
    }
}

private struct CustomResult: Sendable, Equatable {
    let code: Int
    let tag: String
}

// MARK: - Reentrancy: điều hướng tiếp ngay khi continuation resume

@MainActor
struct ReentrancyTests {

    @Test func pushAgainInsideResumedContinuation() async {
        let (branch, nav) = makeBranch()
        let task = Task {
            _ = await nav.push(DummyScreen())
            syncPush(nav)
        }
        await settle()
        branch.popToRoot()
        _ = await task.value
        await settle()
        #expect(branch.path.count == 1)
        branch.popToRoot()
        #expect(branch.path.isEmpty)
    }

    @Test func presentInsideResumedContinuation() async {
        let (branch, nav) = makeBranch()
        let task = Task {
            _ = await nav.present(DummyScreen(), as: .sheet)
            syncPresent(nav, .fullScreenCover)
        }
        await settle()
        branch.root.presents[0].dismissSelf()
        _ = await task.value
        await settle()
        #expect(branch.root.presents.count == 1)
        #expect(branch.root.presents[0].kind == .fullScreenCover)
        branch.root.presents[0].dismissSelf()
        #expect(branch.root.presents.isEmpty)
    }

    @Test func chainedAwaitsSequentially() async {
        let (branch, nav) = makeBranch()
        let task = Task { () -> [String] in
            var results: [String] = []
            for _ in 0..<3 {
                let r = await nav.push(DummyScreen())
                results.append((r as? String) ?? "nil")
            }
            return results
        }
        for expected in ["a", "b", "c"] {
            await settle()
            #expect(branch.path.count == 1)
            let topNav = navigator(for: branch.current, in: branch)
            topNav.pop(returning: expected)
        }
        let results = await task.value
        #expect(results == ["a", "b", "c"])
        #expect(branch.path.isEmpty)
    }
}

// MARK: - Đệ quy sâu & kích thước lớn

@MainActor
struct DeepNestingTests {

    @Test func threeHundredNestedBranchesDismissWithoutStackOverflow() {
        let (branch, _) = makeBranch()
        var node: any NavNode = branch.root
        for i in 0..<300 {
            let presented = node.present(DummyScreen(), kind: i % 2 == 0 ? .sheet : .fullScreenCover)
            presented.push(DummyScreen())
            node = presented.current
        }
        #expect(branch.treeLines().count == 1 + 300 * 2)
        branch.root.presents = []
        #expect(branch.treeLines().count == 1)
    }

    @Test func thousandNodeChainPopToRoot() {
        let (branch, _) = makeBranch()
        for _ in 0..<1000 { branch.push(DummyScreen()) }
        #expect(branch.path.count == 1000)
        branch.popToRoot()
        #expect(branch.path.isEmpty)
    }

    @Test func popMiddleNodePrunesTailPresents() async {
        let (branch, _) = makeBranch()
        for _ in 0..<6 { branch.push(DummyScreen()) }
        let tailNode = branch.path[4].base
        let tailNav = navigator(for: tailNode, in: branch)
        let task = Task { await tailNav.present(DummyScreen(), as: .sheet) }
        await settle()
        #expect(tailNode.presents.count == 1)
        branch.pop(branch.path[2].base)
        let result = await task.value
        #expect(result == nil)
        #expect(branch.path.count == 2)
    }
}

// MARK: - Kết quả: kiểu tuỳ ý, double-dismiss, mid-pop

@MainActor
struct ResultEdgeTests {

    @Test func customStructAndIntResults() async {
        let (branch, nav) = makeBranch()
        let pushTask = Task { await nav.push(DummyScreen()) }
        await settle()
        let custom = CustomResult(code: 7, tag: "vip")
        navigator(for: branch.current, in: branch).pop(returning: custom)
        #expect(await pushTask.value as? CustomResult == custom)

        let presentTask = Task { await nav.present(DummyScreen(), as: .sheet) }
        await settle()
        let sheet = branch.root.presents[0]
        navigator(for: sheet.root, in: sheet).dismissBranch(returning: 999)
        #expect(await presentTask.value as? Int == 999)
    }

    @Test func secondDismissDoesNotOverrideResult() async {
        let (branch, nav) = makeBranch()
        let task = Task { await nav.present(DummyScreen(), as: .sheet) }
        await settle()
        let sheet = branch.root.presents[0]
        let sheetNav = navigator(for: sheet.root, in: sheet)
        sheetNav.dismissBranch(returning: "first")
        sheetNav.dismissBranch(returning: "second")
        let result = await task.value
        #expect(result as? String == "first")
    }

    @Test func popMiddleDeliversResultOnlyToThatNode() async {
        let (branch, nav) = makeBranch()
        let firstTask = Task { await nav.push(DummyScreen()) }
        await settle()
        let firstNode = branch.current
        let secondTask = Task { await navigator(for: firstNode, in: branch).push(DummyScreen()) }
        await settle()
        #expect(branch.path.count == 2)
        navigator(for: firstNode, in: branch).pop(returning: "mine")
        #expect(await firstTask.value as? String == "mine")
        #expect(await secondTask.value == nil)
    }
}

// MARK: - Forest

@MainActor
struct ForestEdgeTests {

    @Test func selectTabOutOfBoundsIsNoop() {
        let tabs = [
            NavTab("A", systemImage: "a.circle", root: NavNodeItem(DummyScreen())),
            NavTab("B", systemImage: "b.circle", root: NavNodeItem(DummyScreen())),
        ]
        let forest = NavForest(tabs: tabs)
        let nav = Navigator(branch: tabs[0].branch, node: tabs[0].branch.root, root: tabs[0].branch, forest: forest)
        let before = forest.selection
        nav.selectTab(5)
        nav.selectTab(-1)
        #expect(forest.selection == before)
        nav.selectTab(1)
        #expect(forest.selection == tabs[1].id)
    }

    @Test func treeLinesCoversAllTabs() {
        let tabs = [
            NavTab("A", systemImage: "a.circle", root: NavNodeItem(DummyScreen())),
            NavTab("B", systemImage: "b.circle", root: NavNodeItem(DummyScreen())),
        ]
        let forest = NavForest(tabs: tabs)
        tabs[1].branch.push(DummyScreen())
        let nav = Navigator(branch: tabs[0].branch, node: tabs[0].branch.root, root: tabs[0].branch, forest: forest)
        let lines = nav.treeLines()
        #expect(lines.count == 5)
        #expect(lines.filter { $0.contains("[tab]") }.count == 2)
    }
}

// MARK: - Fuzz đa seed + giả lập visibility

@MainActor
struct FuzzRound2Tests {

    @Test(arguments: [UInt64(0xCAFEBABE), 0x12345678, 0x0BADF00D])
    func multiSeedStormWithVisibilityFlips(seed: UInt64) async {
        let (rootBranch, _) = makeBranch()
        var rng = SeededRandom(state: seed)
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

        for i in 0..<300 {
            let branches = liveBranches()
            let branch = branches[rng.next(branches.count)]
            let node = branch.current
            let nav = navigator(for: node, in: branch)
            switch rng.next(9) {
            case 0, 1:
                syncPush(nav)
            case 2:
                syncPresent(nav, [.sheet, .fullScreenCover, .popover][rng.next(3)])
            case 3:
                nav.pop(returning: i)
            case 4:
                nav.popToRoot()
            case 5:
                nav.dismissBranch(returning: "d\(i)")
            case 6:
                node.isVisible = rng.next(2) == 0
            case 7:
                awaitTasks.append(Task { await nav.push(DummyScreen()) })
                await settle()
            default:
                // .disappeared cần UI thật bắn onDisappear — fuzz chỉ dùng .removed,
                // đường .disappeared đã có test tất định riêng.
                awaitTasks.append(Task { await nav.present(DummyScreen(), as: .sheet) })
                await settle()
            }
            var count = 0
            var walker = rootBranch.root.next
            while let n = walker { count += 1; walker = n.next }
            #expect(rootBranch.path.count == count)
        }

        rootBranch.popToRoot()
        rootBranch.root.presents = []
        rootBranch.root.isVisible = false
        for task in awaitTasks {
            _ = await task.value
        }
        #expect(rootBranch.treeLines().count == 1)
    }
}
