// Herdwick push relay: turns a host watcher's post into an APNs alert. Stateless; stores
// nothing, logs nothing and sees only opaque ids. Secrets: APNS_KEY (the .p8 PEM),
// APNS_KEY_ID, APNS_TEAM_ID. Var: APNS_TOPIC.
//
// POST /v1/push {token, env, host, session, pane, state, seq} → 204.
//
// The alert text is fixed here and the ids mean nothing without the phone's own records, so
// whoever holds a device token can at most repeat these two generic alerts to that device, and
// no faster than the rate limit.

const HEX = /^[0-9a-f]{64,200}$/;
const UUID = /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/;
const NAME = /^[A-Za-z0-9._:-]{1,64}$/;
const HOSTS = { production: "api.push.apple.com", development: "api.sandbox.push.apple.com" };
const STATES = { blocked: "An agent needs you", done: "An agent finished" };

export default {
  async fetch(request, env) {
    if (request.method !== "POST") return status(405);
    if (new URL(request.url).pathname !== "/v1/push") return status(404);
    const body = (await readJSON(request)) ?? {};
    const { token, host, session, pane, state, seq } = body;
    if (!HEX.test(token ?? "") || !(body.env in HOSTS) || !(state in STATES) || !UUID.test(host ?? "") ||
        !NAME.test(session ?? "") || !NAME.test(pane ?? "") || !Number.isSafeInteger(seq)) return status(400);
    if (!(await env.LIMIT.limit({ key: token })).success) return status(429);

    // The notification service extension replaces this text with names the phone already knows.
    const alert = {
      aps: {
        alert: { title: "Herdwick", body: STATES[state] },
        ...(state === "blocked" ? { sound: "default" } : {}),
        "thread-id": `${host}/${session}`,
        "mutable-content": 1,
      },
      host, session, pane, state, seq,
    };
    const id = `${host}/${session}/${pane}`;
    const headers = {
      authorization: `bearer ${await providerToken(env)}`,
      "apns-topic": env.APNS_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
    };
    // A newer alert for the same agent replaces the older one, as local alerts do.
    if (id.length <= 64) headers["apns-collapse-id"] = id;
    const sent = await fetch(`https://${HOSTS[body.env]}/3/device/${token}`, {
      method: "POST", headers, body: JSON.stringify(alert),
    });
    return status(sent.ok ? 204 : 502);
  },
};

function status(code) {
  return new Response(null, { status: code });
}

async function readJSON(request) {
  const text = await request.text();
  if (text.length > 1024) return null;
  try { return JSON.parse(text); } catch { return null; }
}

const encoder = new TextEncoder();

function base64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// APNs accepts a provider token for up to an hour and throttles refreshes under 20 minutes.
let cached = { token: "", issued: 0 };

async function providerToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cached.token && now - cached.issued < 45 * 60) return cached.token;
  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = base64url(encoder.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = base64url(encoder.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })));
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(`${head}.${claims}`));
  cached = { token: `${head}.${claims}.${base64url(signature)}`, issued: now };
  return cached.token;
}
