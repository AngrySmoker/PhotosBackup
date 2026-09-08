# Photos Backup for iOS

<p align="center">
  <img src="App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="160" alt="Photos Backup app icon">
</p>

An experimental, fully on-device iPhone app for backing up selected photos,
videos, and albums to Google Photos. It combines a SwiftUI app with a bundled
Safari web extension so account setup can be completed on the phone without a
desktop companion or hosted service.

> [!WARNING]
> This project uses Google's private, undocumented Photos endpoints and an
> Android-style authentication flow. It is not affiliated with or endorsed by
> Google, and the integration may stop working without notice. Treat it as
> experimental software and use it at your own risk.

## What it can do

- Connect a Google account through Safari's EmbeddedSetup flow.
- Capture the single-use `oauth_token` with a bundled Safari web extension.
- Exchange the token for a Google Photos credential entirely on the device.
- Select albums from the local Photos library.
- Queue individual photos, videos, or all items in selected albums.
- Show hashing, duplicate-check, upload, and finalization progress per item.
- Avoid re-uploading media already present in Google Photos.
- Retry transient failures, cancel work, and resume after reconnecting.
- Upload in original quality or request Google's Storage Saver processing.
- Store usable long-lived credentials in the iOS Keychain when signing permits.

## Current status

The complete authentication path has been proven on an iOS simulator: Safari
receives the `oauth_token`, the extension captures it, the app exchanges it for
an unbound master token and Photos credential, and an authenticated
`photosdata-pa` request succeeds.

The Xcode project, app target, and scheme are named `PhotosBackup`; the
user-facing app is named **Photos Backup**.

## Requirements

- macOS with Xcode and an installed iOS Simulator runtime
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.40 or newer
- iOS 16.0 or newer
- A Google account for the live connection flow
- For a physical device: an Apple signing identity, or a sideloading tool such
  as SideStore or AltStore

Install XcodeGen with Homebrew if needed:

```sh
brew install xcodegen
```

## Build and run

Generate the Xcode project:

```sh
xcodegen generate
open PhotosBackup.xcodeproj
```

Select the `PhotosBackup` scheme and an iPhone simulator in Xcode, then run the
app. A command-line simulator build also works:

```sh
xcodebuild \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackup \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a signed device build, set `DEVELOPMENT_TEAM` in `project.yml`, regenerate
the project, and let Xcode manage signing.

### Build an unsigned IPA

The repository includes a packaging script for SideStore/AltStore-style
sideloading:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/make-ipa.sh
```

The unsigned package is written to `build/PhotosBackup.ipa`. The sideloading
tool re-signs it with the Apple ID configured on the device.

## Connect a Google account

1. Install and launch Photos Backup.
2. In Settings, enable the **Photos Backup Connect** Safari extension and allow
   it to access `accounts.google.com`.
3. Continue through onboarding and open Google EmbeddedSetup in Safari.
4. Sign in and accept Google's consent prompt. The page may remain on a spinner
   afterward; that is expected.
5. Open the extension's toolbar menu and choose **Connect account** once.
6. Return to Photos Backup, grant the desired Photos access, and select albums.

The captured `oauth_token` is single-use. Triggering the handoff twice can spend
the token before the second exchange and require another sign-in.

## Authentication and credential handling

The normal flow is:

```text
Safari EmbeddedSetup
        │
        ▼
Photos Backup Connect extension
        │  oauth_token
        ▼
App Group handoff, or gpmcprobe:// fallback
        │
        ▼
Android master token → Photos access token → private Photos API
```

- The exchange runs locally; there is no companion backend.
- Credentials are stored as a single Keychain item using
  `AfterFirstUnlockThisDeviceOnly` when Keychain access is available.
- Exported Photos-library items are staged temporarily and removed after the
  queue finishes with them.
- Bound/encrypted Google tokens are rejected because token binding is not
  implemented.
- The URL-scheme fallback carries a live single-use token. Custom URL schemes
  are not exclusive on iOS, so this is weaker than an App Group handoff and
  should not be used for broad distribution without a fresh security review.

## Known limitations

- Google can change or disable the private authentication and Photos endpoints.
- Live Photos currently upload only their still image; the motion component is
  ignored.
- Automatic album backup is triggered while the app is active. Background
  transfer and continuous background scheduling are not hardened yet.
- The Wi-Fi-only/cellular preference is saved in the UI but network-policy
  enforcement is not implemented yet.
- Unsigned simulator builds cannot persist the credential in the Keychain.
  Free personal-team builds cannot provision App Groups and normally expire
  after seven days.
- Google accounts that receive a bound/encrypted master token are unsupported.
- This is not an App Store-ready release.

## Tests

Run the offline unit test suite against any installed simulator:

```sh
xcodebuild \
  -project PhotosBackup.xcodeproj \
  -scheme PhotosBackup \
  -destination 'platform=iOS Simulator,name=<your simulator>' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

List available simulator names with:

```sh
xcrun simctl list devices available
```

Live tests are opt-in because they contact Google. The full exchange test also
requires a fresh, single-use `oauth_token`:

```sh
TEST_RUNNER_GPMC_LIVE=1 \
xcodebuild ... test \
  -only-testing:PhotosBackupTests/LiveExchangeTests/testInvalidTokenIsRejectedByGoogleNotByUs

TEST_RUNNER_GPMC_LIVE=1 \
TEST_RUNNER_GPMC_OAUTH_TOKEN=oauth_XXXX \
xcodebuild ... test \
  -only-testing:PhotosBackupTests/LiveExchangeTests/testFullExchangeWithRealToken
```

Never commit tokens or captured account credentials.

## Repository layout

```text
App/Sources/                  SwiftUI app, onboarding, account, and upload queue
App/Resources/                Info.plist and app icon assets
Extension/Sources/            Native Safari extension handler
Extension/WebResources/       WebExtension manifest, scripts, popup, and icons
GPMC/Core/                    Photos protocol client and protobuf helpers
Tests/PhotosBackupTests/      Offline unit tests and gated live tests
Scripts/make-ipa.sh           Unsigned IPA packaging
docs/                         Feasibility log and authentication ADR
project.yml                   XcodeGen project definition
```

For implementation history and protocol details, see:

- [`docs/ADR-001-auth-route.md`](docs/ADR-001-auth-route.md)
- [`docs/feasibility-probe.md`](docs/feasibility-probe.md)

## Acknowledgements

The protocol work is based on [GPMC by xob0t](https://github.com/xob0t/gpmc),
and the browser authentication route is based on gotohp. The pinned upstream
revisions and design rationale are recorded in the authentication ADR.

## License

This project is available under the [MIT License](LICENSE).
