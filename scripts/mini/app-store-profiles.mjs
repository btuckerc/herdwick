// Creates (or recreates) the App Store provisioning profiles TestFlight builds sign with, through
// the App Store Connect API, and installs them for Xcode. Run on the Mini after adding a target or
// changing a capability:  ASC_KEY_ID=… ASC_ISSUER_ID=… node scripts/mini/app-store-profiles.mjs
// Signing needs the Apple Distribution identity in the herdwick-build keychain (see
// sync-and-build.sh); no Apple ID has to be signed in to Xcode.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createPrivateKey, sign } from "node:crypto";
import { homedir } from "node:os";

const targets = {
  "dev.btuckerc.herdwick": "Herdwick App Store",
  "dev.btuckerc.herdwick.widgets": "Herdwick Widgets App Store",
  "dev.btuckerc.herdwick.notifications": "Herdwick Notifications App Store",
};

const { ASC_KEY_ID: kid, ASC_ISSUER_ID: iss } = process.env;
if (!kid || !iss) throw new Error("Set ASC_KEY_ID and ASC_ISSUER_ID");
const key = createPrivateKey(readFileSync(`${homedir()}/.appstoreconnect/private_keys/AuthKey_${kid}.p8`));
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const input = `${b64({ alg: "ES256", kid, typ: "JWT" })}.${b64({ iss, iat: now, exp: now + 900, aud: "appstoreconnect-v1" })}`;
const token = `${input}.${sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" }).toString("base64url")}`;

async function api(method, path, body) {
  const response = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method, body: body && JSON.stringify(body),
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
  });
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`);
  return response.status === 204 ? null : response.json();
}

const certificates = (await api("GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION")).data;
if (certificates.length === 0) throw new Error("No Apple Distribution certificate");
const profiles = (await api("GET", "/v1/profiles?limit=200")).data;
const directory = `${homedir()}/Library/Developer/Xcode/UserData/Provisioning Profiles`;
mkdirSync(directory, { recursive: true });

for (const [identifier, name] of Object.entries(targets)) {
  const bundle = (await api("GET", `/v1/bundleIds?filter[identifier]=${identifier}`)).data
    .find((candidate) => candidate.attributes.identifier === identifier);
  if (!bundle) throw new Error(`No bundle id ${identifier}`);
  for (const old of profiles.filter((profile) => profile.attributes.name === name)) {
    await api("DELETE", `/v1/profiles/${old.id}`);
  }
  const created = (await api("POST", "/v1/profiles", {
    data: {
      type: "profiles",
      attributes: { name, profileType: "IOS_APP_STORE" },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundle.id } },
        certificates: { data: certificates.map(({ id }) => ({ type: "certificates", id })) },
      },
    },
  })).data;
  writeFileSync(`${directory}/${created.attributes.uuid}.mobileprovision`,
                Buffer.from(created.attributes.profileContent, "base64"));
  console.log(`${name}: ${created.attributes.uuid}`);
}
