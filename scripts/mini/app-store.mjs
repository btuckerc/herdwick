// Publishes Herdwick's App Store listing and releases through the App Store Connect API.
// Run on the Mini (scripts/mini/app-store.sh runs it from nous):
//   node scripts/mini/app-store.mjs status    # version, build, review and media state
//   node scripts/mini/app-store.mjs metadata  # text, categories, age rating, price, availability, review info
//   node scripts/mini/app-store.mjs media     # screenshots and previews from marketing/build/out
//   node scripts/mini/app-store.mjs submit    # attach the newest processed build of this version, submit
// The version is MARKETING_VERSION in project.yml; the text is marketing/listing (fastlane deliver
// layout). Review contact details live only on the Mini, in ~/.herdwick-signing/review.env
// (REVIEW_FIRST_NAME, REVIEW_LAST_NAME, REVIEW_PHONE, REVIEW_EMAIL; mode 600).
// App Privacy isn't in the API: scripts/mini/app-privacy.sh uploads it with an Apple ID session.
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { api, find } from "./asc.mjs";

const root = new URL("../..", import.meta.url).pathname;
const listing = join(root, "marketing/listing");
const media = join(root, "marketing/build/out/appstore/en-US");
const bundleId = "dev.btuckerc.herdwick";
const locale = "en-US";
/** Everywhere but mainland China, which needs an ICP filing. */
const excludedTerritories = new Set(["CHN"]);
const displays = [
  { folder: "iphone-69", screenshots: "APP_IPHONE_67", preview: "IPHONE_67" },
  { folder: "ipad-13", screenshots: "APP_IPAD_PRO_3GEN_129", preview: "IPAD_PRO_3GEN_129" },
];
const posterFrame = "00:00:05:00";
const editable = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"];

const text = (path) => existsSync(join(listing, path)) ? readFileSync(join(listing, path), "utf8").trim() : null;
const version = readFileSync(join(root, "project.yml"), "utf8").match(/MARKETING_VERSION:\s*"?([\d.]+)"?/)[1];
const ref = (type, id) => ({ data: { type, id } });
const log = (...parts) => console.log(...parts);

const app = (await api("GET", `/v1/apps?filter[bundleId]=${bundleId}`)).data.find((a) => a.attributes.bundleId === bundleId);
if (!app) throw new Error(`No app ${bundleId}`);

async function versions() {
  return (await api("GET", `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS&limit=50`)).data;
}

/** The version being prepared, renamed or created to match project.yml. */
async function editableVersion() {
  const all = await versions();
  const current = all.find((v) => editable.includes(v.attributes.appStoreState));
  if (current) {
    if (current.attributes.versionString !== version) {
      await api("PATCH", `/v1/appStoreVersions/${current.id}`, { data: { type: "appStoreVersions", id: current.id, attributes: { versionString: version } } });
      log(`version ${current.attributes.versionString} → ${version}`);
    }
    return { ...current, released: all.some((v) => v.attributes.appStoreState === "READY_FOR_SALE") };
  }
  if (all.some((v) => v.attributes.versionString === version)) throw new Error(`${version} is past editing; raise MARKETING_VERSION`);
  const created = (await api("POST", "/v1/appStoreVersions", { data: {
    type: "appStoreVersions", attributes: { platform: "IOS", versionString: version, releaseType: "AFTER_APPROVAL" },
    relationships: { app: ref("apps", app.id) } } })).data;
  log(`created version ${version}`);
  return { ...created, released: true };
}

async function editableAppInfo() {
  const infos = (await api("GET", `/v1/apps/${app.id}/appInfos`)).data;
  return infos.find((i) => (i.attributes.state ?? i.attributes.appStoreState) !== "READY_FOR_DISTRIBUTION"
    && i.attributes.appStoreState !== "READY_FOR_SALE") ?? infos[0];
}

async function localization(path, type, parent) {
  const existing = (await api("GET", path)).data.find((l) => l.attributes.locale === locale);
  if (existing) return existing;
  return (await api("POST", `/v1/${type}`, { data: { type, attributes: { locale }, relationships: parent } })).data;
}

