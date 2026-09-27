# Herdwick

- Core package: `cd Packages/HerdwickCore && mise exec -- swift test`. Live suites are opt-in:
  `HERDWICK_LIVE=1` (local herdr; read-only on session `main`, writes only in throwaway
  `herdwick-test-*` sessions) and `HERDWICK_SSH_LIVE=1` (private unprivileged sshd on 127.0.0.1).
- Never write to the user's real herdr session `main`.
- The iOS app builds only on the Mac Mini (`ssh mini`, Xcode on `/Volumes/E0/Developer`); Linux builds the core package only.
  `scripts/mini/sync-and-build.sh` (rsync + XcodeGen + simulator build); add `testflight` to upload
  (App Store Connect key IDs come from the Mini's `~/.herdwick-signing/asc.env` unless `ASC_KEY_ID`/`ASC_ISSUER_ID` are set).
  It prints "Uploaded build N" and exits; wait on that command itself. Never block on remote polling
  loops (`ssh mini 'while pgrep …'`): they outlive the build and hang the session.
- Simulator UI checks: `axe` on the Mini (coordinate taps; `--label` taps time out).
- New target or capability (extension, App Group, …): register the bundle id and assign the App
  Group in the developer portal first (the API can't), then `scripts/mini/app-store-profiles.mjs`
  on the Mini; see `docs/architecture.md` › Build.
- Relay: `scripts/mini/deploy-relay.sh` (runs `wrangler deploy` on the Mini with its stored
  Cloudflare login). Never deploy from a laptop copy; the Mini's login is the canonical one.
- Demo in the simulator: `xcrun simctl terminate <udid> dev.btuckerc.herdwick`, then
  `xcrun simctl launch <udid> dev.btuckerc.herdwick -HerdwickDemo studio` (screen points =
  screenshot pixels ÷ 3 on iPhone, ÷ 2 on iPad). Check iPad (split view) too for navigation changes.
- Swift 6 build errors seen here: a long SwiftUI modifier chain or `switch` in a `.sheet` times
  out the type checker (split into a `@ViewBuilder` func); ActivityKit `Activity` isn't Sendable
  (look it up by id instead of holding it across `await`); AppIntent statics must be `let`.
- The MacBook (`ssh mac`) is driven via the Peekaboo bridge (mcp `mac`); if it reports
  `bridge.sock is unavailable`, UI automation there is off and the user must act.
