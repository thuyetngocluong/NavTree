---
name: navtree
description: How to build screens and navigation with the NavTree package (tree-based SwiftUI navigation - push/sheet/fullScreenCover/popover as one tree, implicit Navigator via Environment, NavTree per scene, async await-until-dismiss APIs, presentation config). Use when adding screens, tabs, or any navigation code in this project, or when modifying the NavTree package itself.
---

# NavTree — tree-based SwiftUI navigation

Local package at `NavTree/` (Swift 6, strict concurrency, iOS 17+), being prepared for GitHub publication. The entire navigation state of one Scene is ONE tree, owned by a `NavTree` object:

- **push** extends the current stack (same `NavigationStack`, linked via `pushed`).
- **sheet / fullScreenCover / popover** grows a NEW stack attached to the current node; every presented stack is automatically wrapped in its own `NavigationStack` (push works immediately inside it).
- Tabs: `NavTabs` = one `TabView`, one `NavStack` per tab, `TabView` outermost (never push/present a tab bar).

Type names mirror the SwiftUI thing they represent (all internal except `NavTree`):

| Type | Is | Key members |
|---|---|---|
| `NavTree` (public) | the whole scene | `root` (`.stack` / `.tabs`), `current`, `selectedTab` (observable get/set index), `selectTab`, `reset(_:)` / `reset(_:until:)`, `treeLines()` |
| `NavStack` | one `NavigationStack` | `root`, `top`, `path`, `style` (nil = root stack), `owner` (weak), `presentedModal`, `topmostPresenter(from:)`, `push/pop/popToRoot/dismissSelf` |
| `NavTabs` | one `TabView` | `tabs: [NavTab]`, `selection`, `selectedTab` |
| `NavScreenNode<Screen>` (protocol `NavNode`) | one screen | `pushed`, `presented: [NavStack]`, awaiters |
| `Navigator` (public struct) | handle of ONE screen | `stack`, `node`, `tree` — all WEAK; all relative ops |

Ownership: `NavTree` owns stacks, stacks own nodes (`root` → `pushed` → …, `presented`). Views hold only what SwiftUI bindings need (`NavStackView` → its stack for `path`, `NavScreenHost` → its node for sheet bindings) plus the `Navigator`. Every other reference is weak.

## Declaring screens

Screens are plain SwiftUI views conforming to marker protocols — write `body` as usual, never wrap content in your own `NavigationStack`:

```swift
struct DetailScreen: NavScreen {             // pushable/presentable screen
    let number: Int
    @Environment(\.navigator) private var nav
    var body: some View { ... }
}

struct HomeScreen: NavTabScreen {            // tab root: declares its own tab metadata
    let tabTitle = "Home"
    let tabSystemImage = "house"
    var body: some View { ... }
}

struct MainScreen: NavTabBarScreen {         // app tab bar: expose `content` only
    var content: [any NavTabScreen] {
        HomeScreen()
        SettingsScreen()
    }
}
```

`NavTabBarScreen` is intentionally NOT a `NavScreen` — a tab bar cannot be pushed or presented. Its implicit `body` is `NavRootView(root: self)`, a preview shortcut only.

## App root: one NavTree per Scene, NavRootView is the single root

```swift
@main struct MyApp: App {
    var body: some Scene {
        WindowGroup { SceneRoot() }                          // each window builds its own SceneRoot
    }
}

struct SceneRoot: View {
    @State private var tree = NavTree(root: MainScreen())   // or NavTree(root: RootScreen()) for no-tab apps
    var body: some View {
        NavRootView(tree: tree)                              // renders TabView or NavigationStack based on tree.root
            .onOpenURL { DeepLinkHandler.open($0, in: tree) }  // URL schemes + universal links
    }
}
```

- `NavTree` exists from `init` — no `onAppear` registration, no global registry, no singleton. Deep links / notifications / view models take the tree as a parameter.
- NEVER hold the tree in `App` state: it is shared by every window of a `WindowGroup`, so two iPad windows would render the same stacks. Own it in a view inside `WindowGroup` (as above). The `@State` initializer may re-run when that view is rebuilt; only the first instance is kept and `NavTree.init` has no side effects, so extras are harmless — keep it that way (no registration / global side effects in `NavTree.init`).
- Inside views: `@Environment(\.navTree) private var tree` (weak, optional) for whole-tree ops; `@Environment(\.navigator)` for relative ops. NEVER inject the tree strongly with `.environment(tree)`: SwiftUI/UIKit cache environment snapshots beyond the views' lifetime (`navigationAuthority.initialEnvironment` of `NavigationStack`, the floating tab bar's cached trait collection — found with `leaks --traceTree`), which kept old trees alive after a root swap. `NavRootView` also applies `.id(ObjectIdentifier(tree))` so a new tree never reuses the old NavigationStack/TabView.
- Selected tab: `tree.selectedTab` is an observable Int index — `onChange(of: tree.selectedTab)` fires on user taps AND programmatic `selectTab`; `tree.selectedTab = 1` sets it (out-of-range ignored; always 0 / no-op on a non-tab root).

