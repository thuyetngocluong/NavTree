# 🌳 NavTree

**Your entire SwiftUI navigation as one tree.**

[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-blue.svg)](https://developer.apple.com)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager)
[![Strict Concurrency](https://img.shields.io/badge/concurrency-strict-purple.svg)](https://www.swift.org/documentation/concurrency/)
[![License: MIT](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

NavTree models navigation the way it actually behaves: **push** extends a branch, **sheet / fullScreenCover / popover** grows a *new* branch attached to the current screen. The whole app — tabs, stacks, modals, nested modals — is one inspectable tree, driven from anywhere via a single environment value.

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
- 💉 **Zero parameter drilling** — screens read `@Environment(\.navigator)`; nothing is threaded through initializers.
- ⏳ **`await` navigation** — `await nav.present(...)` suspends until the screen closes and hands back a result. Even works across interactive swipe-dismiss.
- 🎬 **Animation-aware** — `until: .disappeared` resumes only after the close animation finishes, so chaining modals never drops the second one.
- 🧵 **Swift 6, strict concurrency** — the whole model is `@MainActor`-isolated and data-race checked.
- 🪺 **Nested everything** — modals inside modals inside tabs; presenting while presented auto-forwards to the topmost context (UIKit semantics).
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
        WindowGroup { MainScreen() }      // that's it
    }
}
```

No tab bar? Conform your root to `NavRootScreen` and use `NavRootView(root: RootScreen())`.

### 3. Navigate from anywhere

```swift
@Environment(\.navigator) private var nav

nav.push(DetailScreen(number: 1))
nav.present(PickerScreen(), as: .sheet)
nav.present(PlayerScreen(), as: .fullScreenCover)
nav.present(FilterScreen(), as: .popover)
nav.pop()                                  // at a modal's first screen == dismiss
nav.popToRoot()
nav.dismissBranch()                        // close the current sheet/cover/popover
nav.selectTab(1)                           // works even from inside a modal
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
nav.dismissBranch(returning: selection)    // or nav.pop(returning:)
```

- Results are `(any Sendable)?` — cast on the caller side. Swipe-to-dismiss resumes with `nil`.
- Every removal path resumes the awaiter: pop, system back, edge swipe, `popToRoot`, parent branch dismissed — no leaks, no hangs. Navigating from an already-closed screen is a safe no-op.

### Wait for the close *animation*

Presenting a modal right after another closes is a classic SwiftUI failure ("the second sheet never appears"). NavTree solves it declaratively:

```swift
await nav.present(TermsScreen(), as: .sheet, until: .disappeared)  // resumes AFTER the close animation
nav.present(WelcomeScreen(), as: .sheet)                           // always presents reliably
```

## Presentation config

```swift
nav.present(
    PickerScreen(),
    as: .sheet,
    config: .init(
        detents: [.medium, .large],        // .fraction(_:) / .height(_:) too
        dragIndicator: .visible,
        interactiveDismissDisabled: true   // only closable via dismissBranch/pop
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

- Each screen is a **node**; `next` links form a stack (one `NavigationStack` per branch), `presents` holds modal branches. The tree *is* the navigation state — SwiftUI bindings are derived from it, so interactive gestures (swipe back, sheet drag) stay perfectly in sync.
- Exactly **one `AnyView`** exists per screen, at the unavoidable heterogeneous boundary of `navigationDestination`. Inside it everything is concrete generics — structural identity and diffing stay intact.
- The `navigator` environment value is an identity-compared `Equatable` struct — no spurious view invalidation.
- All removal paths funnel through two `didSet` observers (`next`, `presents`), which is what makes the `await` guarantees airtight.

## Testing

The package ships with **36 tests** covering tree structure, continuation/result delivery, reentrancy, 300-deep nesting, deallocation (weak-reference checks), and deterministic multi-seed fuzzing:

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

- **Don't wrap screen content in your own `NavigationStack`** — every branch already has one.
- **sync/async overload**: in an async context, `nav.push(x)` resolves to the awaiting overload. For fire-and-forget from async code, call through a small synchronous `@MainActor` helper.
- `NavTabBarScreen` is intentionally *not* pushable/presentable — tab bars belong at the root (TabView-outside, stacks-inside, per Apple's guidance).
- Double-tap debouncing is the app's responsibility (disable the button while awaiting).

## License

MIT — see [LICENSE](LICENSE).
