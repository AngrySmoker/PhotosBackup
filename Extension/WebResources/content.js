// GPMC Connect — content script on accounts.google.com.
//
// Cannot read the HttpOnly oauth_token cookie. It only reports, to the
// extension console, what page the flow actually landed on and which
// non-HttpOnly cookies exist there — enough to tell "EmbeddedSetup never
// showed the consent screen" apart from "consent happened but no cookie".

(function () {
  const path = location.pathname;
  const isEmbeddedSetup = /embeddedsetup/i.test(path) || /embedded\/setup/i.test(path);
  const visibleCookieNames = document.cookie
    .split(";")
    .map((c) => c.trim().split("=")[0])
    .filter(Boolean);

  console.log(
    `[GPMC Connect] on ${location.host}${path}` +
      ` | embeddedSetup=${isEmbeddedSetup}` +
      ` | title=${JSON.stringify(document.title)}` +
      ` | non-HttpOnly cookies=[${visibleCookieNames.join(", ")}]`
  );

  // Log any button/text that looks like the consent step, so we can confirm
  // whether "I agree" is even being rendered on a mobile UA.
  const bodyText = (document.body && document.body.innerText || "").slice(0, 400);
  if (/agree|consent|terms/i.test(bodyText)) {
    console.log(`[GPMC Connect] consent-like text on page: ${JSON.stringify(bodyText.slice(0, 200))}`);
  }

  const notify = () => {
    try {
      browser.runtime.sendMessage({
        type: "probe:page-sighting",
        href: location.href,
        title: document.title,
        embeddedSetup: isEmbeddedSetup,
        consentLike: /agree|consent|terms/i.test(
          (document.body && document.body.innerText) || ""
        ),
        visibleCookieNames,
      });
    } catch (e) {
      console.log("[GPMC Connect] could not notify background:", String(e));
    }
  };
  if (document.readyState === "complete") notify();
  else window.addEventListener("load", notify, { once: true });
})();
