# GPMCAuthProbe — Safari authentication feasibility probe

Purpose: decide whether GPMC account onboarding can happen **entirely on an
iPhone** via a bundled Safari web extension, or whether it needs a one-time
manual credential import.

The probe is a small app + Safari web extension that runs the checklist from
the handoff plan's Step 2 and reports each step pass/fail on screen.

**Current bottom line (2026-09-08, after attempt 2):** the route works as far as
we can currently test it. The step-3 blocker was **not** permissions and **not**
code signing — iOS Safari exposes more than one cookie store, and a
`cookies.get()` / `getAll()` that omits `storeId` searches only the default
store, which is not the one the browsing tabs use. Sweeping every store from
`cookies.getAllCookieStores()` fixed it. With that fix, **Google's EmbeddedSetup
page does issue an `oauth_token` cookie to mobile Safari** (80 chars, domain
`accounts.google.com`, `httpOnly`, session) and the extension reads it, hands it
to the app, and the app ingests it single-use. Steps 1-6 pass on an **unsigned
simulator build**.

Step 7 (the exchange) is **not yet cleanly measured**: the token was consumed
twice by two operators driving the simulator at once, so the run that reached
Google saw an already-spent token and returned `BadAuthentication`. This says
nothing about the exchange itself — it needs one clean run on a fresh token.

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

## Checklist status (2026-09-08 attempt 2, iOS 18.6 simulator, Xcode 16.4, unsigned)

| # | Checklist step | Status | Evidence / note |
|---|---|---|---|
| 1 | App + Safari extension build & launch | **PASS** | `BUILD SUCCEEDED`; app launched (screenshot); `.appex` embedded in `GPMCAuthProbe.app/PlugIns/`. |
| — | Extension registered with iOS | **PASS** | `simctl spawn "iPhone 16 Pro" pluginkit -mv` lists `dev.gpmc.authprobe.Extension(0.1.0)`. |
| — | Web extension bundle shape | **PASS** | `manifest.json` at bundle root, MV3, `NSExtensionPointIdentifier = com.apple.Safari.web-extension`, `permissions: [cookies, nativeMessaging, activeTab]`, `host_permissions: [https://accounts.google.com/*]`, `optional_host_permissions: [*://*/*]`. |
| 2 | Extension enabled in Safari settings | **PASS** | User enabled it manually in Safari settings. |
| 3 | Host permission effective for accounts.google.com | **PASS** | Root cause was cookie-store partitioning, not permission and not signing. `cookies.getAllCookieStores()` returns multiple stores; queries omitting `storeId` hit the wrong one. `background.js` now sweeps every store. |
| 4 | Extension reads the `oauth_token` cookie | **PASS** | `Found oauth_token` — length 80, domain `accounts.google.com`, `httpOnly: true`, `session: true`. `httpOnly` matters: no content script could have read it, only the `cookies` API. Screenshot `07-oauth-token-found-live.png`. |
| 5 | Cookie handed to native code | **PASS** (via URL channel) | Delivered over the `gpmcprobe://` fallback (`channel: url, captured 12 sec ago`). The App Group path remains inert on an unsigned build, as designed. |
| 6 | App ingests the token, single use | **PASS** | Live: `token length 80; source cleared after read`. |
| 7 | Exchange `oauth_token` → master token | **INCONCLUSIVE** | Request/body match gotohp (`TokenExchangeTests`, 7/7). Live run returned `BadAuthentication` on an **already-spent** token (consumed twice — see Test log attempt 2), so the happy path is still unmeasured. Needs one clean run on a fresh token. |
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

### 2026-09-08 — attempt 2 (unsigned simulator build, storeId fix)

Isolating step 3 first, deliberately **without** any Google account: the failure
reproduces on any cookie-setting site, so `wikipedia.org` was enough.

- **Dump all cookies** on wikipedia.org with no `storeId` → `0 cookie(s)`, while
  `browser.cookies` was a live object and `permissions.getAll()` listed granted
  origins. Permission was never the problem
  (`01-dump-no-storeid-wikipedia.png`).
