# GPMCAuthProbe — Safari authentication feasibility probe

Purpose: decide whether GPMC account onboarding can happen **entirely on an
iPhone** via a bundled Safari web extension, or whether it needs a one-time
manual credential import.

The probe is a small app + Safari web extension that runs the checklist from
the handoff plan's Step 2 and reports each step pass/fail on screen.

**Current bottom line (2026-09-08, after attempt 3):** the route is confirmed
end to end through the credential exchange. The step-3 blocker was **not**
permissions and **not** code signing — iOS Safari exposes more than one cookie
store, and a `cookies.get()` / `getAll()` that omits `storeId` searches only the
default store, which is not the one the browsing tabs use. With that fixed,
steps 1-8 all pass on an **unsigned simulator build**: EmbeddedSetup issues an
`oauth_token` to mobile Safari, the extension reads it, the app ingests it, and
it exchanges cleanly into an Android master token and a Photos access token.
**No `TokenEncrypted=1`** — token binding does not have to be ported.

Step 9 (the read-only Photos call) returned HTTP 400 on its first live run. That
was a bug in this port, now fixed: the `x-goog-ext-*-bin` headers were being
sent on every photosdata-pa RPC, but upstream sends them only on commit and
album calls — never on the hash lookup. It needs one more fresh token to confirm
green.

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
| 7 | Exchange `oauth_token` → master token | **PASS** | Live, on a fresh token: master token issued for `alexguroov@gmail.com`, androidId `636428d840be3e65`. |
| 8 | Exchange master token → Photos access token | **PASS** | Access token issued, expires in 16 hr. **No `TokenEncrypted=1`** — this account's credential is unbound, so token binding does not need porting for it. |
| 9 | Read-only Photos request succeeds | **FIXED, AWAITING RETEST** | Two live runs returned HTTP 400. Real cause: `request()` stopped assigning `httpBody`, so every protobuf RPC posted an empty body. Fixed, with a regression test that reads the outgoing body. Needs one fresh token to confirm green. |

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

### 2026-09-08 — attempt 3 (fresh token, single clean run)

- Steps 1-6 green again, unchanged.
- **Step 7 PASS.** Master token issued; `account: alexguroov@gmail.com ·
  androidId: 636428d840be3e65`.
- **Step 8 PASS.** `access token issued, expires in 16 hr`. Critically, **no
  `TokenEncrypted=1`** — the credential is unbound, so `tokenbinding.go` does
  not need porting for this account.
- **Step 9 FAIL — HTTP 400**, and the cause was ours, not Google's.

**Root cause of the 400.** `GPMCClient.rpc()` attached
`x-goog-ext-173412678-bin` and `x-goog-ext-174067345-bin` to *every*
photosdata-pa call. Upstream does not: in gotohp @ 0637c745 `backend/api.go`,
those headers are set by `doCommitRequest`, `CreateAlbum` and `AddMediaToAlbum`,
but **not** by `FindRemoteMediaByHash`. Sending them on the hash lookup gets it
rejected with 400. A 400 (rather than 401/403) was the tell: the credential was
fine — step 8 had just succeeded — so the request itself was malformed.

This was **not** a probe-only bug. `validateReadAccess()` and the duplicate
check inside `upload()` build the identical message and went through the same
`rpc()` helper, so every upload's dedupe step would have failed the same way.

**Fix:** the extension headers are now opt-in per RPC (`rpc(_:body:ext:)`),
set only on the commit call. Covered by
`GPMCClientTests.testHashLookupOmitsTheExtensionHeadersThatCommitSends`, which
was confirmed to fail against the old behaviour before being kept.

**Still to confirm:** step 9 green on a fresh token.

### 2026-09-08 — attempt 4 (step 9 still 400; real cause found)

Steps 1-8 green again on a fresh token (androidId `09397f559fa298da`, access
token 17 hr). Step 9 still **HTTP 400**, so the attempt-3 header change was not
the cause.

Checked the request against gotohp @ 0637c745 field by field before touching
anything else. The message body is byte-identical to `generated/HashCheck.pb.go`
(`HashCheck{field1{field1{sha1Hash}, field2{}}}`); the credential pairs, the
`oauth2:openid …/photos.native` scope, `lang=en_US` and the derived User-Agent
all match upstream exactly. Nothing in the protocol was wrong.

**Real cause: the request body was never sent.** When `GPMCClient.request()` was
refactored to route through a shared `send(_:file:delegate:)` helper, the
`request.httpBody = body` assignment was dropped — the original had it inline in
the non-file branch. Every protobuf RPC was posting `Content-Type:
application/x-protobuf` with **zero bytes**, which Google answers with 400. The
compiler said nothing: `body` still looked used, because the re-auth retry path
passes it along.

This affected every RPC, not just the probe: the duplicate check and the commit
call in `upload()` were equally empty.

**Fixed**, and covered by `testRpcActuallySendsItsProtobufBody`, which drains
`httpBodyStream` (URLProtocol never sees `httpBody`) and was confirmed to fail
against the broken build.

Two diagnostics added so the next wire-format bug is not another guessing round:

- Non-2xx errors now quote Google's response body (`GPMCClient.explanation`) —
  printable bodies verbatim, protobuf ones as a hex prefix. Previously the body
  was discarded and only the status code survived.
- **Re-run read-only check** in the app repeats step 9 against the credential
  already held in memory. The Photos access token lasts ~17 hours while an
  `oauth_token` is single-use, so iterating no longer costs an interactive
  sign-in each time.

## Manual test script (next run — confirm step 9)

Steps 1-8 are settled. Only step 9 is open.

Because the app now keeps the exchange result in memory, this no longer needs a
sign-in **if the app has not been relaunched since the last exchange**: just tap
**Re-run read-only check**.

Otherwise, one fresh token:

1. Rebuild + reinstall (commands above), launch `GPMCAuthProbe`.
2. **Open Google EmbeddedSetup in Safari** → sign in → **I agree**. The page
   then hangs on a spinner; expected.
3. **GPMC Connect** popup → **Connect account**, **once**. Accept the
   `gpmcprobe://` dialog once; **cancel** any second one.
4. Step 9 should be green. If it is not, the failure text now carries Google's
   own explanation — capture that line verbatim before changing anything, and
   use **Re-run read-only check** to iterate without burning another sign-in.

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
