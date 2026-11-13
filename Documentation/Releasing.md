# Releasing

1. Confirm the MIT copyright line and installation URLs are correct.
2. Run `python3 Scripts/check_repository.py --release`, script regressions, Debug/Release package builds, package tests, and README integration verification.
3. Update CHANGELOG.md with a dated version entry and prepare release notes describing API changes, constraints and measured compatibility.
4. Push the reviewed commit when publication is authorized, and check its hosted CI results. Local workflow files alone are not evidence of hosted CI success.
5. Create and push the version tag at that commit. Verify a clean external project can resolve and build the actual repository URL/tag.
6. Check tag CI, then publish the GitHub Release. Keep raw logs in CI artifacts rather than source history.

`0.x` is an API preview period. Document source-breaking changes in minor releases and behavior fixes in patch releases. Until the next release, installation examples track `main`. On release, switch them to `.upToNextMinor(from:)` so consumers receive patches without automatically adopting a breaking minor release. Do not reuse the retired `v0.1.0` tag. Before `1.0`, decide whether explicit flow shutdown is part of the public API; do not silently redefine logical deactivation as visual disappearance.

The preparation scripts do not push, create repositories or publish releases. The temporary integration fixture tag is not a release tag in this repository.
