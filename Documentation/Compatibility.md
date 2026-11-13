# Compatibility

The package declares **iOS 17.0+** and **Swift tools 6.0**. It uses SwiftUI Observation, available starting in iOS 17 ([Apple documentation](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro)).

| Requirement | Verification status |
| --- | --- |
| iOS 17.0 deployment target | Compilation checked with Xcode 27.1 / Swift 6.4; iOS 17 runtime behavior has not been tested |
| Swift tools 6.0 | Xcode 16.0 / Swift 6.0 package build passed in hosted CI |
| README usage examples | Compiled as independent package consumers; no separate example application or newer-compiler requirement |
| CI integration | Xcode 26.6 package builds/tests and README integration configured; Release compilation passed; package tests and README integration are tracked in hosted CI |

Compilation for an iOS deployment target does not establish runtime behavior on that version. Historical simulator results and current build evidence are listed in [Verification](Testing.md).

CI selects explicit Xcode paths on `macos-15` and `macos-26`. A missing toolchain or selected runtime fails the job rather than skipping checks. Runner inventories may change; maintain the configured toolchains accordingly.

No macOS, Linux, watchOS, tvOS or visionOS compatibility is promised. Physical devices have not been tested.
