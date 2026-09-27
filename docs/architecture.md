# Herdwick architecture

Decisions as of 2026-09-24. The evidence behind them is in
`research-2026-09-24.md`.

## Targets
- iOS 26.0 minimum (Liquid Glass is native from 26), built with the iOS 27 SDK
  (Xcode 27.0, Swift 6.4, strict concurrency). iPhone first; iPad adaptive
  layout.
- Bundle ID `dev.btuckerc.herdwick`, team `7F3KV9WTNW`.
- The Xcode project is generated from `project.yml` (XcodeGen), so every
  source file stays editable and reviewable from nous.
- Extensions share the App Group `group.dev.btuckerc.herdwick`: `HerdwickNotifications`
  (service), `HerdwickWidgets` (widgets and the pinned-run Live Activity) and
  `HerdwickShare` (share extension; `dev.btuckerc.herdwick.share`). The share extension
  previews the item and offers "Decide in Herdwick" or an agent from the `AttentionSnapshot`
  (items carry the conversation's `DraftStore` id when it has a transcript session), then
  writes one complete-protection package (text and up to four images, 20 MB, no provider
  URLs, the chosen agent as a hint) to `Imports/`. It can't open the app. The app never
  presents shares on its own: `SharedInbox` lists them behind the Inbox's "Shared" row, where
  the user picks the suggested agent, another live one or New Agent…. The package records
  that conversation's draft as `staged` (one share per draft); its text joins the draft
  unless the draft already contains it, and opening that conversation any way re-attaches
  its images. Nothing is sent until the user sends; the package is deleted only after a
  send from that conversation succeeds, or by swiping it off the shelf.
- Multiple windows: each window has its own `SceneState` (host, navigation path, sheets,
  import); `SceneCommands` adds ⌘N (New Agent), ⌘F (search), ⌘[ (back) and ⌘R (refresh).
  A regular-width window uses a split view with the inbox as sidebar.

## Modules
- `Packages/HerdwickCore`: plain Swift, builds and tests on Linux and iOS.
  - `HerdrAPI`: Codable models for the herdr JSON API (protocol 22):
    `ping`, `session.snapshot`, `workspace/tab/pane/agent.*`, `pane.send_*`,
    `events.subscribe`, and `terminal.frame`/`terminal.input` for the direct
    terminal stream.
  - `HerdrClient`: speaks NDJSON over any `CommandRunner`, which runs a
    remote command and returns an `ExecChannel` (stdin writes, stdout
    stream). One request per bridge process, as herdr itself does. Every
    remote command is wrapped in `/bin/sh -c` so fish or other login shells
    do not matter. `events()` returns only after `subscription_started`.
    Structural events arrive with underscores (`tab_renamed`) and are mapped to
    `tab.renamed`; agent status events already arrive dotted
    (`pane.agent_status_changed`) and are kept as they are.
  - `mirror(session:)`: a snapshot stream. A `preview` snapshot first, so the
    session shows before the subscription is up; then subscribe, snapshot
    (`live`), and a fresh snapshot after events; events that arrive while a
    snapshot is in flight are taken together, so a burst or a post-suspension
    backlog costs one more snapshot, not one each. Agent status events are per
    pane, so a changed pane set re-subscribes.
  - `HerdwickSSH`/`SSHConnection`: Apple swift-nio-ssh (not Citadel, which
    depends on a third-party nio-ssh fork). Ed25519 and password auth, `none`
    auth for Tailscale SSH, host-key validation hook for TOFU pinning, exec
    channels with streaming stdio, a handshake timeout, and a keepalive that,
    after 60 s without inbound traffic, opens and closes a session channel and
    drops the connection on a miss. It can adopt an already-connected fd
    (`ClientBootstrap.withConnectedSocket`); tests prove this with a
    socketpair, which is what `tailscale_dial` returns.
    Closing stdin after a quick command has already exited is not an error
    (`ChannelError.alreadyClosed`), so its output is kept.
  - `ConnectionSupervisor`: the reconnect state machine (see below).
  - `HerdrDemo`: `DemoHost`, a `CommandRunner` that plays a scripted herdr host
    (`Scenarios/<name>/`: snapshot, `.screen` terminal frames, timeline and
    send triggers; format in `Scenarios/README.md`). It answers the probe,
    `session list`, the bridge methods and terminal sessions, and relays UI
    cues to the app's `DemoDirector`. The app runs unchanged on top of it.
- App target `Herdwick`: SwiftUI with `@Observable` models, Keychain,
  NWPathMonitor, scenePhase, the terminal surface, and TailscaleKit.
- Hosts: every saved host gets its own `HostConnection` (one SSH transport and
  herdr session each); `Route`/`PaneAddress` carry the host profile with the
  pane, so the all-hosts inbox and navigation reach the right connection.
- Widget extension `HerdwickWidgets` (`Widgets/`): reads the `AttentionSnapshot`
  (`Shared/`, compiled into both targets) that the app's `Attention` writes to the
  App Group `group.dev.btuckerc.herdwick`. The app also declares background fetch
  (`dev.btuckerc.herdwick.refresh`) and the `herdwick://` URL scheme.
- Notification service extension `HerdwickNotifications` (`Notifications/`): dresses
  alerts-while-away pushes from `snapshot` data and updates the snapshot and badge. The
  push relay is `relay/` (Cloudflare Worker, deployed with `scripts/mini/deploy-relay.sh`;
  secrets `APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`); the app finds it through the
  `HerdwickPushRelay` Info.plist key.

## Remote commands (no server-side install)
- Alerts while away: `PushWatch` writes `~/.herdwick/<installation>-<host profile>/`
  (`watch.sh`, `push.<session>.env`, `watch.<session>.pid`) and runs the watcher with
  `nohup` only while the app is away; see `design-v2.md` › Attention. Needs `sh`, `curl` and
  `openssl` on the host. Uploads go to `${TMPDIR:-/tmp}/herdwick-<uid>/<session>/` (mode 700)
  and are swept by the chosen retention at the next upload; nothing else is written.
- Discovery: `$SHELL -lc 'command -v herdr'`, then `~/.local/bin/herdr`,
  `/opt/homebrew/bin/herdr`, `/usr/local/bin/herdr`. Cache the path per host.
- API: `herdr --session <s> remote-api-bridge` (probe with `--check`).
- Sessions: `herdr session list --json`.
- Live terminal: read-only `herdr --session <s> terminal session observe
  <pane> --cols C --rows R` at the phone's grid. It does not resize the PTY.
  At fewer rows than the pane it sends only the pane's top rows, which hides the
  prompt, and at fewer columns it cuts wide lines off, so the app observes at
  least the pane's `scroll.viewport_rows` and `pane.layout` width, inside a
  vertical `ScrollView` wrapping a horizontal one (direction-locked), anchored to
  the bottom. The keyboard covers old output rather than changing the grid.
  `observe` ignores stdin in herdr 0.9, so it runs under a wrapper that kills
  it when stdin closes; otherwise dropped connections leak processes.
- Scrollback: `observe` has no scroll, and `pane.scroll` would move the host's
  own view, so earlier output comes from `pane.read --source recent --format ansi`
  (500 lines) minus the visible screen's line count, parsed by `ANSILines` (SGR
  only) and drawn as text above the live terminal. Reloaded on open and whenever
  the user scrolls up from the bottom; full-screen apps have none.
- Typing mode: `terminal session control <pane> --takeover --cols C --rows R`,
  which exits on stdin EOF. It resizes the PTY, and the new size persists
  after exit, so it is opt-in and labelled. The composer (`pane.send_input`)
  and key bar (`pane.send_keys`) never resize.

## Reconnect
One SSH connection per host multiplexes every channel. States: `idle`,
`connecting`, `live`, `resuming` (a live link being checked), `waiting`
(backoff), `offline`, `suspended`, `failed(actionable)`.

- Triggers: scene becomes active, NWPathMonitor path change, a missed
  keepalive probe, or event-stream EOF.
- Foreground backoff: 0.5, 1, 2, 4, then every 8 s. No attempts while
  backgrounded.
- Going to the background: under a UIKit background assertion, push watchers are
  armed over the live links (10 s bound, cut short if iOS takes the time back),
  then every link closes (`suspended`). Nothing stays open while the app is
  suspended: it could not read what a host sends, a host would keep streaming to
  it (herdr's writer blocks on an unread subscriber), and a link that died
  meanwhile would stall the return. Removing a host or session closes its link
  for good.
- Liveness: a quiet link is probed after 60 s without inbound traffic; any
  traffic counts, so a busy link is never probed and an idle one wakes the radio
  once a minute.
- Route changes: a new path strands a direct TCP connection, so it is replaced.
  A tailnet connection rides the in-app node, which moves to the new path
  itself, so it is only checked (`resuming`: one fresh snapshot, 10 s bound;
  still usable meanwhile, replaced if it does not answer).
- Redialling with a snapshot on screen: the mirror subscribes to the panes that
  snapshot shows while it takes the preview, instead of after it; a pane set
  that changed meanwhile falls back to the preview's panes.
- The UI never blanks. The cached snapshot stays visible, dimmed, with
  "Reconnecting…" as the navigation subtitle. The terminal keeps its last frame until the
  fresh `full:true` frame arrives.
- Resync: subscribe to events, then take a snapshot, then apply the buffered
  events (the gap-free order from the herdr docs). The link counts as live only
  from that snapshot; the preview before it only fills the screen.
- Setup latency: the herdr path is cached per host, and the mirror for the likely
  session (the chosen one, else the last one opened) starts alongside
  `session list`, which then confirms it or picks another.
- Configuration errors (auth, host key mismatch, herdr missing) stop retrying
  and show the fix where the user is looking.

## Onboarding
1. Tailscale: embedded TailscaleKit (in-app tsnet node, state in Application
   Support, excluded from backup). Sign in with Tailscale
   (SFSafariViewController on `browseToURL`), pick a machine from
   `statusJSON()` peers, then try Tailscale SSH (`none` auth). If that is
   refused, fall back to a device key. Host keys are checked against the
   peer's `SSH_HostKeys`; direct hosts use trust-on-first-use.
2. Host: host/IP/domain, port and user. Generate an Ed25519 key in the
   Keychain (this device only) and offer a copyable `authorized_keys` line, or
   accept a password.

## Local privacy
- Settings › Privacy enables app lock (device-owner authentication, including passcode)
  on launch and after more than 30 seconds in the background. With it on, every inactive
  scene has an opaque window-level cover, including over sheets (the app switcher shows
  it); with it off there is no cover, so launch and return never flash a lock screen.
- Drafts migrate from `composerDrafts` only after an atomic complete-protection file write
  succeeds. An unreadable store is never overwritten. Private files are excluded from backup.
- Opt-in offline transcripts keep complete raw records in protected Application Support
  files: at most 20 conversations, 4 MiB per conversation (80 MiB raw total plus bounded
  identity/title envelopes), and no more than the requested history window. Replay uses the
  existing parser, displays “Offline copy · <date>”, and must never count as read or enable
  remote actions. Opt-out deletes files; host removal deletes that host's copies.
- Key replacement retains the active private key while a second Keychain identity is pending.
  Users install the new public key, select it for each host's next connection, reconnect,
  then explicitly attest success per host. They can revert a host to the old key while
  pending. Only confirmation for every applicable host permits destructive old-key removal.
  This is manual verification, not an automated installation/test; remote old authorizations
  are left intact for the user to remove afterward.

## UI
Liquid Glass only on the control and navigation layer: toolbars, the composer,
the key bar and ask option buttons; never on status, cards or content, and never
nested. See `design-v2.md` for the inbox, conversation and ask design. Terminal content
stays opaque and themeable. Themes are built-in palettes with separate light
and dark slots; fonts are system monospace faces (SF Mono, Menlo, Courier).
The composer defaults to no autocorrect or autocapitalisation, since shells
need literal text; a setting enables it for prose prompts.

## Terminal renderer
SwiftTerm 1.20 (SwiftPM), chosen over libghostty-spm for maintenance and a
plain UIKit view. herdr sends full frames, so scrollback is off and each
`full:true` frame starts with a clear-screen. Its build plugin needs Xcode's
Metal Toolchain and `-skipPackagePluginValidation`. In typing mode SwiftTerm's
keyboard accessory (sticky ctrl) replaces the key bar.

## Build
- `scripts/mini/sync-and-build.sh` rsyncs to the Mini, runs XcodeGen
  (`project.yml`) and builds for the simulator; `testflight` archives and
  uploads with `ASC_KEY_ID` and `ASC_ISSUER_ID`. Release signs manually with an
  API-made Apple Distribution identity and App Store profiles
  (`scripts/mini/app-store-profiles.mjs`, rerun after adding a target or a
  capability), so no Apple ID has to be signed in to Xcode.
- A new target or capability, in order: register its explicit bundle id in the developer
  portal (Identifiers) with its capabilities; App Groups must also be pointed at
  `group.dev.btuckerc.herdwick` there (Configure), which the App Store Connect API can't do.
  Then add the id and profile name to `app-store-profiles.mjs` and to the `ExportOptions`
  in `sync-and-build.sh`, set `PROVISIONING_PROFILE_SPECIFIER` in `project.yml`, and run
  the profiles script on the Mini. Check a profile's entitlements with
  `security cms -D -i <uuid>.mobileprovision | plutil -extract Entitlements xml1 -o - -`.
- Relay: `scripts/mini/deploy-relay.sh` syncs and runs `wrangler deploy` on the Mini, the
  deploy host (its Cloudflare login and the fallback are described in the script). Deploy
  the relay before an app build that sends a new push kind.
- `scripts/mini/build-tailscalekit.sh` builds `Frameworks/TailscaleKit.xcframework`
  from libtailscale with `GOTOOLCHAIN=go1.25.5`; Go 1.27's json/v2 breaks
  `go-json-experiment` ("undefined: json.SkipFunc").
- App icon: `App/AppIcon.icon` (Icon Composer; flat SVG layers for fleece, face and
  prompt, lit by the system in Default, Dark, Clear and Tinted). Edit it in Icon Composer
  or by hand; `marketing/icon.png` is its Default export (`ictool --export-image`).

## Demo host and marketing
- Onboarding offers "Explore a demo host" (the `studio` scenario), so App
  Review and new users can try the app without a machine.
- `-HerdwickDemo`, `-HerdwickScene` and related launch arguments (see
  `App/Demo/DemoDirector.swift`) open a scenario straight to a screen.
  `marketing/capture.sh` uses them to capture every listing scene
  and the App Preview from the simulator, and `marketing/render.sh` composes
  the listing assets. See `marketing/README.md`.