- `cookies.getAllCookieStores()` returned **more than one store**, and querying
  each store explicitly returned the cookies (`02-cookiestore-partition-evidence.png`,
  `03-both-contexts-storeid-confirmed.png`).

**Root cause:** iOS Safari partitions cookies across multiple stores. A
`cookies.get()` / `getAll()` that omits `storeId` searches only the default
store, which is *not* the store the browsing tabs use, and returns zero cookies
for every site. That is indistinguishable at the call site from a denied
permission, which is what sent attempt 1 chasing permissions and code signing.

**Fix:** `background.js` now enumerates `cookies.getAllCookieStores()` and
sweeps every store in both `readOAuthToken()` and `dumpCookies()`
(`04-self-test-pass.png`, `05-dump-after-fix.png`).

This retires candidate causes 1-3 from attempt 1. Candidate 4 is also retired:
the EmbeddedSetup consent screen **does** render on a mobile UA — no desktop-UA
override was needed (`06-embeddedsetup-renders-on-mobile.png`).

With a real account signed in on EmbeddedSetup:

- **GPMC Connect → Check for token** → `Found oauth_token`, length 80, domain
  `accounts.google.com`, `httpOnly: true`, `session: true`
  (`07-oauth-token-found-live.png`). **This answers ADR-001's open question: yes,
  mobile Safari receives the cookie.** `httpOnly: true` also confirms the
  `cookies` API is load-bearing — a content script could never have read it.
- **Connect account** → delivered over `gpmcprobe://` (`channel: url`), app
  ingested it single-use, `source cleared after read`. Steps 1-6 green
  (`08-app-checklist-top.png`).
- Step 7 → `BadAuthentication — the oauth_token is invalid or already spent`
  (`09-app-checklist-token-already-spent.png`).

**Caveat on step 7, important:** two operators were driving the simulator
concurrently and **Connect account ran twice**, so the token was consumed twice.
`oauth_token` is single-use; the second exchange was always going to fail this
way. Treat step 7 as *unmeasured*, not failed. It needs one clean run on a fresh
token before any conclusion is drawn.

**Consequence for ADR-001:** the claim that "a real Apple Developer team is
probably needed even to evaluate this route" is **refuted**. Cookie access,
capture, handoff and ingest all work unsigned. A team is still required for the
App Group handoff channel (shipping), but not for evaluation.

## Manual test script (next run — one clean shot at step 7)

Steps 1-6 are settled. The only thing left to measure is the exchange, and it
must be done on a **fresh** `oauth_token` with **exactly one** Connect account
tap. Do not run two operators against the simulator at once.

1. Launch `GPMCAuthProbe`. Confirm the extension is enabled and has All Websites
   access (a reinstall wipes the grant).
2. Tap **Open Google EmbeddedSetup in Safari**. EmbeddedSetup always starts a
   full add-account sign-in — an existing Safari session is not reused, so the
   account password is required here.
3. Sign in and tap **I agree**. The page then hangs on a spinner; that is
   expected and means the cookie has been written.
4. Open the **GPMC Connect** popup → **Check for token** → expect
   `Found oauth_token`.
5. Tap **Connect account** **once**. Accept the `gpmcprobe://` dialog once.
   If a second dialog appears, **cancel it** — accepting it re-ingests a spent
   token and will paint step 7 red for no reason.
6. Return to the app. Steps 7-9 run automatically. Screenshot the checklist.
7. Report: the step 7 result, and if green, whether step 8 reported
   `TokenEncrypted=1` — that decides whether token binding must be ported
   before shipping.

If step 7 fails again on a demonstrably fresh single-use token, the likely
suspects are the `droidguard_results: "dummy123"` placeholder in
`TokenExchange.oauthExchangeBody` and the `Email` placeholder, both inherited
from gotohp.

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
