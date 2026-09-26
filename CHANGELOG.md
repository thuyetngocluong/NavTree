# Changelog

All notable changes to NavTree are documented here. The project follows [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- `Navigator.current` — navigate from outside a view (deep links, push notifications, view models). Resolves the selected tab → deepest presented branch → top screen.
- CI running the test suite on the iOS Simulator.

## [1.0.0]

Initial release.

- One navigation tree for tabs, stacks, sheets, full-screen covers and popovers.
- `@Environment(\.navigator)` with `push` / `present` / `pop` / `popToRoot` / `dismissBranch` / `selectTab`.
- `await`-able navigation returning a result, with `until: .disappeared` to resume after the close animation.
- `NavPresentationConfig` (detents, drag indicator, interactive dismiss).
- `NavTreeSection()` debug view.

[Unreleased]: https://github.com/thuyetngocluong/NavTree/compare/1.0.0...HEAD
[1.0.0]: https://github.com/thuyetngocluong/NavTree/releases/tag/1.0.0
