# App Store Connect answers

Everything App Store Connect asks for that isn't a text file in `en-US/`.
`en-US/`, `review_information/`, `*_category.txt` and `copyright.txt` follow fastlane
`deliver` metadata layout, so `fastlane deliver --metadata_path marketing/listing` can upload them.

## Listing

| Field | Value |
|---|---|
| Name | `Herdwick for herdr` (18/30). Fallback if review objects: `Herdwick` |
| Subtitle | `Coding agents, from anywhere` (28/30). No third-party names here (guideline 2.3.7) |
| Primary / secondary category | Developer Tools / Utilities |
| Price | Free |
| Age rating | 4+. Every content question "None"; unrestricted web access: No (the only web view is Tailscale's own sign-in page) |
| Marketing / support / privacy URL | `https://herdwick.app`, `/support`, `/privacy`. The domain must be registered and the pages live before submission |
| Copyright | `2026 btuckerc`. Replace with the legal name the developer account uses |

## App privacy

**Data Not Collected.** Herdwick has no analytics, crash reporting or developer-run servers.
SSH traffic goes to the user's own machine. The optional Tailscale sign-in creates a node in
the user's own tailnet under Tailscale's terms; the developer receives nothing.

Decision for the account holder: Apple treats third-party SDKs as partners. If you'd rather
declare the Tailscale sign-in, choose Contact Info › Email Address and Identifiers › User ID
and Device ID, used for App Functionality, linked to the user, not used for tracking.
Heeler for herdr ships as Data Not Collected.

## Trademarks

- herdr: in the name and the description as a compatibility statement, lowercase, never
  first, never "official". No herdr logo or wordmark art.
- Tailscale: descriptive plain text only ("Tailscale built in", "Tailscale SSH"). No logo,
  badge, brand colour or "Powered by". libtailscale's BSD-3-Clause §3 forbids using the name
  to endorse or promote without permission.
- Agent names (Claude Code, Codex, opencode) appear in the description as compatibility,
  and inside terminal captures as user content, never in overlays, keywords or the subtitle.
- The description ends with the non-affiliation line and "Tailscale is a registered
  trademark of Tailscale Inc."

## Screenshots and previews

Rendered by `marketing/render.sh` into `marketing/build/out/appstore/en-US/`:
`iphone-69/` (1320×2868) and `ipad-13/` (2064×2752) stills, plus `preview.mp4` for each
(886×1920 and 1200×1600, 30 fps H.264, stereo AAC). Upload stills in file-name order. The
iPhone preview's poster frame is at 5 s.
