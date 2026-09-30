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
> nothing installed on the host. The App Store name is "Herdwick: Agents over SSH"; I'd
> use "herdr" in the description as a compatibility statement and say clearly that it's
> independent and not affiliated.
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

> Answer your coding agents from your phone. Herdwick is a free iPhone and iPad app for
> herdr on your own Mac or Linux machines.
>
> Read conversations, review diffs and use the live terminal. Connect over SSH or sign in
> with Tailscale. No account.

Attach the 1080×1920 launch video, or screenshots 1 and 3. Put the App Store link in a reply.

## Show HN

Title: `Show HN: Herdwick – an iOS client for herdr to answer your coding agents`

> herdr is an open-source terminal workspace that tracks coding agents (Claude Code, Codex,
> opencode) across panes and knows when one is blocked. Herdwick is a native iPhone and
> iPad client for it.
>
> How it works: Herdwick runs herdr's own commands over SSH. `session list --json` finds the
> session, one `remote-api-bridge` per request speaks herdr's NDJSON API, `events.subscribe`
> keeps the inbox live, and `terminal session observe` streams a pane's frames into
> SwiftTerm. For omp, Claude Code and Codex it tails the agent's transcript over the same
> SSH connection and renders it as a conversation; other agents open in the terminal.
> Replies go through `pane.send_input`. Tailscale is optional and embedded via
> libtailscale, so there's no VPN profile and no keys to copy.
>
> Notifications are local by default, posted while it's open or when iOS grants a
> background refresh, so they can be late. For on-time alerts, opt in to Alerts While Away:
> your machine sends only ids through a small stateless relay (source in the repo) to Apple's
> push service. Nothing else of mine is in the path.
>
> There's a built-in demo host if you want to look around without connecting anything.

## Reddit, herdr Discord

> I built an iOS client for herdr, with Tailscale built in. When an agent is waiting on you,
> open its conversation, see what it did and answer it there. The live terminal is always
> there too. Free, no account. Feedback welcome.

Attach the 20 s preview as a GIF or video.

## Press blurb

> Herdwick is a free iPhone and iPad app for herdr, the open-source terminal workspace for
> coding agents. It shows the agents on your own Mac or Linux machines, the ones waiting on
> you first. Read their conversations, review diffs and answer them. Connect over SSH or
> sign in with Tailscale. No account, no analytics.