function reviewContact() {
  const file = `${homedir()}/.herdwick-signing/review.env`;
  if (!existsSync(file)) throw new Error(`Missing ${file}`);
  const env = Object.fromEntries(readFileSync(file, "utf8").split("\n").filter((l) => l.includes("=")).map((l) => l.split("=", 2)));
  return { contactFirstName: env.REVIEW_FIRST_NAME, contactLastName: env.REVIEW_LAST_NAME,
           contactPhone: env.REVIEW_PHONE, contactEmail: env.REVIEW_EMAIL };
}

async function metadata() {
  const v = await editableVersion();
  await api("PATCH", `/v1/appStoreVersions/${v.id}`, { data: { type: "appStoreVersions", id: v.id,
    attributes: { copyright: text("copyright.txt"), releaseType: "AFTER_APPROVAL" } } });

  const vl = await localization(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations`, "appStoreVersionLocalizations",
    { appStoreVersion: ref("appStoreVersions", v.id) });
  await api("PATCH", `/v1/appStoreVersionLocalizations/${vl.id}`, { data: { type: "appStoreVersionLocalizations", id: vl.id, attributes: {
    description: text(`${locale}/description.txt`), keywords: text(`${locale}/keywords.txt`),
    promotionalText: text(`${locale}/promotional_text.txt`), supportUrl: text(`${locale}/support_url.txt`),
    marketingUrl: text(`${locale}/marketing_url.txt`),
    // "What's New" is refused on an app's first version.
    ...(v.released ? { whatsNew: text(`${locale}/release_notes.txt`) } : {}),
  } } });
  log("version text");

  const info = await editableAppInfo();
  await api("PATCH", `/v1/appInfos/${info.id}`, { data: { type: "appInfos", id: info.id, relationships: {
    primaryCategory: ref("appCategories", text("primary_category.txt")),
    secondaryCategory: ref("appCategories", text("secondary_category.txt")),
  } } });
  const il = await localization(`/v1/appInfos/${info.id}/appInfoLocalizations`, "appInfoLocalizations", { appInfo: ref("appInfos", info.id) });
  await api("PATCH", `/v1/appInfoLocalizations/${il.id}`, { data: { type: "appInfoLocalizations", id: il.id, attributes: {
    name: text(`${locale}/name.txt`), subtitle: text(`${locale}/subtitle.txt`), privacyPolicyUrl: text(`${locale}/privacy_url.txt`),
  } } });
  log("name, subtitle, categories");

  const rating = (await api("GET", `/v1/appInfos/${info.id}/ageRatingDeclaration`)).data;
  await api("PATCH", `/v1/ageRatingDeclarations/${rating.id}`, { data: { type: "ageRatingDeclarations", id: rating.id,
    attributes: JSON.parse(text("age_rating.json")) } });
  log("age rating");

  await api("PATCH", `/v1/apps/${app.id}`, { data: { type: "apps", id: app.id, attributes: { contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" } } });

  const detail = (await api("GET", `/v1/appStoreVersions/${v.id}/appStoreReviewDetail`)).data;
  const review = { ...reviewContact(), demoAccountRequired: false, notes: text("review_information/notes.txt") };
  if (detail) await api("PATCH", `/v1/appStoreReviewDetails/${detail.id}`, { data: { type: "appStoreReviewDetails", id: detail.id, attributes: review } });
  else await api("POST", "/v1/appStoreReviewDetails", { data: { type: "appStoreReviewDetails", attributes: review,
    relationships: { appStoreVersion: ref("appStoreVersions", v.id) } } });
  log("review information");

  await price();
  await availability();
}

/** Free, set once. */
async function price() {
  const manual = await find(`/v1/appPriceSchedules/${app.id}/manualPrices?limit=1`);
  if (manual?.data?.length) return log("price already set");
  let free, next = `/v1/apps/${app.id}/appPricePoints?filter[territory]=USA&limit=200`;
  while (!free && next) {
    const page = await api("GET", next.replace("https://api.appstoreconnect.apple.com", ""));
    free = page.data.find((p) => Number(p.attributes.customerPrice) === 0);
    next = page.links?.next;
  }
  if (!free) throw new Error("No free price point");
  await api("POST", "/v1/appPriceSchedules", {
    data: { type: "appPriceSchedules", relationships: {
      app: ref("apps", app.id), baseTerritory: ref("territories", "USA"),
      manualPrices: { data: [{ type: "appPrices", id: "${free}" }] } } },
    included: [{ type: "appPrices", id: "${free}", attributes: { startDate: null },
      relationships: { appPricePoint: ref("appPricePoints", free.id) } }],
  });
  log("price: free");
}

/** Every territory but the excluded ones, and new ones as they open; set once. */
async function availability() {
  if (await find(`/v1/apps/${app.id}/appAvailabilityV2`)) return log("availability already set");
  // Apple wants every territory named; the excluded ones as unavailable.
  const territories = (await api("GET", "/v1/territories?limit=200")).data.map((t) => t.id);
  await api("POST", "/v2/appAvailabilities", {
    data: { type: "appAvailabilities", attributes: { availableInNewTerritories: true }, relationships: {
      app: ref("apps", app.id),
      territoryAvailabilities: { data: territories.map((id) => ({ type: "territoryAvailabilities", id: `\${${id}}` })) } } },
    included: territories.map((id) => ({ type: "territoryAvailabilities", id: `\${${id}}`,
      attributes: { available: !excludedTerritories.has(id) }, relationships: { territory: ref("territories", id) } })),
  });
  log(`availability: ${territories.length - excludedTerritories.size} of ${territories.length} territories`);
}

async function upload(kind, parent, file, extra = {}) {
  const bytes = readFileSync(file);
  const name = file.split("/").pop();
  const created = (await api("POST", `/v1/${kind}`, { data: { type: kind,
    attributes: { fileName: name, fileSize: bytes.length, ...extra }, relationships: parent } })).data;
  for (const op of created.attributes.uploadOperations) {
    const response = await fetch(op.url, { method: op.method, body: bytes.subarray(op.offset, op.offset + op.length),
      headers: Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value])) });
    if (!response.ok) throw new Error(`upload ${name}: ${response.status}`);
  }
  await api("PATCH", `/v1/${kind}/${created.id}`, { data: { type: kind, id: created.id, attributes: {
    uploaded: true, sourceFileChecksum: createHash("md5").update(bytes).digest("hex"),
    ...(kind === "appPreviews" ? { previewFrameTimeCode: posterFrame } : {}) } } });
  return created.id;
}

/** Replaces a set's assets when the local files (names and bytes, in order) differ. */
async function syncSet(setType, setKind, assetKind, locId, displayType, files, extra) {
  const typeKey = setKind === "appScreenshotSets" ? "screenshotDisplayType" : "previewType";
  const sets = (await api("GET", `/v1/appStoreVersionLocalizations/${locId}/${setKind}?limit=50`)).data;
  let set = sets.find((s) => s.attributes[typeKey] === displayType);
  if (!set) set = (await api("POST", `/v1/${setKind}`, { data: { type: setKind, attributes: { [typeKey]: displayType },
    relationships: { appStoreVersionLocalization: ref("appStoreVersionLocalizations", locId) } } })).data;
  const remote = (await api("GET", `/v1/${setKind}/${set.id}/${assetKind}?limit=50`)).data;
  const want = files.map((f) => [f.split("/").pop(), createHash("md5").update(readFileSync(f)).digest("hex")]);
  const have = remote.map((a) => [a.attributes.fileName, a.attributes.sourceFileChecksum]);
  if (JSON.stringify(want) === JSON.stringify(have)) return log(`${displayType} ${assetKind}: up to date`);
  for (const asset of remote) await api("DELETE", `/v1/${assetKind}/${asset.id}`);
  const ids = [];
  for (const file of files) ids.push(await upload(assetKind, { [setType]: ref(setKind, set.id) }, file, extra));
  log(`${displayType} ${assetKind}: uploaded ${files.length}`);
  return ids;
}

async function mediaSync() {
  const v = await editableVersion();
  const vl = await localization(`/v1/appStoreVersions/${v.id}/appStoreVersionLocalizations`, "appStoreVersionLocalizations",
    { appStoreVersion: ref("appStoreVersions", v.id) });
  const pending = [];
  for (const d of displays) {
    const folder = join(media, d.folder);
    const stills = readdirSync(folder).filter((f) => /^\d\d-.*\.png$/.test(f)).sort().map((f) => join(folder, f));
    pending.push(...(await syncSet("appScreenshotSet", "appScreenshotSets", "appScreenshots", vl.id, d.screenshots, stills) ?? [])
      .map((id) => ["appScreenshots", id]));
    const preview = join(folder, "preview.mp4");
    if (existsSync(preview)) {
      pending.push(...(await syncSet("appPreviewSet", "appPreviewSets", "appPreviews", vl.id, d.preview, [preview], { mimeType: "video/mp4" }) ?? [])
        .map((id) => ["appPreviews", id]));
    }
  }
  // Apple processes uploads in the background; wait for its verdict (videos take minutes).
  const deadline = Date.now() + 15 * 60_000;
  while (pending.length && Date.now() < deadline) {
    for (let i = pending.length - 1; i >= 0; i--) {
      const [kind, id] = pending[i];
      const state = (await api("GET", `/v1/${kind}/${id}`)).data.attributes.assetDeliveryState;
      if (state.state === "COMPLETE") pending.splice(i, 1);
      else if (state.state === "FAILED") throw new Error(`${kind} ${id} failed: ${JSON.stringify(state.errors)}`);
    }
    if (pending.length) await new Promise((r) => setTimeout(r, 10_000));
  }
  if (pending.length) throw new Error(`${pending.length} uploads still processing after 15 min; run media again to check`);
  log("media processed");
}

async function submit() {
  const v = await editableVersion();
  const build = (await api("GET", `/v1/builds?filter[app]=${app.id}&filter[preReleaseVersion.version]=${version}`
    + "&filter[processingState]=VALID&filter[expired]=false&sort=-uploadedDate&limit=1")).data[0];
  if (!build) throw new Error(`No processed build of ${version}; run sync-and-build.sh testflight first`);
  await api("PATCH", `/v1/appStoreVersions/${v.id}/relationships/build`, ref("builds", build.id));
  log(`build ${build.attributes.version} attached to ${version}`);
  const open = (await api("GET", `/v1/reviewSubmissions?filter[app]=${app.id}&filter[platform]=IOS`
    + "&filter[state]=READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES")).data;
  if (open.some((s) => s.attributes.state !== "READY_FOR_REVIEW")) {
    throw new Error(`A submission is already ${open.map((s) => s.attributes.state).join(", ")}`);
  }
  const submission = open[0] ?? (await api("POST", "/v1/reviewSubmissions", { data: { type: "reviewSubmissions",
    attributes: { platform: "IOS" }, relationships: { app: ref("apps", app.id) } } })).data;
  const items = (await api("GET", `/v1/reviewSubmissions/${submission.id}/items`)).data;
  if (!items.length) await api("POST", "/v1/reviewSubmissionItems", { data: { type: "reviewSubmissionItems", relationships: {
    reviewSubmission: ref("reviewSubmissions", submission.id), appStoreVersion: ref("appStoreVersions", v.id) } } });
  await api("PATCH", `/v1/reviewSubmissions/${submission.id}`, { data: { type: "reviewSubmissions", id: submission.id, attributes: { submitted: true } } });
  log(`${version} submitted for review; it releases on approval`);
}

async function status() {
  for (const v of (await versions()).slice(0, 3)) {
    const build = (await api("GET", `/v1/appStoreVersions/${v.id}/build`)).data;
    log(`${v.attributes.versionString}: ${v.attributes.appStoreState}, build ${build?.attributes.version ?? "none"}, ${v.attributes.releaseType}`);
  }
  const submissions = (await api("GET", `/v1/reviewSubmissions?filter[app]=${app.id}&limit=3`)).data;
  for (const s of submissions) log(`review submission ${s.attributes.submittedDate ?? "draft"}: ${s.attributes.state}`);
  const info = await editableAppInfo();
  log(`age rating ${info.attributes.appStoreAgeRating ?? "unset"}; price ${(await find(`/v1/appPriceSchedules/${app.id}/manualPrices?limit=1`))?.data?.length ? "set" : "unset"}; availability ${await find(`/v1/apps/${app.id}/appAvailabilityV2`) ? "set" : "unset"}`);
}

const commands = { status, metadata, media: mediaSync, submit };
const command = commands[process.argv[2]];
if (!command) { console.error(`usage: app-store.mjs ${Object.keys(commands).join("|")}`); process.exit(2); }
await command();
