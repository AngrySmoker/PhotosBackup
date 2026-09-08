// GPMC Connect — background service worker.
//
// Responsibilities:
//   1. Answer popup requests for the current oauth_token cookie.
//   2. Forward a captured token to the native handler via sendNativeMessage.
//
// The oauth_token cookie on accounts.google.com is HttpOnly, so it is only
// reachable through the privileged browser.cookies API from here / the popup —
// never from a content script's document.cookie. That is the whole reason this
// extension exists instead of a page script.

const COOKIE_URL = "https://accounts.google.com";
const COOKIE_NAME = "oauth_token";
// On iOS/macOS Safari the applicationIdentifier argument is ignored (messages
// route to the bundled handler), but the API still requires a string.
const NATIVE_APP_ID = "dev.gpmc.authprobe.Extension";

/// Every cookie store Safari exposes, plus `undefined` for "whatever the
/// default is". iOS Safari hands out more than one persistent store, and a
/// `cookies.get()` / `getAll()` call that omits `storeId` only searches the
/// default one — which on iOS is *not* the store the browsing tabs use. That
/// silently returns zero cookies for every site and looks exactly like a
/// missing permission. So: always sweep every store.
async function cookieStoreIds() {
  try {
    const stores = await browser.cookies.getAllCookieStores();
    const ids = (stores || []).map((s) => s.id).filter(Boolean);
    return ids.length ? ids : [undefined];
  } catch (_) {
    return [undefined];
  }
}

async function readOAuthToken() {
  let lastError = null;
  let sawStore = false;
  try {
    for (const storeId of await cookieStoreIds()) {
      sawStore = true;
      const query = { url: COOKIE_URL, name: COOKIE_NAME };
      if (storeId !== undefined) query.storeId = storeId;
      let cookie = null;
      try {
        cookie = await browser.cookies.get(query);
      } catch (err) {
        lastError = err;
        continue;
      }
      if (cookie && cookie.value) {
        return {
          ok: true,
          value: cookie.value,
          domain: cookie.domain,
          storeId: storeId || null,
          secure: cookie.secure,
          httpOnly: cookie.httpOnly,
          session: cookie.session,
          expirationDate: cookie.expirationDate || null,
        };
      }
    }
  } catch (err) {
    // Most commonly: host permission for accounts.google.com not granted yet.
    return { ok: false, reason: "cookies-api-error", detail: String(err) };
  }
  if (lastError && !sawStore) {
    return { ok: false, reason: "cookies-api-error", detail: String(lastError) };
  }
  return {
    ok: false,
    reason: "cookie-absent",
    detail: lastError ? `last store error: ${String(lastError)}` : "searched every cookie store",
  };
}

async function forwardToNative(payload) {
  try {
    const response = await browser.runtime.sendNativeMessage(NATIVE_APP_ID, payload);
    return { ok: true, response };
  } catch (err) {
    return { ok: false, reason: "native-messaging-error", detail: String(err) };
  }
}

async function dumpCookies() {
  const out = { ok: true, groups: {}, caps: {} };
  out.caps.cookiesApi = typeof browser.cookies;
  out.caps.getAll = typeof (browser.cookies && browser.cookies.getAll);
  try {
    out.caps.permissions = await browser.permissions.getAll();
  } catch (e) {
    out.caps.permissions = { error: String(e) };
  }
  try {
    out.caps.originAllowed_accounts = await browser.permissions.contains({
      origins: ["https://accounts.google.com/*"],
    });
  } catch (e) {
    out.caps.originAllowed_accounts = String(e);
  }
  try {
    out.caps.originAllowed_all = await browser.permissions.contains({
      origins: ["*://*/*"],
    });
  } catch (e) {
    out.caps.originAllowed_all = String(e);
  }
  try {
    const m = browser.runtime.getManifest();
    out.caps.manifest = {
      permissions: m.permissions || [],
      host_permissions: m.host_permissions || [],
      optional_host_permissions: m.optional_host_permissions || [],
    };
  } catch (e) {
    out.caps.manifest = { error: String(e) };
  }
  try {
    out.caps.cookieStores = await browser.cookies.getAllCookieStores();
  } catch (e) {
    out.caps.cookieStores = { error: String(e) };
  }
  // Without the "tabs" permission Safari only exposes tab.url when the
  // extension actually holds host permission for that tab. So an empty url
  // here means "no site access granted for the page you are looking at" —
  // which is the exact discriminator between a missing grant and a missing
  // cookies API.
  let activeURL = null;
  try {
    const tabs = await browser.tabs.query({ active: true, currentWindow: true });
    const t = (tabs && tabs[0]) || {};
    activeURL = t.url || null;
    out.caps.activeTab = {
      url: t.url || "(withheld — no host permission for this tab)",
      title: t.title || "(withheld)",
    };
  } catch (e) {
    out.caps.activeTab = { error: String(e) };
  }

  out.caps.lastPageSighting = lastPageSighting;

  // The one that matters: sweep every store, the way readOAuthToken now does.
  try {
    const merged = [];
    for (const storeId of await cookieStoreIds()) {
      const q = { domain: "accounts.google.com" };
      if (storeId !== undefined) q.storeId = storeId;
      for (const c of await browser.cookies.getAll(q)) {
        merged.push(`${c.name}${c.name === COOKIE_NAME ? " ***" : ""}`);
      }
    }
    out.caps.accountsGoogleAcrossStores = merged;
  } catch (e) {
    out.caps.accountsGoogleAcrossStores = [`error: ${String(e)}`];
  }

  const filters = {
    "all (no filter)": {},
    "domain=google.com": { domain: "google.com" },
    "domain=accounts.google.com": { domain: "accounts.google.com" },
    "url=https://accounts.google.com/embedded/setup/android": {
      url: "https://accounts.google.com/embedded/setup/android",
    },
    "domain=wikipedia.org": { domain: "wikipedia.org" },
    "url=https://example.com/": { url: "https://example.com/" },
  };
  if (activeURL) {
    filters[`url=${activeURL}`] = { url: activeURL };
  }
  // Safari hands out more than one cookie store (the tab the popup was opened
  // from may not live in the default one). getAll() with no storeId only looks
  // at the default store, so sweep every store explicitly.
  const stores = Array.isArray(out.caps.cookieStores) ? out.caps.cookieStores : [];
  for (const s of stores) {
    filters[`storeId=${s.id} (all)`] = { storeId: s.id };
    if (activeURL) {
      filters[`storeId=${s.id} url=${activeURL}`] = { storeId: s.id, url: activeURL };
    }
    filters[`storeId=${s.id} domain=accounts.google.com`] = {
      storeId: s.id,
      domain: "accounts.google.com",
    };
  }
  for (const [label, filter] of Object.entries(filters)) {
    try {
      const cookies = await browser.cookies.getAll(filter);
      out.groups[label] = cookies.map((c) => ({
        name: c.name,
        domain: c.domain,
        path: c.path,
        secure: c.secure,
        httpOnly: c.httpOnly,
        session: c.session,
        len: (c.value || "").length,
      }));
    } catch (err) {
      out.groups[label] = { error: String(err) };
    }
  }
  return out;
}