## Navigating (implicit — no parameters threaded through views)

Read `@Environment(\.navigator) private var nav` anywhere and call:

```swift
nav.push(DetailScreen(number: 1))
nav.present(SettingsScreen(), as: .sheet)          // .fullScreenCover / .popover  (NavPresentationStyle)
nav.present(PickerScreen(), as: .sheet,
            config: .init(detents: [.medium, .large],
                          dragIndicator: .visible,
                          interactiveDismissDisabled: true))
nav.pop()                                          // at a modal's first screen == dismiss
nav.pop(returning: someValue)                      // send a result to the awaiter
nav.popToRoot()
nav.dismiss()                                      // close the modal (sheet/cover/popover) containing this screen
nav.dismiss(returning: someValue)
nav.selectTab(1)                                   // works from anywhere, incl. inside modals
if nav.isPresented { /* show a close button */ }
```

Presenting while something is already presented auto-forwards to the deepest presented context (`NavStack.topmostPresenter(from:)`, UIKit "topmost" semantics). The check covers the WHOLE push chain of the caller's stack (`presentedModal`), not just the calling screen: one `NavigationStack` can present only one modal at a time, so a modal owned by any screen in the stack blocks every other screen of that stack. For tab stacks the scope is the whole `TabView` (`NavTabs.presentedModal`, `NavStack.coveringModal`): a modal covers the tab bar, and switching tabs programmatically leaves it on screen (verified on simulator), so `tree.current` and presents from any tab resolve into that modal. `NavNode.present` itself attaches directly with no forwarding — always go through `Navigator`. `popover` is a real popover on iPad, adapts to a sheet on iPhone.

## Async: await until the screen closes

```swift
let result = await nav.push(PickerScreen())                          // resumes when popped/removed
let result = await nav.present(PickerScreen(), as: .sheet)           // resumes when dismissed
await nav.present(A(), as: .sheet, until: .disappeared)              // resumes AFTER close animation
// Child screen finishes with:
nav.pop(returning: picked)  /  nav.dismiss(returning: picked)
```

- Result type is `(any Sendable)?` — caller casts: `result as? String`. Interactive dismiss (swipe) resumes with `nil`.
- `until: .disappeared` is the tool for presenting one modal right after another closes (avoids the classic "second sheet never appears" SwiftUI bug). It resumes when the deepest screen that was still VISIBLE in the removed subtree gets `onDisappear` (`deepestVisibleInSubtree`, handed off before the subtree is torn down): e.g. a sheet with a fullScreenCover on top waits for the cover, because a cover makes the screens under it receive `onDisappear` early. If nothing in the removed subtree is visible, it resumes at removal.
- Every removal path resumes awaiters: pop, back button/edge swipe, popToRoot, swipe-dismiss, enclosing modal dismissed, tail replaced by a new push. Removing a node removes its whole subtree (pushed tail + all modals under it) and resumes every awaiter inside; awaiters of the inner screens get `nil`, the dismissed modal's own awaiter gets the `returning:` value. Navigation from an already-removed screen (zombie Task) is a safe no-op for EVERY call — push, present, pop, popToRoot, dismiss all go through `liveNode`; otherwise a late Task could dismiss the sheet the user is now looking at. `NavStack.path` setter IGNORES any write containing a removed node: such a path was built from stale UI (e.g. code popped + pushed while the user swiped back); applying it would either re-attach a dead screen or truncate away a freshly pushed one. SwiftUI re-reads the model path afterwards. The setter also skips identical assignments to avoid spurious Observation notifications.
- Tree torn down while awaiting (root swap, window closed) → awaiters resume with `nil` via the `deinit` safety net. This only works because `Navigator` holds `stack`/`node`/`tree` WEAKLY and the async APIs keep no strong locals across the suspension point (setup happens inside the `withCheckedContinuation` closure). Never make these strong again: it recreates the cycle Task → Navigator → node → child → continuation → Task (`LifetimeTests` guards this).
- Task cancellation does NOT end an await, by design: the screen is still showing, and `.task` is cancelled the moment a cover it presented hides it. The await always ends when the screen is removed.

