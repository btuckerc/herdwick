# Launch copy

Media: `marketing/build/out/social/` (launch videos, OG and X cards) and `press/` (hero,
icon). Regenerate with `marketing/render.sh`.

## Before submission: permission notes

Send both. Don't wait for replies; the listing uses descriptive text only.

**To herdr** (GitHub Discussions or Discord)

> Subject: Herdwick, an iOS client for herdr: naming check
>
> Hi. I'm shipping Herdwick, a free native iPhone and iPad client that runs herdr's own
> commands over SSH (session list, remote-api-bridge, terminal observe/control). No forks,
> nothing installed on the host. I'd like to call it "Herdwick for herdr" on the App Store,
> use "herdr" in the description and say clearly that it's independent and not affiliated.
> No logo use. Is that OK with you, and do you prefer any wording? Happy to send a TestFlight.

**To Tailscale** (press@tailscale.com)

> Subject: Descriptive use of "Tailscale" in an iOS app that embeds libtailscale
>
> Hi. Herdwick is a free iOS client for herdr, a terminal workspace for coding agents. It
> embeds libtailscale so people can sign in to their own tailnet and reach their machines
> over Tailscale SSH. In the App Store description and screenshots I'd say "Tailscale built
> in" and "connect with Tailscale SSH" in plain text, with "Tailscale is a registered
> trademark of Tailscale Inc." and a non-affiliation note. No logo, no badge. Given
> libtailscale's BSD-3 clause 3, I wanted to check that's acceptable.

## X

> Your coding agents keep working after you close the laptop. Now you can answer them.
>
> Herdwick is a native iOS client for herdr: every agent on your machines in one list,
> the blocked one on top, its live terminal, and a composer to reply from the train.
>
> SSH or Tailscale built in. No account.

Attach the 1080×1920 launch video, or screenshots 1 and 3. Put the App Store link in a reply.

## Show HN

Title: `Show HN: Herdwick – iOS client for herdr, answer blocked coding agents anywhere`

> herdr is an open-source terminal workspace that tracks coding agents (Claude Code, Codex,
> opencode) across panes and knows when one is blocked. Herdwick is a native iPhone and
> iPad client for it.
>
> How it works: Herdwick runs herdr's own commands over SSH. `session list --json` finds the
> session, one `remote-api-bridge` per request speaks herdr's NDJSON API, `events.subscribe`
> keeps the agent list live, and `terminal session observe` streams a pane's frames into
> SwiftTerm. Replies go through `pane.send_input`. Tailscale is optional and embedded via
> libtailscale, so there's no VPN profile and no keys to copy.
>
> What it doesn't do: no push notifications yet (it taps you while it's open), and there
> are no servers of mine in the path.
>
> There's a built-in demo host if you want to look around without connecting anything.

## Reddit, herdr Discord

> Built an iOS client for herdr with Tailscale built in. An agent gets blocked, you open
> the pane, read its terminal and answer from the composer. Free, no account. Feedback on
> the key bar especially welcome.

Attach the 20 s preview as a GIF or video.

## Press blurb

> Herdwick is a free, native iPhone and iPad client for herdr, the open-source terminal
> workspace for coding agents. It shows every agent running on a developer's machines,
> puts the blocked one first, shows its live terminal and lets the developer answer from
> anywhere, over SSH or a built-in Tailscale connection. No account, no analytics.
