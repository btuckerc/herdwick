// App Store Connect API client for the Mini's scripts. The key is the Mini's
// ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8 (Admin role); the ids come from the
// environment, else ~/.herdwick-signing/asc.env (mode 600).
import { existsSync, readFileSync } from "node:fs";
import { createPrivateKey, sign } from "node:crypto";
import { homedir } from "node:os";

const envFile = `${homedir()}/.herdwick-signing/asc.env`;
const env = { ...(existsSync(envFile) ? Object.fromEntries(readFileSync(envFile, "utf8")
  .split("\n").filter((line) => line.includes("=")).map((line) => line.split("=", 2))) : {}), ...process.env };
const { ASC_KEY_ID: kid, ASC_ISSUER_ID: iss } = env;
if (!kid || !iss) throw new Error("Set ASC_KEY_ID and ASC_ISSUER_ID");
const key = createPrivateKey(readFileSync(`${homedir()}/.appstoreconnect/private_keys/AuthKey_${kid}.p8`));
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");

let token, expires = 0;
function bearer() {
  const now = Math.floor(Date.now() / 1000);
  if (now > expires - 60) {
    expires = now + 1200;
    const input = `${b64({ alg: "ES256", kid, typ: "JWT" })}.${b64({ iss, iat: now, exp: expires, aud: "appstoreconnect-v1" })}`;
    token = `${input}.${sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;
  }
  return token;
}

/** One API call; throws with Apple's error details. Paths start with /v1 or /v2. */
export async function api(method, path, body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method, body: body && JSON.stringify(body),
    headers: { authorization: `Bearer ${bearer()}`, "content-type": "application/json" },
  });
  if (!response.ok) {
    const text = await response.text();
    let detail = text;
    try { detail = JSON.parse(text).errors.map((e) => `${e.detail ?? e.title}${e.source?.pointer ? ` (${e.source.pointer})` : ""}`).join("; "); } catch {}
    const error = new Error(`${method} ${path}: ${response.status} ${detail}`);
    error.status = response.status;
    throw error;
  }
  return response.status === 204 ? null : response.json();
}

/** GET, or null on 404. */
export async function find(path) {
  try { return await api("GET", path); } catch (error) { if (error.status === 404) return null; throw error; }
}
