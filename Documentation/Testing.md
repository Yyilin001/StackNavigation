# Verification

## Current checks

| Check | Scope |
| --- | --- |
| Repository check | Local documentation links and personal paths, including Python scripts; release placeholders with `--release` |
| Script regressions | 14 Python tests for path scanning, stale reports, Git configuration isolation and simulator selection; no devices are started |
| Package build | Library compilation for a generic iOS Simulator, Debug or Release |
| Package tests | 67 Swift Testing functions covering route identity, command ordering, subscriptions, Host ownership, registration lifetime, membership callbacks and callback reentry; includes simulator-hosted SwiftUI modifier checks |
| README integration | Compile both language quick starts against an exact version in a temporary local Git repository |

The repository has no example application or UI test target. Core package tests exercise navigation logic and internal lifecycle coordination. `NavigationModifierHostingTests` additionally renders a `NavigationHost` in a `UIHostingController` and checks the public modifiers; these checks do not simulate back gestures, assert animation completion or inspect local `@State` storage. README compilation verifies API usage, not runtime behavior.

## Commands

Run from the repository root with Xcode selected via `xcode-select` or `DEVELOPER_DIR`:

```sh
python3 Scripts/check_repository.py
python3 -m unittest discover -s Scripts/tests -v
python3 Scripts/verify.py package-build
python3 Scripts/verify.py package-build --configuration Release
python3 Scripts/verify.py package
python3 Scripts/check_integration.py
```

Only `package` boots a simulator. It chooses an available iPhone on the newest installed iOS 17.0+ runtime; set `SIMULATOR_OS=18.5` to filter runtimes, or `SIMULATOR_UDID` to select a device explicitly. An explicit UUID takes precedence over the OS filter and must belong to an available iOS 17.0+ runtime. Invalid selections fail before any device is created or booted. If needed, automatic selection creates a compatible iPhone; it never deletes devices. Plain `swift test` on macOS is not supported for this iOS package.

Build output goes to ignored `Build/`; test result bundles and the integration summary go to ignored `TestResults/`. The integration check clears the previous `integration.json` before running and writes a new report only on success; a failed run exits with an error and leaves no success report. It reads the Swift quick starts directly from both READMEs, builds them in separate modules, verifies exact-version resolution and removes its temporary checkout. It does not publish or verify a remote release tag.

Fixture Git commands and the consumer build use a child-process environment that excludes inherited Git overrides and disables user/system Git configuration. The fixture uses an empty Git template. Commit/tag signing, personal hooks and repository-path overrides do not affect the check; the user's Git files and parent-process environment are not modified. Script regressions exercise real local commits, tags and clones with deliberately failing signing/hook settings.

## Recorded evidence

Last membership-callback regression: 2026-11-13. Local toolchain: Xcode 27.1 / Swift 6.4. Build destination: generic iOS Simulator, arm64 and x86_64.

| Scope | Deployment target / runtime | Result |
| --- | --- | --- |
| Current package, Debug and Release | iOS 17.0 target | Passed |
| Current English and Chinese README quick starts | iOS 17.0 target | Passed |
| Current package tests, including SwiftUI hosting | iOS 17.0 target; iOS 18.5 and 27.1 simulators | 67 passed on each runtime |
| Historical package tests | iOS 18.0 target; iOS 18.5 and 27.1 simulators | 51 passed on each runtime |
| Historical application UI checks | iOS 18.0 target; iOS 27.1 simulator | 10 selected checks passed; those tests are not distributed here |

The new membership tests cover first registration (including a covered root), no duplicate insertion on return, independent modifiers, modifier ordering, top-down batch removal, callback refresh, invalidation/release, Host takeover, transient pages and FIFO navigation inside insertion/removal. Four hosting test functions (seven parameterized executions) verify real SwiftUI registration, covering/returning, independent use, insertion-triggered pop and removal-triggered replacement with the same route. System-back cancellation/completion is modeled by path writes in core tests; no new gesture automation was run.

Historical application checks covered root lifecycle, callback navigation, Host replacement, completed/cancelled back gestures and same-turn pop/push state isolation. They are supporting evidence from the earlier application harness, not current package UI coverage or a guarantee across iOS versions.

The [minimum-toolchain CI job](https://github.com/Yyilin001/StackNavigation/actions/runs/43429029278/job/131897558439) verified the library with Xcode 16.0 / Swift 6.0 and passed all 14 script regressions.

Not verified: iOS 17 runtime behavior and physical devices. Each release also checks hosted integration CI and dependency installation against its actual URL/tag; see the release notes for that version’s evidence. See [compatibility](Compatibility.md) and [release preparation](Releasing.md).
