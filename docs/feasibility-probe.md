# GPMCAuthProbe — Safari authentication feasibility probe

Purpose: decide whether GPMC account onboarding can happen **entirely on an
iPhone** via a bundled Safari web extension, or whether it needs a one-time
manual credential import.

The probe is a small app + Safari web extension that runs the checklist from
the handoff plan's Step 2 and reports each step pass/fail on screen.

**Current bottom line (2026-09-08):** blocked on an earlier step than expected.
The Safari extension is not getting *any* cookie access on the unsigned
simulator build (`browser.cookies.getAll({})` returns 0 cookies for every
site), so we cannot yet observe whether Google's EmbeddedSetup page issues an
`oauth_token` cookie to mobile Safari. Next attempt: grant the extension
all-sites access and/or retest on a signed build. See **Test log** below.

## Build & run

```sh
export DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer
xcodegen generate
xcodebuild -project GPMCAuthProbe.xcodeproj -scheme GPMCAuthProbe \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

DD="$(xcodebuild -project GPMCAuthProbe.xcodeproj -scheme GPMCAuthProbe \
  -showBuildSettings -sdk iphonesimulator 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
xcrun simctl install "iPhone 16 Pro" "$DD/GPMCAuthProbe.app"
xcrun simctl launch "iPhone 16 Pro" dev.gpmc.authprobe
```

Unit tests (offline, wire-format assertions):

```sh
xcodebuild -project GPMCAuthProbe.xcodeproj -scheme GPMCAuthProbe \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' \
  CODE_SIGNING_ALLOWED=NO test -only-testing:GPMCAuthProbeTests/TokenExchangeTests
```

Live network test (reaches Google; proves the request path from iOS):

```sh
# Rejection path — no account needed:
TEST_RUNNER_GPMC_LIVE=1 xcodebuild ... test \
  -only-testing:GPMCAuthProbeTests/LiveExchangeTests/testInvalidTokenIsRejectedByGoogleNotByUs

# Full path — needs a fresh oauth_token:
TEST_RUNNER_GPMC_LIVE=1 TEST_RUNNER_GPMC_OAUTH_TOKEN=oauth_XXXX xcodebuild ... test \
  -only-testing:GPMCAuthProbeTests/LiveExchangeTests/testFullExchangeWithRealToken
```

## Checklist status (2026-09-08, iOS 18.6 simulator, Xcode 16.4, unsigned)

| # | Checklist step | Status | Evidence / note |
|---|---|---|---|
| 1 | App + Safari extension build & launch | **PASS** | `BUILD SUCCEEDED`; app launched (screenshot); `.appex` embedded in `GPMCAuthProbe.app/PlugIns/`. |
| — | Extension registered with iOS | **PASS** | `simctl spawn "iPhone 16 Pro" pluginkit -mv` lists `dev.gpmc.authprobe.Extension(0.1.0)`. |
| — | Web extension bundle shape | **PASS** | `manifest.json` at bundle root, MV3, `NSExtensionPointIdentifier = com.apple.Safari.web-extension`, `permissions: [cookies, nativeMessaging, activeTab]`, `host_permissions: [https://accounts.google.com/*]`, `optional_host_permissions: [*://*/*]`. |
| 2 | Extension enabled in Safari settings | **PASS** | User enabled it manually in Safari settings. |
| 3 | Host permission effective for accounts.google.com | **FAIL (so far)** | With the site set to Allow, `browser.cookies.getAll({domain:"accounts.google.com"})` and `getAll({})` both return **0 cookies**. The extension has no cookie visibility at all. Cause not yet isolated — see Test log. |
| 4 | Extension reads the `oauth_token` cookie | **BLOCKED** | Cannot be reached until step 3 works. `No token yet (cookie-absent)` observed, but that is a consequence of step 3, not evidence about Google's page. |
| 5 | Cookie handed to native code | **NOT RUN** (unsigned) | `sendNativeMessage` → `SafariWebExtensionHandler` is wired; App Group persistence is inert without a team (probe falls back to `gpmcprobe://`). |
| 6 | App ingests the token, single use | **PASS (logic only)** | `HandoffStore` consumes the source file on read; construction-level, no integration run yet. |
| 7 | Exchange `oauth_token` → master token | **PARTIAL** | Request/body match gotohp (`TokenExchangeTests`, 7/7). Live: a bogus token returns `Error=BadAuthentication`, parsed and surfaced correctly — the request path from iOS works. Happy path needs a real token. |
| 8 | Exchange master token → Photos access token | **NOT RUN** | Needs a real master token. `TokenEncrypted=1` is detected and rejected (not mishandled). |
| 9 | Read-only Photos request succeeds | **NOT RUN** | `GPMCClient.validateReadAccess()` — dummy hash lookup, mirrors gotohp's `FindRemoteMediaByHash`. |

## Test log

### 2026-09-08 — attempt 1 (unsigned simulator build)

- Extension enabled manually in Safari settings. EmbeddedSetup sign-in
  completed; page hung on the spinner (expected per gotohp docs).