/// Proves the capture path (write → read → clean up) without any Google
/// account: plant a throwaway `oauth_token` on accounts.google.com in every
/// cookie store, read it back through the real `readOAuthToken()`, then delete
/// it. A PASS here means step 3/4 of the checklist are mechanically sound and
/// the only remaining unknown is whether Google itself issues the cookie.
const SELF_TEST_VALUE = "PROBE-FAKE-NOT-A-REAL-TOKEN";

async function selfTestCookiePath() {
  const steps = [];
  const stores = await cookieStoreIds();
  let planted = 0;
  for (const storeId of stores) {
    const spec = {
      url: COOKIE_URL + "/",
      name: COOKIE_NAME,
      value: SELF_TEST_VALUE,
      path: "/",
      secure: true,
    };
    if (storeId !== undefined) spec.storeId = storeId;
    try {
      const c = await browser.cookies.set(spec);
      steps.push(`set in ${storeId}: ${c ? "ok" : "returned null"}`);
      if (c) planted += 1;
    } catch (e) {
      steps.push(`set in ${storeId}: ${String(e)}`);
    }
  }
  const readBack = await readOAuthToken();
  steps.push(`readOAuthToken(): ${JSON.stringify({ ...readBack, value: undefined })}`);
  for (const storeId of stores) {
    const spec = { url: COOKIE_URL + "/", name: COOKIE_NAME };
    if (storeId !== undefined) spec.storeId = storeId;
    try {
      await browser.cookies.remove(spec);
    } catch (e) {
      steps.push(`remove in ${storeId}: ${String(e)}`);
    }
  }
  const after = await readOAuthToken();
  steps.push(`after cleanup: ${after.ok ? "STILL PRESENT (bad)" : after.reason}`);
  return {
    ok: true,
    planted,
    pass: readBack.ok && readBack.value === SELF_TEST_VALUE && !after.ok,
    steps,
  };
}

// Last thing the content script saw on accounts.google.com, surfaced in the
// dump so the popup can answer "did the consent screen actually render on a
// mobile UA?" without anyone reading a Web Inspector console.
let lastPageSighting = null;

browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  (async () => {
    if (message && message.type === "probe:page-sighting") {
      lastPageSighting = { ...message, at: new Date().toISOString() };
      sendResponse({ ok: true });
      return;
    }
    if (message && message.type === "probe:read-cookie") {
      sendResponse(await readOAuthToken());
      return;
    }
    if (message && message.type === "probe:dump-cookies") {
      sendResponse(await dumpCookies());
      return;
    }
    if (message && message.type === "probe:self-test") {
      sendResponse(await selfTestCookiePath());
      return;
    }
    if (message && message.type === "probe:request-permissions") {
      // Must originate from a user gesture in the popup. Safari may either
      // show a prompt or silently refuse; either outcome is informative.
      try {
        const granted = await browser.permissions.request({
          origins: ["*://*/*"],
          permissions: ["cookies"],
        });
        sendResponse({ ok: true, granted, after: await browser.permissions.getAll() });
      } catch (e) {
        sendResponse({ ok: false, reason: "permissions-request-error", detail: String(e) });
      }
      return;
    }
    if (message && message.type === "probe:connect") {
      const token = await readOAuthToken();
      if (!token.ok) {
        sendResponse({ stage: "read", ...token });
        return;
      }
      const handoff = await forwardToNative({
        type: "oauth_token",
        value: token.value,
        domain: token.domain,
        capturedAt: new Date().toISOString(),
        source: "EmbeddedSetup",
      });
      sendResponse({ stage: "handoff", tokenMeta: redact(token), ...handoff });
      return;
    }
    sendResponse({ ok: false, reason: "unknown-message" });
  })();
  return true; // keep the message channel open for the async sendResponse
});

function redact(token) {
  const v = token.value || "";
  return {
    length: v.length,
    preview: v.length > 12 ? `${v.slice(0, 6)}…${v.slice(-4)}` : "…",
    domain: token.domain,
    httpOnly: token.httpOnly,
    session: token.session,
  };
}
