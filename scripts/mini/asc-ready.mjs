// Checks App Store Connect accepts the API key before an archive, so an expired developer
// agreement fails in seconds instead of after the archive. When Apple has posted an agreement
// the Account Holder must accept, says where, then waits for it (every 30 s, up to
// ASC_AGREEMENT_WAIT minutes, default 30) so the upload goes on once it is accepted.
import { api } from "./asc.mjs";

const limit = Date.now() + Number(process.env.ASC_AGREEMENT_WAIT ?? 30) * 60_000;
let told = false;
for (;;) {
  try {
    await api("GET", "/v1/apps?filter[bundleId]=dev.btuckerc.herdwick&limit=1");
    if (told) console.log("Agreement in effect; continuing.");
    process.exit(0);
  } catch (error) {
    if (error.status !== 403 || !/agreement/i.test(error.message)) throw error;
    if (!told) {
      console.log("App Store Connect: a developer agreement needs the Account Holder's acceptance.");
      console.log("Accept it at https://developer.apple.com/account (banner at the top); waiting for it to take effect…");
      told = true;
    }
    if (Date.now() > limit) {
      console.error("Still no agreement in effect; giving up.");
      process.exit(1);
    }
    await new Promise((resolve) => setTimeout(resolve, 30_000));
  }
}
