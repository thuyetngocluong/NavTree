---
name: navtree
description: How to build screens and navigation with the NavTree package (tree-based SwiftUI navigation - push/sheet/fullScreenCover/popover as one tree, implicit Navigator via Environment, async await-until-dismiss APIs, presentation config). Use when adding screens, tabs, or any navigation code in this project, or when modifying the NavTree package itself.
---

# NavTree — tree-based SwiftUI navigation

Local package at `NavTree/` (Swift 6, strict concurrency, iOS 17+), being prepared for GitHub publication. The entire navigation state of the app is ONE tree:

- **push** extends the current branch (same `NavigationStack`, linked via `next`).
- **sheet / fullScreenCover / popover** grows a NEW branch attached to the current node; every presented branch is automatically wrapped in its own `NavigationStack` (push works immediately inside it).
- Tabs are a forest: one root branch per tab, `TabView` outermost (never push/present a tab bar).

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

struct MainScreen: NavTabBarScreen {         // app tab bar: expose `content` only, body is implicit
    var content: [any NavTabScreen] {
        HomeScreen()
        SettingsScreen()
    }
}
// App entry: `MainScreen()` used directly as a View.
// No-tab app: `struct RootScreen: NavRootScreen` + `NavRootView(root: RootScreen())`.
```

`NavTabBarScreen` is intentionally NOT a `NavScreen` — a tab bar cannot be pushed or presented.

## Navigating (implicit — no parameters threaded through views)

Read `@Environment(\.navigator) private var nav` anywhere and call:

```swift
nav.push(DetailScreen(number: 1))
nav.present(SettingsScreen(), as: .sheet)          // .fullScreenCover / .popover
nav.present(PickerScreen(), as: .sheet,
            config: .init(detents: [.medium, .large],
                          dragIndicator: .visible,
                          interactiveDismissDisabled: true))
nav.pop()                                          // at a presented branch's first screen == dismiss
nav.pop(returning: someValue)                      // send a result to the awaiter
nav.popToRoot()
nav.dismissBranch()                                // close current sheet/cover/popover
nav.dismissBranch(returning: someValue)
nav.selectTab(1)                                   // works from anywhere, incl. inside modals
if nav.isPresented { /* show a close button */ }
```

Presenting while something is already presented auto-forwards to the deepest presented context (UIKit "topmost" semantics). `popover` is a real popover on iPad, adapts to a sheet on iPhone.

## Async: await until the screen closes

```swift
let result = await nav.push(PickerScreen())                          // resumes when popped/removed
let result = await nav.present(PickerScreen(), as: .sheet)           // resumes when dismissed
await nav.present(A(), as: .sheet, until: .disappeared)              // resumes AFTER close animation
// Child screen finishes with:
nav.pop(returning: picked)  /  nav.dismissBranch(returning: picked)
```

- Result type is `(any Sendable)?` — caller casts: `result as? String`. Interactive dismiss (swipe) resumes with `nil`.
- `until: .disappeared` is the tool for presenting one modal right after another closes (avoids the classic "second sheet never appears" SwiftUI bug). If the awaited screen is covered when removed, it resumes at removal.
- Every removal path resumes awaiters: pop, back button/edge swipe, popToRoot, swipe-dismiss, parent branch dismissed, tail replaced by a new push. Navigation from an already-removed screen (zombie Task) is a safe no-op returning `nil`.

## Navigating from outside a view

`Navigator.current` (static) resolves selected tab → deepest presented branch → top screen. For deep links / notifications / view models only; inside views always prefer `@Environment(\.navigator)`.

```swift
Navigator.current.push(DetailScreen(id: id))
Navigator.current.present(SettingsScreen(), as: .sheet)
```

Backed by `NavRegistry` (internal), which holds exactly ONE root per app and asserts on a second. `NavRootView`/`NavTabBarHost` register from `.onAppear` — NEVER from `init`, because `@State(initialValue:)` re-creates the object on every view init and keeps only the first; registering in init would capture a throwaway instance (silent no-op navigation). `NavRegistry.reset()` exists for tests; `Navigator.current` is a safe no-op when nothing is registered.

## Gotchas (learned the hard way)

1. **sync/async overload trap**: inside an async context, `nav.push(x)` resolves to the AWAITING overload ("expression is async" error, or an unwanted suspension). For fire-and-forget from async code, call through a small sync `@MainActor` helper function. This bit us three separate times — check for it in any async call site.
2. Environment value `\.navigator` is an Equatable struct compared by identity — do NOT replace it with an existential protocol type (kills SwiftUI's env comparison fast path) and do not store closures in it.
3. Model types (`NavNode`/`NavBranch`/`NavForest`) are `@MainActor` and internal — public surface is only the 4 screen protocols, `Navigator`, `NavBranchKind`, `NavAwaitUntil`, `NavDetent`, `NavPresentationConfig`, `NavRootView`, `NavTreeSection`.
4. Debug view: drop `NavTreeSection()` into any `List` to render the live navigation tree (`[root]/[push]/[sheet]/[cover]/[popover]` lines, `▶` = selected tab).
5. Double-tap debounce is the app's job (disable button while awaiting), not the library's.
6. Package tests (36, incl. fuzz + reentrancy + presentation config): run from the package dir —
   `cd NavTree && xcodebuild test -scheme NavTree -destination 'platform=iOS Simulator,name=...'`.
   When touching removal/continuation logic in `NavNode.swift`/`NavBranch.swift`, run these before declaring done; every awaiter must resume on every removal path (didSet on `next`/`presents` is the single funnel — never bypass it).
7. `NavTabBarHost` builds its forest once (`@State`) — tab list is static after first render by design.
8. Adding/renaming the package product requires updating the Xcode project's package reference — pbxproj cannot be edited by tools while Xcode is open; the user must re-add the local package via Xcode UI (File ▸ Add Package Dependencies ▸ Add Local).
