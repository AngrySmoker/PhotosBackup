# Build & Test

## Prerequisites

- macOS + Xcode 16.4 + iOS Simulator runtime, XcodeGen 2.40+ (`brew install xcodegen`), iOS 16.0+

## Generate (always first — .xcodeproj is generated)

```sh
xcodegen generate
open PhotosBackup.xcodeproj
```

Signed device build: set `DEVELOPMENT_TEAM` in `project.yml`, regenerate, let Xcode manage signing.

## Build (simulator, unsigned)

```sh
xcodebuild \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackup \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Test (offline — default gate, ~75 tests)

```sh
xcrun simctl list devices available   # pick a name first
xcodebuild \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackup \
  -destination 'platform=iOS Simulator,name=<your simulator>' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Live tests (opt-in, contacts Google — never run by default)

```sh
TEST_RUNNER_GPMC_LIVE=1 \
xcodebuild ... test \
  -only-testing:PhotosBackupTests/LiveExchangeTests/testInvalidTokenIsRejectedByGoogleNotByUs

TEST_RUNNER_GPMC_LIVE=1 \
TEST_RUNNER_GPMC_OAUTH_TOKEN=oauth_XXXX \
xcodebuild ... test \
  -only-testing:PhotosBackupTests/LiveExchangeTests/testFullExchangeWithRealToken
```

`TEST_RUNNER_GPMC_OAUTH_TOKEN` must be a fresh single-use token. Never commit tokens.

## IPA (SideStore sideload)

```sh
./Scripts/make-ipa.sh
# output: build/PhotosBackup.ipa
# override Xcode location only if needed:
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./Scripts/make-ipa.sh
```
