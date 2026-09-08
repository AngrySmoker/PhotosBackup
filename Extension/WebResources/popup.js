const statusEl = document.getElementById("status");
const titleEl = document.getElementById("title");
const descriptionEl = document.getElementById("description");
const connectBtn = document.getElementById("connect");
const openAppBtn = document.getElementById("open-app");
const peekBtn = document.getElementById("peek");
const dumpBtn = document.getElementById("dump");
const grantBtn = document.getElementById("grant");
const selfTestBtn = document.getElementById("selftest");

function showStatus(text, kind = "") {
  statusEl.textContent = text;
  statusEl.className = `status visible ${kind}`.trim();
}

function setLoading(loading) {
  connectBtn.disabled = loading;
  connectBtn.innerHTML = loading
    ? '<span class="spinner"></span>Connecting securely…'
    : "Connect to App";
}

function showSuccess() {
  document.body.classList.add("success");
  titleEl.textContent = "You’re connected";
  descriptionEl.textContent = "Return to Photos Backup. The app will verify your account and finish setup.";
  document.getElementById("state-icon").innerHTML = `
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round">
      <path d="m5 12 4 4L19 6" />
    </svg>`;
  statusEl.className = "status";
}

function friendlyConnectionError(result) {
  if (!result) return "The extension did not respond. Close this menu and try again.";
  if (result.reason === "cookie-absent") {
    return "We couldn’t find a completed Google sign-in. Make sure you signed in and tapped I agree, then try again.";
  }
  if (result.reason === "cookies-api-error") {
    return "Photos Backup needs access to accounts.google.com. Check Website Access below, then try again.";
  }
  return "We couldn’t connect this time. Return to the Google page, finish signing in, and try again.";
}

connectBtn.addEventListener("click", async () => {
  setLoading(true);
  statusEl.className = "status";
  const result = await browser.runtime.sendMessage({ type: "probe:connect" });

  if (result && result.stage === "read" && !result.ok) {
    showStatus(friendlyConnectionError(result), "err");
    setLoading(false);
    return;
  }

  if (result && result.stage === "handoff" && result.ok) {
    const channel = (result.response && result.response.channel) || "native";
    if (channel === "none") {
      const opened = await urlHandoff(result.response && result.response.token);
      if (!opened) setLoading(false);
      return;
    }
    showSuccess();
    return;
  }

  showStatus("The secure handoff didn’t finish. Please try once more.", "err");
  setLoading(false);
});

openAppBtn.addEventListener("click", async () => {
  openAppBtn.disabled = true;
  openAppBtn.innerHTML = '<span class="spinner"></span>Opening Photos Backup…';
  try {
    await browser.tabs.create({ url: "gpmcprobe://return" });
  } catch (_) {
    showStatus("Return to the Photos Backup app from your Home Screen.", "");
    openAppBtn.disabled = false;
    openAppBtn.textContent = "Open Photos Backup";
  }
});

async function urlHandoff(token) {
  if (!token) {
    showStatus("The app handoff is unavailable on this build. Reopen Photos Backup and try again.", "err");
    return false;
  }
  const url = `gpmcprobe://token?value=${encodeURIComponent(token)}&capturedAt=${encodeURIComponent(new Date().toISOString())}`;
  try {
    await browser.tabs.create({ url });
    showSuccess();
    return true;
  } catch (_) {
    showStatus("Couldn’t open Photos Backup. Return to the app from your Home Screen.", "err");
    return false;
  }
}

peekBtn.addEventListener("click", async () => {
  showStatus("Checking your Google sign-in…");
  const result = await browser.runtime.sendMessage({ type: "probe:read-cookie" });
  if (result && result.ok) showStatus("Google sign-in found. You can connect to the app now.");
  else showStatus(friendlyConnectionError(result), "err");
});

grantBtn.addEventListener("click", async () => {
  showStatus("Requesting website access…");
  try {
    const granted = await browser.permissions.request({
      origins: ["https://accounts.google.com/*"],
      permissions: ["cookies"],
    });
    showStatus(granted ? "Website access is enabled. Try connecting again." : "Website access was not enabled. Allow it in Safari’s extension settings.", granted ? "" : "err");
  } catch (_) {
    showStatus("Open Safari’s extension settings and allow access to accounts.google.com.", "err");
  }
});

selfTestBtn.addEventListener("click", async () => {
  showStatus("Testing the secure handoff…");
  const result = await browser.runtime.sendMessage({ type: "probe:self-test" });
  showStatus(result && result.pass ? "Secure handoff is working." : "The secure handoff test failed. Reopen the app and extension, then retry.", result && result.pass ? "" : "err");
});

dumpBtn.addEventListener("click", async () => {
  showStatus("Collecting diagnostics…");
  const result = await browser.runtime.sendMessage({ type: "probe:dump-cookies" });
  if (!result || !result.ok) {
    showStatus("Diagnostics could not run.", "err");
    return;
  }
  const stores = Array.isArray(result.caps && result.caps.cookieStores) ? result.caps.cookieStores.length : 0;
  const permitted = result.caps && result.caps.originAllowed_accounts;
  const found = JSON.stringify(result.groups || {}).includes('"oauth_token"') ||
    JSON.stringify((result.caps && result.caps.accountsGoogleAcrossStores) || []).includes("oauth_token");
  showStatus(`Website access: ${permitted ? "yes" : "no"}\nCookie stores: ${stores}\nCompleted sign-in: ${found ? "found" : "not found"}`, found ? "" : "err");
});
