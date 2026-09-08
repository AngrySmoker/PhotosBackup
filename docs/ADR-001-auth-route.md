# ADR-001 — Authentication route for the iOS GPMC uploader

Status: proposed (pending the feasibility-probe result)
Date: 2026-09-08

## Context

GPMC authenticates to Google Photos' private `photos.native` API with an
Android-style master token. Its README obtains that token from a rooted /
emulated Android device. The companion project **gotohp**
(`0637c745dc590d74766b24eac80d689d2248e766`) removed the Android requirement:
it signs in on Google's `EmbeddedSetup` web page, reads the `oauth_token`
cookie, and exchanges it server-side for the master token and then a Photos
credential.

We want the same account onboarding to happen entirely on an iPhone.

## Decision

Target a **standalone SwiftUI iPhone app** (no companion server or desktop
process during normal operation) that authenticates via the gotohp browser
flow, with a **bundled Safari web extension** capturing the `oauth_token`
cookie so the user never touches developer tools.

Concrete parameters:

| Item | Choice | Rationale |
|---|---|---|
| Minimum iOS | 16.0 | Safari web extensions with MV3 + `browser.cookies`; `NavigationStack`. Revisit to 17 only if a needed API forces it. |
| Auth route | Safari extension → `oauth_token` → gotohp exchange | Only route that keeps full GPMC functionality *and* can run on-device. Public Photos API scopes are not equivalent and are a separate product decision. |
| Handoff (extension → app) | App Group container, single-use, file-protected | Shared process-less channel; `gpmcprobe://` URL handoff exists **only** as a probe fallback for unsigned builds and must not ship. |
| Upstream refs | GPMC `94b1b267…` for protocol; gotohp `0637c745…` for auth + protocol fixes | Preserve MIT notices from both. |
| First-release scope | Account connect + explicit photo/video upload + activity queue. Live Photos, background transfer hardening, Android-credential import (incl. token binding) are follow-ups. | Keep the first release provable end to end. |

## Open question this ADR is blocked on

Does mobile Safari on `accounts.google.com/EmbeddedSetup` receive an
`oauth_token` cookie, and does the exchange succeed from an iOS-originated
request? The `GPMCAuthProbe` target exists to answer exactly this. If the
answer is no, the fallback is a one-time manual `oauth_token` / `auth_data`
import under advanced setup (already sketched in `GPMCClient.AuthData`).

**Status 2026-09-08 (attempt 5): answered yes; the decision stands.** All nine
checklist steps pass on an **unsigned simulator build** — EmbeddedSetup issues an
`oauth_token` to mobile Safari, the extension reads it (`httpOnly`, so only the
`cookies` API could), the app ingests it single-use, and it exchanges into a
master token, a Photos access token, and a successful `photosdata-pa` call. The
consent screen renders on a mobile UA; no desktop-UA override is needed. **No
`TokenEncrypted=1`**, so token binding does not need porting.

Attempt 1's conclusion that "a real Apple Developer team is probably needed even
to evaluate this route" was **wrong**, and is retracted. Both blockers were bugs
in this port: the extension queried only the default cookie store (iOS Safari
partitions them), and a refactor had dropped the request body so every protobuf
RPC posted zero bytes. Neither was an entitlement problem.

A team is still required to **ship**: the App Group handoff and the Keychain both
need one. Without it the credential cannot be persisted, so a connected account
is session-only — surfaced as a warning, not a rejection.

## Consequences

- The app carries a Safari web extension target and its review surface.
- Token binding (`TokenEncrypted=1`) is explicitly detected and rejected for
  now, not silently mishandled — see `TokenExchange` and `GPMCClient`.
- Shipping requires a real Apple Developer team for the App Group entitlement;
  the probe documents the unsigned-simulator gap.
