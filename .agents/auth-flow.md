# Auth flow (read before touching auth code)

Proven end-to-end on iOS simulator. Full rationale: `docs/ADR-001-auth-route.md`.

## Chain

```text
In-app EmbeddedSetup WebView (accounts.google.com, full mobile-Safari UA)
  → AccountConnectView polls WKHTTPCookieStore.getAllCookies() for the oauth_token
    cookie (httpOnly; getAllCookies returns it on iOS 16/17/18 — a Safari web
    extension's browser.cookies does NOT on iOS 17, which is why the extension
    route was dropped; see ADR-001)
  → AccountConnector.ingestWebToken(token) → TokenExchange → master token → Photos access token
  → authenticated photosdata-pa request
```

## Rules

1. **`oauth_token` is single-use.** Triggering handoff twice spends it; second exchange fails → requires fresh sign-in. Never retry an exchange with the same token, never log/store it.
2. **Bound/encrypted tokens rejected:** `TokenEncrypted=1` → `GPMCError.tokenBound`. Do not silently mishandle or try to "support" without a design review.
3. **Credential storage:** single Keychain item, `AfterFirstUnlockThisDeviceOnly`. Unsigned simulator builds can't persist (session-only, warn don't crash). Re-signed builds (7-day free-team refresh) may lose it — "reconnect account" is a normal path.
4. **In-app capture:** the token is read in-process from the app's own non-persistent WKWebView cookie store — no extension, no App Group, no custom-scheme handoff. The web session is discarded on capture. (The old extension + `photosbackup://` handoff has been removed.)
5. **Retry split:** `GPMCClient` owns token refresh (near-expiry + one forced re-auth on 401/403). `UploadQueue` owns whole-item retry (transport/5xx, 3 attempts, exp backoff ≤30s) and halts the queue on credential-rejected.
6. **Live tests need real Google + fresh token** (`TEST_RUNNER_GPMC_LIVE=1`, `TEST_RUNNER_GPMC_OAUTH_TOKEN`). Never commit tokens or captured credentials.
