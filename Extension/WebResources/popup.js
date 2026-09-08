// GPMC Connect — popup controller.

const statusEl = document.getElementById("status");
const connectBtn = document.getElementById("connect");
const peekBtn = document.getElementById("peek");
const dumpBtn = document.getElementById("dump");
const grantBtn = document.getElementById("grant");
const selfTestBtn = document.getElementById("selftest");

selfTestBtn.addEventListener("click", async () => {
  show("Self-testing (plant → read → delete)…");
  const res = await browser.runtime.sendMessage({ type: "probe:self-test" });
  if (!res || !res.ok) {
    show(`Self-test failed to run: ${JSON.stringify(res)}`, "err");
    return;
  }
  show(
    `${res.pass ? "SELF-TEST PASS" : "SELF-TEST FAIL"} (planted in ${res.planted} store(s))\n\n` +
      res.steps.join("\n"),
    res.pass ? "ok" : "err"
  );
});

grantBtn.addEventListener("click", async () => {
  show("Requesting…");
  try {
    // Try from the popup first: permissions.request() must run in a page with
    // a user gesture, and on Safari the popup qualifies where the background
    // worker may not.
    const granted = await browser.permissions.request({
      origins: ["*://*/*"],
      permissions: ["cookies"],
    });
    const after = await browser.permissions.getAll();
    show(`popup request → granted=${granted}\nnow: ${JSON.stringify(after)}`, granted ? "ok" : "err");
  } catch (e) {
    const res = await browser.runtime.sendMessage({ type: "probe:request-permissions" });
    show(`popup request threw: ${String(e)}\nbackground → ${JSON.stringify(res)}`, "err");
  }
});

// Same call, but made from the popup page instead of the background worker.
// Safari's activeTab / temporary grants attach to the page the user actually
// interacted with, so a difference between the two contexts is itself a result.
async function localProbe() {
  const lines = ["--- popup-context probe ---"];
  try {
    lines.push(`popup typeof browser.cookies: ${typeof browser.cookies}`);
    const all = await browser.cookies.getAll({});
    lines.push(`popup getAll({}): ${all.length} cookie(s)`);
    const stores = await browser.cookies.getAllCookieStores();
    for (const s of stores) {
      const c = await browser.cookies.getAll({ storeId: s.id });
      lines.push(`popup getAll({storeId:${s.id}}): ${c.length} cookie(s)`);
    }
  } catch (e) {
    lines.push(`popup probe threw: ${String(e)}`);
  }
  return lines.join("\n");
}

dumpBtn.addEventListener("click", async () => {
  show("Dumping…");
  const local = await localProbe();
  const res = await browser.runtime.sendMessage({ type: "probe:dump-cookies" });
  if (!res || !res.ok) {
    show(`Dump failed: ${JSON.stringify(res)}`, "err");
    return;
  }
  const lines = [];
  if (res.caps) {
    lines.push(
      `accounts.google.com across ALL stores: ${JSON.stringify(res.caps.accountsGoogleAcrossStores)}`
    );
    lines.push(`cookies API: ${res.caps.cookiesApi} / getAll: ${res.caps.getAll}`);
    lines.push(`origin allowed (accounts.google.com): ${res.caps.originAllowed_accounts}`);
    lines.push(`origin allowed (*://*/*): ${res.caps.originAllowed_all}`);
    lines.push(`granted permissions: ${JSON.stringify(res.caps.permissions)}`);
    lines.push(`manifest: ${JSON.stringify(res.caps.manifest)}`);
    lines.push(`cookie stores: ${JSON.stringify(res.caps.cookieStores)}`);
    lines.push(`active tab: ${JSON.stringify(res.caps.activeTab)}`);
    lines.push(`last accounts.google.com page seen: ${JSON.stringify(res.caps.lastPageSighting)}`);
    lines.push("");
  }
  for (const [label, entries] of Object.entries(res.groups)) {
    if (Array.isArray(entries)) {
      lines.push(`${label}: ${entries.length} cookie(s)`);
      for (const c of entries) {
        lines.push(`  ${c.name}  @${c.domain}${c.path}  ${c.httpOnly ? "httpOnly " : ""}len${c.len}`);
      }
    } else {
      lines.push(`${label}: ${entries.error}`);
    }
  }
  lines.push("");
  lines.push(local);
  const hasOAuth =
    JSON.stringify(res.groups).includes('"oauth_token"') ||
    JSON.stringify(res.caps.accountsGoogleAcrossStores || []).includes("oauth_token");
  show((hasOAuth ? "oauth_token IS present below\n\n" : "oauth_token NOT in any group\n\n") + lines.join("\n"),
       hasOAuth ? "ok" : "err");
});

function show(text, cls) {
  statusEl.textContent = text;
  statusEl.className = cls || "";
}

peekBtn.addEventListener("click", async () => {
  show("Checking…");
  const res = await browser.runtime.sendMessage({ type: "probe:read-cookie" });
  if (res && res.ok) {
    show(
      `Found oauth_token\n  length: ${res.value.length}\n  domain: ${res.domain}\n  httpOnly: ${res.httpOnly}\n  session: ${res.session}`,
      "ok"
    );
  } else {
    show(`No token yet (${(res && res.reason) || "unknown"})\n${(res && res.detail) || ""}`, "err");
  }
});

connectBtn.addEventListener("click", async () => {
  connectBtn.disabled = true;
  show("Reading cookie and handing off…");
  const res = await browser.runtime.sendMessage({ type: "probe:connect" });

  if (res && res.stage === "read" && !res.ok) {
    show(`Could not read oauth_token (${res.reason}).\n${res.detail || ""}`, "err");
    connectBtn.disabled = false;
    return;
  }

  if (res && res.stage === "handoff") {
    const meta = res.tokenMeta || {};
    if (res.ok) {
      const channel = (res.response && res.response.channel) || "native";
      show(
        `Handed off via ${channel}.\n  token: ${meta.preview} (len ${meta.length})\nReturn to the GPMC Auth Probe app.`,
        "ok"
      );
      // On an unsigned simulator build the native side has no App Group to
      // write to; it reports channel === "none". Fall back to the URL handoff
      // so the probe can still complete end to end.
      if (channel === "none") {
        await urlHandoff(res.response && res.response.token, meta);
      }
      return;
    }
    // Native messaging itself failed — last-resort URL handoff for the probe.
    show(`Native handoff failed (${res.reason}).\nTrying URL handoff…`, "err");
    await urlHandoff(null, meta);
    connectBtn.disabled = false;
  }
});

async function urlHandoff(token, meta) {
  // The background worker returns the raw token only when it could not persist
  // it natively, precisely so this fallback can forward it. This path is for
  // the feasibility probe only and is not a production handoff.
  if (!token) {
    show(
      `${statusEl.textContent}\n\nURL handoff needs the raw token but none was returned.\nRun on a signed build with the App Group enabled.`,
      "err"
    );
    return;
  }
  const url = `gpmcprobe://token?value=${encodeURIComponent(token)}&capturedAt=${encodeURIComponent(
    new Date().toISOString()
  )}`;
  try {
    await browser.tabs.create({ url });
    show(`${statusEl.textContent}\n\nOpened gpmcprobe:// handoff.`, "ok");
  } catch (e) {
    show(`${statusEl.textContent}\n\nCould not open URL handoff: ${String(e)}`, "err");
  }
}
