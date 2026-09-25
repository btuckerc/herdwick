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
  - `mirror(session:)`: a live snapshot stream. Subscribe, then snapshot,
    then a fresh snapshot per event; agent status events are per pane, so a
    changed pane set re-subscribes.
  - `HerdwickSSH`/`SSHConnection`: Apple swift-nio-ssh (not Citadel, which
    depends on a third-party nio-ssh fork). Ed25519 and password auth, `none`
    auth for Tailscale SSH, host-key validation hook for TOFU pinning, exec
    channels with streaming stdio, a handshake timeout, and a keepalive that
    opens and closes a session channel every 15 s and drops the connection
    on a miss. It can adopt an already-connected fd
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

## Remote commands (no server-side install)
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
`connecting`, `live`, `reconnecting(attempt)`, `failed(actionable)`.

- Triggers: scene becomes active, NWPathMonitor path change, a missed
  keepalive probe, or event-stream EOF.
- Foreground backoff: 0.5, 1, 2, 4, then every 8 s. No attempts while
  backgrounded.
- Going to the background: a background task flushes any pending send, then
  the connection closes deliberately. iOS would kill the socket anyway.
- The UI never blanks. The cached snapshot stays visible, dimmed, with
  "Reconnecting…" as the navigation subtitle. The terminal keeps its last frame until the
  fresh `full:true` frame arrives.
- Resync: subscribe to events, then take a snapshot, then apply the buffered
  events (the gap-free order from the herdr docs).
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
  uploads with `ASC_KEY_ID` and `ASC_ISSUER_ID`.
- `scripts/mini/build-tailscalekit.sh` builds `Frameworks/TailscaleKit.xcframework`
  from libtailscale with `GOTOOLCHAIN=go1.25.5`; Go 1.27's json/v2 breaks
  `go-json-experiment` ("undefined: json.SkipFunc").

## Demo host and marketing
- Onboarding offers "Explore a demo host" (the `studio` scenario), so App
  Review and new users can try the app without a machine.
- `-HerdwickDemo`, `-HerdwickScene` and related launch arguments (see
  `App/Demo/DemoDirector.swift`) open a scenario straight to a screen.
  `marketing/capture.sh` uses them to capture every listing scene
  and the App Preview from the simulator, and `marketing/render.sh` composes
  the listing assets. See `marketing/README.md`.
