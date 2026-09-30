<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="">
</p>

<h1 align="center">Herdwick</h1>

<p align="center">
  Coding agents on your phone.<br>
  A native iPhone and iPad client for <a href="https://herdr.dev">herdr</a>.
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6815920496"><img src="docs/images/app-store-badge.svg" height="48" alt="Download on the App Store"></a>
</p>

<p align="center">
  <img src="docs/images/screenshots-iphone.webp" alt="Herdwick on iPhone: the agent inbox, answering a question, steps, diffs, what's new, machines and the live terminal">
</p>

herdr is the terminal workspace your coding agents run in. Herdwick connects to
your own machine over SSH, shows every agent herdr tracks, and lets you read and
answer them as conversations, or drop into the live terminal.

- Inbox of agents across all your hosts, with the ones that need you first.
- Transcripts from omp, Claude Code and Codex rendered as chat, including
  subagents, tool steps, plans and diffs.
- Answer questions and permission prompts with native controls.
- Live terminal (SwiftTerm), a key bar and an opt-in typing mode.
- Start an agent in two taps in any workspace or folder on the host, or in an empty pane; attach files.
- Plain SSH (device key or password) or an embedded Tailscale node.
- No account, no analytics, nothing installed on your machine.

On iPad the inbox and the conversation sit side by side.

<p align="center">
  <img src="docs/images/screenshots-ipad.webp" alt="Herdwick on iPad">
</p>

[Support](https://btuckerc.dev/herdwick/support) ·
[Privacy](https://btuckerc.dev/privacy/herdwick)

## Requirements

- iOS 26 or later.
- To build: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Go
  (for TailscaleKit); Linux core builds use [mise](https://mise.jdx.dev).
- A Mac or Linux host running herdr, reachable over SSH.

## Build

```sh
scripts/mini/build-tailscalekit.sh   # builds Frameworks/TailscaleKit.xcframework
xcodegen generate
open Herdwick.xcodeproj
```

Set your own team and bundle ID in `project.yml` before building for a device.

The core package (herdr API, SSH, transcript parsing) builds and tests on
macOS and Linux:

```sh
cd Packages/HerdwickCore
swift test
```

See [docs/architecture.md](docs/architecture.md) and
[docs/design-v2.md](docs/design-v2.md) for how it works. The screenshots come
from the app's demo mode; [marketing/README.md](marketing/README.md) covers how
they're captured and rendered.

## License

[MIT](LICENSE). Herdwick is an independent project, not affiliated with herdr
or Tailscale Inc.
