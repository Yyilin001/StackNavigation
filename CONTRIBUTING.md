# Contributing

Keep changes focused and include a minimal reproduction for navigation issues. Distinguish logical stack activation from visual appearance, animation completion, Sheet coverage and app foregrounding.

## Checks

```sh
python3 Scripts/check_repository.py
python3 -m unittest discover -s Scripts/tests -v
python3 Scripts/verify.py package-build
python3 Scripts/verify.py package-build --configuration Release
python3 Scripts/verify.py package
python3 Scripts/check_integration.py
```

For path/queue changes, test reentrant commands and return values. For lifecycle changes, test root pages, initial registration, cancellation, Host takeover and observer ordering. For modifier-registration changes, extend the simulator-hosted SwiftUI package tests. Gesture or animation changes still need an application-level reproduction; this repository does not include an XCUITest target. Report the exact Xcode/iOS configuration and untested scope. See [verification](Documentation/Testing.md).

The self-contained quick starts in both READMEs are compiled by `check_integration.py`; keep each example in one Swift block that imports `StackNavigation`.

Formatting uses the root `.swift-format` configuration:

```sh
xcrun swift-format lint --strict --recursive Sources Tests
xcrun swift-format format --in-place --recursive Sources Tests
```

Keep the library independent of application models. Do not introduce private SwiftUI/UIKit hooks or change path mutation constraints without revisiting state-identity evidence. Do not commit build output, test bundles or personal paths. Treat feedback respectfully and keep discussion focused on the technical behavior.