## Navigating from outside a view

`tree.current` resolves selected tab → deepest presented modal → top screen. For deep links / notifications / view models only; inside views always prefer `@Environment(\.navigator)`.

```swift
tree.current.push(DetailScreen(id: id))
tree.current.present(SettingsScreen(), as: .sheet)
```

### Deep links: always reset first

```swift
static func open(_ url: URL, in tree: NavTree) async {
    tree.reset()                              // close covering modal + pop stacks (default .allTabs; .selectedTab keeps other tabs)
    tree.selectedTab = 0                      // reset keeps the selected tab
    push(DetailScreen(id: 42), in: tree)      // push right after reset is fine
    // presenting right after? use: await tree.reset(until: .disappeared)
}
// SceneRoot: .onOpenURL { url in Task { await DeepLinkHandler.open(url, in: tree) } }
```

- `reset` always closes the modal covering the screen, even with `.selectedTab`, because a modal covers the whole TabView.
- `reset(until: .disappeared)` waits (weakly) for every screen that was VISIBLE and got removed to receive `onDisappear`. Released screens stop the wait, so it never hangs on a torn-down window.
- Inside an async handler, call `push`/`present` through small sync helpers (overload trap, gotcha 1). The sample app's `DeepLinkHandler` shows the full pattern with the `sample://` URL scheme (`sample://detail/<n>`, `sample://settings`, `sample://sheet`); test it with `xcrun simctl openurl <udid> "sample://detail/5"`.
- `NavNode.closingModalScreen` (weak) remembers the still-visible screen of a modal a node just closed, so a node removed in the same tick (dismiss then popToRoot, which is what reset does) still hands its `.disappeared` awaiters to the closing modal. Without it they resume while the cover is still animating out (found by the lifecycle fuzz).

## Gotchas (learned the hard way)

1. **sync/async overload trap**: inside an async context, `nav.push(x)` resolves to the AWAITING overload ("expression is async" error, or an unwanted suspension). For fire-and-forget from async code, call through a small sync `@MainActor` helper function. This bit us three separate times — check for it in any async call site.
2. Environment value `\.navigator` is an Equatable struct compared by identity — do NOT replace it with an existential protocol type (kills SwiftUI's env comparison fast path) and do not store closures in it.
3. Model types (`NavNode`/`NavStack`/`NavTabs`) are `@MainActor` and internal — public surface is the 4 screen protocols, `NavTree`, `Navigator`, `NavPresentationStyle`, `NavAwaitUntil`, `NavDetent`, `NavPresentationConfig`, `NavRootView`, `NavTreeSection`.
4. Debug view: drop `NavTreeSection()` into any `List` to render the live navigation tree (`[root]/[push]/[sheet]/[cover]/[popover]` lines, `▶` = selected tab).
5. Double-tap debounce is the app's job (disable button while awaiting), not the library's.
6. Package tests (84, incl. invariant-checking NavTree fuzz (`NavTreeStressRound3Tests`: 10 seeds × 800 steps, stack + tab roots, zombies, stale paths, teardown ledger), a lifecycle fuzz (`NavTreeStressRound4Tests`) whose UISim plays SwiftUI — keeps removed screens mounted until onDisappear, sheet keeps the presenter visible, cover hides it — and checks no early `.disappeared` resume and no hang once the UI settles (do not use the library's own helpers to compute expectations there), fuzz + reentrancy + presentation config + NavTree.current): run from the package dir —
   `cd NavTree && xcodebuild test -scheme NavTree -destination 'platform=iOS Simulator,name=...'`.
   Xcode's test navigator may show 0 tests for the NavTree scheme right after file renames; the CLI run is authoritative.
   When touching removal/continuation logic in `NavNode.swift`/`NavStack.swift`, run these before declaring done; every awaiter must resume on every removal path (didSet on `pushed`/`presented` is the single funnel — never bypass it).
7. `NavTree(root:)` builds the tab list once — tab list is static after init by design.
8. Never nest `NavigationStack`s: `NavRootView` renders `NavTabsView` (TabView, stacks inside) for a tab-bar root and `NavStackView` for a plain root. Don't put a `NavTabBarScreen` inside another stack.
9. Adding/renaming the package product requires updating the Xcode project's package reference — pbxproj cannot be edited by tools while Xcode is open; the user must re-add the local package via Xcode UI (File ▸ Add Package Dependencies ▸ Add Local).
