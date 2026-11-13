# Changelog

## 0.2.0 — 2026-11-13

Published from the new repository history. The retired `v0.1.0` tag is not reused.

- Independent `onNavigationEnter` and `onNavigationExit` page modifiers, including root registration and covered-page removal.
- Initial membership before activation, top-down removal before returning-page activation, and FIFO navigation from both callbacks.
- Explicit registration-scoped semantics for Host replacement, cancellation and pages removed before mounting.
- Membership regression tests and simulator-hosted SwiftUI tests of the public modifiers.
- Typed navigation commands with stable page-instance IDs.
- Root and destination logical activation/deactivation modifiers.
- FIFO callback reentry and cancellable navigation-change subscriptions.
- Host takeover and revoked-registration protection.
- Independent Swift package with package tests and concise, compile-checked README examples.
- iOS 17.0 minimum deployment target; package and independent consumer compilation verified. iOS 17 runtime validation remains pending.
- English and Chinese usage documentation, CI and clean Git dependency verification.

Known boundaries: no middle removal/reordering, no implicit flow shutdown when the entire Host disappears, and no source-version metadata on system path writes. See the README before integrating.