- **GPMC Connect → Check for token** → `No token yet (cookie-absent)`.
- **GPMC Connect → Dump all cookies** →
  - `all (no filter): 0 cookie(s)`
  - `domain=google.com: 0 cookie(s)`
  - `domain=accounts.google.com: 0 cookie(s)`
  - `url=https://accounts.google.com/embedded/setup/android: 0 cookie(s)`

**Reading:** this is not "EmbeddedSetup withheld the cookie." `getAll({})`
returning zero for *every* site means the extension has no effective cookie
permission on this build. Candidate causes, still to isolate:

1. iOS host permission not actually granted to **all** sites (enabling the
   extension ≠ granting website access; the per-site / all-sites toggle is
   separate, and a reinstall wipes prior grants).
2. `browser.cookies` on iOS Safari needs an explicit granted origin that MV3
   `host_permissions` does not auto-confer — it must be user-approved.
3. Unsigned build: Safari may withhold `cookies` from a web extension whose
   containing app is not signed with a real team.
4. Whether the "I agree" consent screen renders at all on a mobile UA is still
   unconfirmed (open question — the `oauth_token` cookie is only written on
   accept).

Diagnostics added after this attempt: a **Dump all cookies** button that also
prints `typeof browser.cookies`, `browser.permissions.getAll()`, and
`permissions.contains({origins:["https://accounts.google.com/*"]})`; plus
`optional_host_permissions: ["*://*/*"]` in the manifest so all-sites access can
be granted; plus content-script logging of the landed URL, page title, and
non-HttpOnly cookie names.

## Manual test script (next attempt — needs your Google account)

1. Rebuild + reinstall (commands above). Launch `GPMCAuthProbe`.
2. **Grant the extension access to every website.** `ᴀA` / puzzle menu on any
   page → **GPMC Connect** → **Always Allow on Every Website** (or Settings →
   Apps → Safari → Extensions → GPMC Connect → **All Websites → Allow**).
   Enabling the extension is not enough — this is the step that grants cookie
   access.
3. **Sanity-check the cookies API first**, before touching EmbeddedSetup:
   open `https://myaccount.google.com` (already signed in), open the **GPMC
   Connect** popup → **Dump all cookies**. Read the top lines:
   - `cookies API: object / getAll: function` and a non-empty
     `granted permissions:` with an `origins` list, **and** `google.com`
     cookies listed → the API works. Proceed to step 4.
   - Still `0 cookie(s)` everywhere and `granted permissions:` shows no
     origins → iOS Safari is not giving this (unsigned) extension cookie
     access. Stop; retest on a signed build (free personal team) before
     drawing any conclusion about the route.
4. (Optional, worth trying) In Safari, `ᴀA` menu → **Request Desktop
   Website**, or add accounts.google.com under Settings → Apps → Safari →
   Request Desktop Website. This sends a macOS UA — the environment gotohp is
   known to work in.
5. Tap **Open Google EmbeddedSetup in Safari** from the app. Sign in.
   **Note whether an "I agree" / consent screen appears and tap it.** Expect
   the page to hang afterward — that's normal.
6. Open the **GPMC Connect** popup → **Dump all cookies**.
   - `oauth_token IS present` → the route works. Tap **Connect account**,
     return to the app, screenshot the checklist (steps 7–9 auto-run).
   - Healthy `accounts.google.com` cookie list but **no `oauth_token`** →
     EmbeddedSetup is not issuing it to this client. Route is likely dead on
     iOS Safari → manual `oauth_token` import is the fallback.
7. Report: the `granted permissions:` line, the cookie names listed for
   `accounts.google.com`, whether "I agree" appeared, and any red-step
   `detail` text.

## If the route is confirmed dead

The Advanced section of the app already accepts a pasted `oauth_token` and runs
the full exchange (`ContentView` → `AuthProbe.runExchange`). That path plus
`GPMCClient.AuthData` (raw `auth_data` import) is the fallback onboarding.
Whether `TokenEncrypted=1` shows up there determines if token binding
(`gotohp backend/tokenbinding.go`) must be ported before shipping.

## Files

```
App/Sources/
  GPMCAuthProbeApp.swift   @main; onOpenURL + scenePhase drain the handoff
  ContentView.swift        checklist UI + "paste an oauth_token" advanced path
  ProbeLog.swift           the 9-step observable checklist
  HandoffStore.swift       App Group drain + gpmcprobe:// ingest, single use
  TokenExchange.swift      oauth_token → master token → Photos credential (gotohp port)
  AuthProbe.swift          orchestrates steps 6–9
Extension/Sources/
  SafariWebExtensionHandler.swift   native endpoint; writes App Group handoff
Extension/WebResources/
  manifest.json   MV3; cookies + nativeMessaging + activeTab; optional_host_permissions *://*/*
  background.js   readOAuthToken, forwardToNative, dumpCookies (+ caps readout)
  content.js      logs landed URL / title / visible cookie names on accounts.google.com
  popup.html/js   Connect account · Check for token · Dump all cookies
GPMC/Core/                 pre-existing sketches; GPMCClient gained
                           validateReadAccess() + TokenEncrypted detection
Tests/GPMCAuthProbeTests/  TokenExchangeTests (offline, 7), LiveExchangeTests (gated)
```
