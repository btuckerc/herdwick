# App Store Connect answers

Everything App Store Connect asks for that isn't a text file in `en-US/`.
`en-US/`, `review_information/`, `*_category.txt` and `copyright.txt` follow fastlane
`deliver` metadata layout, so `fastlane deliver --metadata_path marketing/listing` can upload them.

## Listing

| Field | Value |
|---|---|
| Name | `Herdwick: Agents over SSH` (25/30). herdr is kept out of the name: it's a third-party product, and "SSH" and "Agents" are what people search for. Alternatives: `Herdwick: Coding Agents`, `Herdwick: Remote Agent Inbox` |
| Subtitle | `Remote coding, chat & terminal` (30/30). Alternative: `Answer agents from your phone`. No third-party names here (guideline 2.3.7) |
| Keywords | 100/100 bytes. Don't repeat words already in the name or subtitle (they're indexed); no third-party marks (Claude, Codex, Tailscale, herdr), no `tmux`/`mosh` (not what the app is). Rebalance if the name or subtitle changes |
| Primary / secondary category | Developer Tools / Utilities |
| Price | Free |
| Age rating | Answer Apple's questionnaire; 4+ is the expected result. Unrestricted web access: No (links open outside the app; the only in-app web view is Tailscale sign-in). In the review notes, say agent transcripts are private to the user's machine, not user-to-user chat or shared content |
| Marketing / support / privacy URL | `https://herdwick.app`, `/support`, `/privacy`. The domain must be registered and the pages live before submission |
| Copyright | `2026 Tucker Craig` |
| Price | Free (USD 0.00, all countries). See Pricing below |

## App privacy

**Answer "Yes, we collect data".** Herdwick itself has no analytics, crash reporting or
developer-run servers (no such SDKs in `project.yml` or `Package.swift`), but it embeds
Tailscale's SDK, and Apple counts an SDK's collection as the app's even when the developer
receives nothing. Checked against the shipped revision (libtailscale `59d4bb8`,
tailscale.com v1.94.1):

- `tsnet.Server.startLogger` always starts logtail, uploading the node's logs to
  `log.tailscale.com`. Only `TS_NO_LOGS_NO_SUPPORT` turns this off, and neither
  libtailscale nor the app sets it. The Go runtime reads the environment at load, so
  calling `setenv` from Swift can't set it; libtailscale would need an exported switch.
- The node registers with Tailscale's control server using its node and machine keys,
  its hostname (`herdwick-<random>`), OS and device model, and it is tied to the user's
  Tailscale account.
- Sign-in runs in `SFSafariViewController` (`Onboarding.swift`), which the app cannot
  read. The email and account never pass through the app.

Declare these types. Both are linked to the user, for App Functionality, and not used for tracking:

| Type | Why |
| --- | --- |
| Identifiers › Device ID | Tailscale node and machine keys, registered with its control server |
| Diagnostics › Other Diagnostic Data | tsnet log upload to `log.tailscale.com` |

Don't declare Email Address or User ID: the app never sends either. Also not collected:
SSH traffic, transcripts, terminal output and photo attachments. These go only to the
user's own machine, which the developer doesn't control. Keys and passwords stay in the
Keychain.

If log upload is later disabled (an exported libtailscale call to
`envknob.SetNoLogsNoSupport()` before the node starts), drop Diagnostics.

The privacy policy at `/privacy` must say the same. It must name Tailscale as the
third party for the optional Tailscale connection: node identity, device and connection
metadata, and diagnostic logs, under Tailscale's own privacy policy. It must also say
that nothing else leaves the device except the user's SSH connection to their own machine.

Notifications are opt-in. Local alerts are posted while the app is open or during background
refresh (`App/Model/Attention.swift`). Alerts While Away, a second opt-in, has the user's own
machine send the device's push token and opaque ids (host UUID, session, pane, state) to the
push relay (`relay/`, a Cloudflare Worker), which forwards them to APNs in real time and stores
and logs nothing. Apple's definition excludes data processed only in real time and not
retained, so there is nothing to declare for it. The privacy policy must still describe it.

## Pricing

Free for 1.0. Two advisers split on this. The growth case wins for a first release:

- Buyers must already have iOS 26, run herdr and trust SSH to their own machine.
  A price adds a barrier before the first connection proves the app works.
- Paying needs the Paid Apps Agreement, banking and tax set up.
- At 15% commission, 100 sales at $9.99 is about $850: maintenance money, not income.

Keep "free" out of promises ("free forever"). If revenue matters later, add an optional
tip-jar IAP in 1.1 rather than gating existing features. The alternative was $9.99 one-time.
Going from free to paid after launch forfeits the launch installs and upsets early users.
If you choose paid, change the "free" wording in the description, promotional text and
`launch.md` to "One-time purchase. No subscription. No Herdwick account."

## Trademarks

- herdr: in the description and promotional text as a compatibility statement, lowercase,
  never "official". Not in the name, subtitle or keywords. No herdr logo or wordmark art.
- Tailscale: descriptive plain text only ("Tailscale built in", "Tailscale SSH"). No logo,
  badge, brand colour or "Powered by". libtailscale's BSD-3-Clause §3 forbids using the name
  to endorse or promote without permission.
- Agent names (omp, Claude Code, Codex) appear in the description as compatibility, and
  inside captures as user content, never in overlays, keywords or the subtitle.
- The description ends with the non-affiliation line and "Tailscale is a registered
  trademark of Tailscale Inc."

## Screenshots and previews

Rendered by `marketing/render.sh` into `marketing/build/out/appstore/en-US/`:
`iphone-69/` (1320×2868) and `ipad-13/` (2064×2752) stills, plus `preview.mp4` for each
(886×1920 and 1200×1600, 30 fps H.264, stereo AAC). Upload stills in file-name order. The
iPhone preview's poster frame is at 5 s.
