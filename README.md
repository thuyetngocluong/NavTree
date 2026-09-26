# 🌳 NavTree

**Your entire SwiftUI navigation as one tree.**

[![CI](https://github.com/thuyetngocluong/NavTree/actions/workflows/ci.yml/badge.svg)](https://github.com/thuyetngocluong/NavTree/actions/workflows/ci.yml)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-blue.svg)](https://developer.apple.com)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![Strict Concurrency](https://img.shields.io/badge/concurrency-strict-purple.svg)](https://www.swift.org/documentation/concurrency/)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

NavTree models navigation the way it actually behaves: **push** extends a stack, **sheet / fullScreenCover / popover** grows a *new* stack attached to the current screen. The whole app — tabs, stacks, modals, nested modals — is one inspectable tree (`NavTree`), driven from anywhere via a single environment value.

```text
▶ [tab] Home
    [root] HomeScreen
    [push] DetailScreen
        [sheet] PickerScreen        ← its own NavigationStack, for free
            [push] SearchScreen
• [tab] Settings
    [root] SettingsScreen
```

## Why NavTree?

- 🧭 **One mental model** — no juggling `NavigationPath`, `@State` booleans, and item bindings. Push, present, pop, dismiss: four verbs, one tree.
- 🌱 **One root per scene** — `NavRootView` is the single root whether or not you have a tab bar; `NavTree` exists from `init`, so deep links work before the first screen appears, and every window gets its own tree.
- 💉 **Zero parameter drilling** — screens read `@Environment(\.navigator)`; nothing is threaded through initializers.
- ⏳ **`await` navigation** — `await nav.present(...)` suspends until the screen closes and hands back a result. Even works across interactive swipe-dismiss.
- 🎬 **Animation-aware** — `until: .disappeared` resumes only after the close animation finishes, so chaining modals never drops the second one.
- 🧵 **Swift 6, strict concurrency** — the whole model is `@MainActor`-isolated and data-race checked.
- 🪺 **Nested everything** — modals inside modals inside tabs; presenting while presented auto-forwards to the topmost context (UIKit semantics). A modal covers the whole tab bar, so presenting from any tab while another tab has a modal open lands in that modal.
- 🔍 **Debuggable** — drop `NavTreeSection()` into any list and watch the live tree.

## Quick start

### 1. Declare screens

Screens are ordinary SwiftUI views conforming to marker protocols — just write `body`:

```swift
import NavTree

struct DetailScreen: NavScreen {
    let number: Int
    @Environment(\.navigator) private var nav

    var body: some View {
        Button("Deeper") { nav.push(DetailScreen(number: number + 1)) }
    }
}

struct HomeScreen: NavTabScreen {
    let tabTitle = "Home"
    let tabSystemImage = "house"

    var body: some View { ... }
}
```

### 2. Declare the app root

```swift
struct MainScreen: NavTabBarScreen {      // tab bar app
    var content: [any NavTabScreen] {
        HomeScreen()
        SettingsScreen()
    }
}

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup { SceneRoot() }                          // each window builds its own SceneRoot
    }
}

struct SceneRoot: View {
    @State private var tree = NavTree(root: MainScreen())   // one tree per window

    var body: some View {
        NavRootView(tree: tree)
    }
}
```

Keep the tree in a view *inside* `WindowGroup`, not in `App`: `App` state is shared by every window, so an app-level tree would be rendered by two iPad windows at once.

No tab bar? Conform your root to `NavRootScreen` and pass it the same way: `NavTree(root: RootScreen())`. `NavRootView` picks the right container (TabView-outside-stacks-inside, or a single `NavigationStack`) from the tree.

Don't need the tree outside views? `NavRootView(root: MainScreen())` creates and owns one for you.

### 3. Navigate from anywhere

```swift
@Environment(\.navigator) private var nav

nav.push(DetailScreen(number: 1))
nav.present(PickerScreen(), as: .sheet)
nav.present(PlayerScreen(), as: .fullScreenCover)
nav.present(FilterScreen(), as: .popover)
nav.pop()                                  // at a modal's first screen == dismiss
nav.popToRoot()
nav.dismiss()                              // close the current sheet/cover/popover
nav.selectTab(1)                           // works even from inside a modal
```

### Observe or set the selected tab

`NavTree.selectedTab` is an observable, settable index. It changes on user taps and on any `selectTab` call alike:

```swift
@Environment(\.navTree) private var tree       // weak, nil outside a NavRootView

Text("Tab \(tree?.selectedTab ?? 0)")
    .onChange(of: tree?.selectedTab) { old, new in analytics.log(tab: new) }

tree?.selectedTab = 1                      // same as nav.selectTab(1); out-of-range is ignored
```

## Await a screen like a function call

```swift
// Caller — suspends until the picker closes, gets the result back:
Task {
    if let picked = await nav.present(PickerScreen(), as: .sheet) as? String {
        apply(picked)
    }
}

// Picker screen — finish with a value:
nav.dismiss(returning: selection)          // or nav.pop(returning:)
```

- Results are `(any Sendable)?` — cast on the caller side. Swipe-to-dismiss resumes with `nil`.
- Every removal path resumes the awaiter: pop, system back, edge swipe, `popToRoot`, enclosing modal dismissed — no leaks, no hangs. Every call (push, present, pop, popToRoot, dismiss) from an already-closed screen is a safe no-op, so a late `Task` can never pop or dismiss what the user opened afterwards.
- Tearing down the whole tree (root swap, window closed) resumes pending awaiters with `nil`: `Navigator` only holds weak references, so a suspended `await` never keeps the tree alive.
- Cancelling the awaiting `Task` does **not** end the await — the screen is still on screen, so returning early would lie. The await always ends when the screen is removed.

### Wait for the close *animation*

Presenting a modal right after another closes is a classic SwiftUI failure ("the second sheet never appears"). NavTree solves it declaratively:

```swift
await nav.present(TermsScreen(), as: .sheet, until: .disappeared)  // resumes AFTER the close animation
nav.present(WelcomeScreen(), as: .sheet)                           // always presents reliably
```

"After the close animation" means the last screen that was still visible in what got removed, including a modal on top of it: a sheet with a full-screen cover over it waits for the cover.

## Navigate from outside a view

Deep links, push notifications and view models don't have `@Environment`. Hand them the scene's `NavTree`; `tree.current` resolves the context the user is actually looking at — selected tab → deepest presented modal → top screen:

```swift
@MainActor
enum DeepLinkHandler {
    static func open(_ url: URL, in tree: NavTree) {
        switch url.path {
        case "/detail":   tree.current.push(DetailScreen(id: url.lastPathComponent))
        case "/settings": tree.current.present(SettingsScreen(), as: .sheet)
        default:          break
        }
    }
}

// SceneRoot (one per window)
NavRootView(tree: tree)
    .onOpenURL { DeepLinkHandler.open($0, in: tree) }       // URL schemes + universal links, per window
```

Inside a view, keep using `@Environment(\.navigator)` for relative navigation — it's precise and testable. For whole-tree operations from a view, read `@Environment(\.navTree)`. It is deliberately weak and optional: SwiftUI and UIKit cache environment snapshots (for example inside `NavigationStack` and the floating tab bar) longer than the views live, so a strongly injected tree would outlive a root swap.

There is no global singleton: the tree is a plain object you own. It works the moment it's created — no `onAppear` registration — and multi-window apps simply get one tree per window.

## Presentation config

```swift
nav.present(
    PickerScreen(),
    as: .sheet,
    config: .init(
        detents: [.medium, .large],        // .fraction(_:) / .height(_:) too
        dragIndicator: .visible,
        interactiveDismissDisabled: true   // only closable via dismiss/pop
    )
)
```

`popover` shows a real popover on iPad and adapts to a sheet on iPhone.

## Debug view

```swift
List {
    ...
    NavTreeSection()   // renders the live navigation tree of the whole app
}
```

## How it works

- Types are named after the SwiftUI thing they represent: a `NavStack` *is* a `NavigationStack`, `NavTabs` *is* a `TabView`, a `NavScreenNode` is one screen, and `NavTree` is the whole scene.
- Each screen is a **node**; `pushed` links form a stack, `presented` holds the modal stacks growing out of it. The tree *is* the navigation state — SwiftUI bindings are derived from it, so interactive gestures (swipe back, sheet drag) stay perfectly in sync.
- Exactly **one `AnyView`** exists per screen, at the unavoidable heterogeneous boundary of `navigationDestination`. Inside it everything is concrete generics — structural identity and diffing stay intact.
- The `navigator` environment value is an identity-compared `Equatable` struct — no spurious view invalidation.
- All removal paths funnel through two `didSet` observers (`pushed`, `presented`), which is what makes the `await` guarantees airtight.

## Testing

The package ships with **70 tests** covering tree structure, continuation/result delivery, reentrancy, 300-deep nesting, deallocation (weak-reference checks), `NavTree.current` resolution, and deterministic multi-seed fuzzing:

```bash
xcodebuild test -scheme NavTree -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Installation

**Swift Package Manager** — in Xcode: *File ▸ Add Package Dependencies…* and paste:

```
https://github.com/thuyetngocluong/NavTree.git
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/thuyetngocluong/NavTree.git", from: "1.0.0")
]
```

### Requirements

| | |
|---|---|
| iOS | 17.0+ |
| Swift | 6.0+ |
| Xcode | 16+ |

## Tips & gotchas

- **Don't wrap screen content in your own `NavigationStack`** — every stack already has one.
- **Own the tree in a view inside `WindowGroup`**, never in `App` (app state is shared across windows). The `@State` initializer may re-run when SwiftUI rebuilds that view, but only the first instance is kept, and `NavTree.init` has no side effects, so extras are harmlessly discarded.
- **sync/async overload**: in an async context, `nav.push(x)` resolves to the awaiting overload. For fire-and-forget from async code, call through a small synchronous `@MainActor` helper.
- `NavTabBarScreen` is intentionally *not* pushable/presentable — tab bars belong at the root (TabView-outside, stacks-inside, per Apple's guidance).
- Double-tap debouncing is the app's responsibility (disable the button while awaiting).

## License

MIT — see [LICENSE](LICENSE).
