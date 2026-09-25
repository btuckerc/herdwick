# Herdwick v2 design

Synthesised 2026-09-25 from a council (Fable A, Fable B, Astra review) over a verified
protocol map. Status: phases 1–5 built (see Phases).

## Mental model: agents are conversations
One screen answers "who needs me, what do they want, answer it".

| herdr | Herdwick |
|---|---|
| host + herdr session | the account: the inbox title (tap for the host list, swipe between hosts) |
| agent (pane with a detected agent) | a conversation |
| workspace | caption on the conversation (label, branch) |
| tab, pane, split, layout | hidden; shells (`unknown`) sit in a collapsed "Terminals" section |
| `agent_status` | blocked → pinned "Needs you"; a finish not yet read here → "Done" with an unread dot; working → typing dots; idle or a read finish → "Idle" |

Order: blocked agents pinned in a "Needs You" section, everything else by `state_change_seq`
descending (most recent change first, like a messages list).

## Screens (4)
1. **Inbox** (`SessionView`): `List`, inline title. The principal `HostTitle` shows host name
   over address (or connection state) as one control, no chevron: tap opens the Hosts sheet
   (All Hosts as an exclusive choice, hosts in the user's order with Edit/drag to reorder,
   Add Host, the host's herdr sessions, Edit host). Swipe it to move to the previous/next
   host (push transition); their names peek dimmed at the edges. In All Hosts the title reads
   "All Hosts · N hosts" and doesn't swipe. `.toolbarTitleMenu` was dropped because its label
   flies away while the menu is open. Trailing toolbar button: Settings. Bottom bar: View
   options at the leading edge (one menu with titled View, Group and Sort sections; Group and
   Sort only for Agents) and "+" (New Agent/Workspace) at the trailing edge. Row: status
   glyph, conversation title (terminal title minus the agent glyph prefix),
   "status · workspace", unread dot. Agents with a transcript open the conversation; others
   open the terminal. No per-row preview: that would need a transcript read per agent.
2. **Conversation**: transcript rendered as chat; pending ask as native cards above the
   composer; composer (`pane.send_input`, text + `enter`). Title = transcript title or agent,
   subtitle = status text in colour + workspace. One toolbar button: Terminal.
3. **Terminal**: existing SwiftTerm surface pushed from the conversation or a shell row; observe
   by default, typing mode (takeover) opt-in. The fallback for anything we can't structure.
   Reading scrolls like a document without touching the host's pane: vertically into earlier
   output (`pane.read recent`, ANSI colours, loaded on open and each time you scroll up into
   it) and sideways when the pane is wider than the phone (observed at its `pane.layout`
   width). Typing mode fits the screen and doesn't scroll.
4. **Settings / hosts** sheet; onboarding is a sheet flow.

Agentless panes keep the terminal and command composer (“Run a command”); Send submits
with Enter, with attachments (including images) pasted as shell-quoted paths. Under the
header, an accent glass-prominent Start control launches OMP, Claude or Codex in that pane.
The kind is remembered per host profile (`lastAgentKind.<profileID>`) and also seeds
the New Agent picker. A foreground non-shell process triggers “Start in New Tab” /
Cancel rather than typing into the busy program; the new tab uses the pane's workspace
and cwd without focusing it, skips the busy check (its shell may still run startup helpers
such as mise), and retries `agent_pane_busy` for up to 5 s until that shell is ready.
If process inspection is unavailable, herdr still validates the start. A started agent's
transcript doesn't exist until its first message, so a missing file reads as empty and the
conversation shows “New conversation” while `tail -F` waits for the file.
The inbox's folded terminals are grouped by workspace with “No agent yet” captions
and a leading Start swipe action; Machines uses the same empty-workspace wording.

Inbox options (Settings, persisted in `UserDefaults`): Agents or Machines (herdr's host ›
workspace › tab › pane tree, with Close Tab/Close Workspace swipes); all hosts or the current
one; grouping None/Host/Workspace/Status, with "Needs You" always pinned first; sort Recent or
Priority (blocked, unread done, working, idle, unknown); collapse idle. Rows swipe leading to
Mark as Read/Unread (full swipe) and Hide/Unhide (local), trailing to Close (confirmed). "+"
opens New Agent/Workspace.
The composer attaches files and images, uploaded to the host and cleaned up after the chosen
retention (1 hour/day/week, default a day). The on-screen Return adds a line unless "On-screen
Return Sends" is on; on a hardware keyboard Return and ⌘↩ send, ⇧↩ or ⌥↩ adds a line.
Conversation detail is Full, Folded (default) or Digest.

Liquid Glass only on: system toolbars (automatic), the composer container, the key bar, ask
option buttons. Never glass inside a toolbar item or inside another glass container. Status is
text/glyphs, never a glass capsule. Remove glass from `StatusBadge`, `ConnectionPill`,
`FailureCard`.

## Conversation source of truth
- herdr's snapshot gives `agents[].agent_session = {source, agent, kind, value}`. omp reports
  `kind:"path"` (`~/.omp/agent/sessions/<slug>/<ts>_<id>.jsonl`); Claude Code and Codex report
  `kind:"id"`, and `HerdrClient.locateTranscript` finds the file with one exec: the agent's
  own `CLAUDE_CONFIG_DIR`/`CODEX_HOME` (from `/proc/<foreground pid>/environ` on Linux), then
  the shell's, then `~/.claude` / `~/.codex`; `projects/*/<id>.jsonl` or
  `sessions/*/*/*/rollout-*-<id>.jsonl`. The app retries 4× (2/4/6 s): a fresh session's file
  can appear after herdr reports the id.
- `TranscriptReader(format:)` adapts each format to the same `TranscriptEntry`s:
  - Claude (`TranscriptClaude`): `user`/`assistant` records, `tool_use`/`tool_result` blocks,
    `toolUseResult` as details; "[Request interrupted by user…" becomes a notice.
    `TaskCreate`/`TaskUpdate` (which replaced `TodoWrite`) fold into one plan: the id comes
    from `toolUseResult.task.id`, and each call carries the board after it.
  - Codex (`TranscriptCodex`): `response_item` message/reasoning/`function_call`/
    `custom_tool_call` and outputs ("Process exited with code N" → exit code, text after
    "Output:"); harness user messages (`<environment_context>` …) hidden; `event_msg` errors
    → notices.
- `ConversationFeed` (app) over `HerdrClient.readFileTail`/`followFile` (HerdwickCore): only the
  open conversation is read. One exec reads the file size and the first 4 KiB (line 1 is a
  padded `title` record rewritten in place, so the title comes from there); then one channel
  runs `tail -c +<offset> -F <path> & …; cat >/dev/null; kill` from the last 256 KiB (partial
  first line dropped). The remote `tail` dies when the channel closes, because the shell is
  waiting on stdin. "Show Earlier Messages" reloads with 4× the window. A dropped channel
  (backgrounding closes the transport) keeps the painted conversation; the view follows again
  on the same transport after 2 s or when the reconnect bumps `liveID`. Only a first read that
  never painted shows "Couldn't read this agent's transcript".
- `TranscriptReader` → `TranscriptEntry` → `Conversation` (HerdwickCore `Transcript.swift`;
  omp shapes below):
  - `message/user` → user bubble; `message/assistant` `text` → agent text (Markdown blocks:
    headings, lists and task lists, quotes, code, tables that scroll sideways; inline via
    `AttributedString`),
    `thinking` and `toolCall`s → one folded "N steps · <last summary>" row; a tool call merges
    with its `toolResult` by `toolCallId` (state, first 200 output lines).
  - `custom/tool_execution_start` → running step (replaced by its call); `compaction`,
    displayed `custom_message`, assistant `errorMessage` → centred notices; `title`,
    `title_change`, `session.title` → title; model/thinking/usage/credential/`session_init`
    records and `developer` messages → hidden.
  - Unknown record types survive as raw rows (a newer omp never silently loses content).
    Checked against all 46 local omp session files: zero raw rows.
  - Rendered in file order; the `parentId` tree is not walked.
- Agents with no known format or no session id/path open the terminal directly; a transcript
  that can't be located says so in the conversation.
- Read state is local (`ReadState` in Core, held by `HostConnection`, persisted per host and
  session). herdr says `done` only while nobody at the desk has looked, and a finish in the
  desk's focused pane goes straight to `idle`, so a finish is `done` or a working agent seen to
  stop. Reading records the `state_change_seq` on screen; the desk acknowledging later bumps
  it without making it unread again. A conversation is read only when the app is active, the
  transcript has loaded and its end is on screen (`onScrollGeometryChange`); new output that
  arrives while you're scrolled back stays unread. A read finish shows as Idle; reading a
  blocked agent drops the dot, never the orange. Agents first seen start read. We never call
  `agent.focus`/tab focus: that would move the user's desk.
- Sending while an omp agent works queues the message as steering: it shows dimmed under the
  conversation, "Queued · Tap to Edit", until the transcript records it. Tapping the newest
  sends omp's Alt+Up (restore the last queued message to its editor), checks omp's editor on
  screen (`OmpEditor`), clears it with Ctrl+C (which leaves the turn running) and puts the
  text back in the composer. If omp took the message first, its editor stays empty and
  nothing is cleared.

## Attention: alerts, badge, widgets
From the councils of 2026-09-25 (`Attention`, `Push`):
- Alerts for Needs You and Finished, each a Settings toggle that asks permission when turned
  on. They fire on a new unread state (one per pane and `state_change_seq`, remembered so a
  reconnect never repeats one), not for the conversation on screen, and are withdrawn once
  the agent is read or answered. Tapping one opens that agent. With Needs You on, the badge
  counts blocked agents across hosts; finished work is not a debt.
- The app only sees hosts while it runs. In the background iOS wakes it now and then
  (`BGAppRefreshTask`, earliest 15 min): it reconnects each link for one snapshot (20 s cap),
  which raises alerts and updates the widgets, then lets go.
- Widgets (`HerdwickWidgets`: Home small and medium, Lock Screen rectangular/circular/inline)
  read an `AttentionSnapshot` the app writes to the App Group: every visible agent as the app
  presents it (needs you, unread done, working, idle; newest change first within each), when
  the app saw that state begin, and whether every host answered. Small shows the three counts
  and the most pressing agent; medium adds the two most pressing agents, each a link, with a
  live "4m ago", and drops to one agent (then counts only) when the widget or text size leaves
  no room, so nothing clips. The app reloads timelines only when that content changes. Widgets say when
  what they show is old or a host was offline and never claim "all clear" then.
  `herdwick://open?host=&session=&pane=` deep-links alerts and widgets.
- Alerts while away (opt-in, Settings › Alerts While Away, with a How It Works page). As the
  app backgrounds it arms a watcher on each live link over the SSH it already holds
  (`PushWatch`, inside a background task) and disarms it when the link next comes up in the
  foreground, including after the app was closed. The watcher is a POSIX `sh` script written
  to `~/.herdwick/` (secrets on stdin into a 0600 file, nothing in the process list): per agent
  one `herdr agent wait` blocked on herdr's socket (measured on herdr 0.9.1: no CPU, no context
  switches in 20 s, ~6 MB), one `agent list` (~20 ms CPU) every 120 s for agents started
  meanwhile, one `curl` per alert, and it exits after 24 h or when herdr stops. No daemon, no
  port, no install. `idle` after `working` counts as done (herdr skips `done` for the pane
  focused at the desk).
- The post carries only the device token and opaque ids (host UUID, session, pane, state,
  seq). The relay (`relay/`, a ~70-line Cloudflare Worker holding the APNs key) validates
  them, rate-limits 20 a minute per device, sends a generic `mutable-content` alert with a
  collapse id per agent, and stores and logs nothing. The notification service
  (`HerdwickNotifications`) fills in the title and place from the snapshot, records the seq in
  the App Group so the app never repeats the alert, moves the agent in the snapshot, sets the
  badge and reloads widgets. A user can't run their own relay for this build: that would mean
  sharing the APNs key. Self-built copies set `HerdwickPushRelay` to their own team's relay.
- Ruled out: CloudKit (web tokens are single-use), Local Push Connectivity (restricted
  entitlement, named Wi-Fi only), Tailscale (the phone's node is down while suspended).
  Not built: a "Watch this run" Live Activity. T3 Code's "settled" shelf was not adopted:
  Hide already parks work and resurfaces it when it needs you.

## Subagent transcript state
Core derives working children from omp `task`, Claude `Agent`/`Task`, and Codex
`spawn_agent` calls. omp async-result notices may complete multiple children; wait
results and notices coalesce into one result per child, with cancellation taking
precedence. Result rows remain in Digest. Claude async launch results replace the
provisional call ID with `agentId`; completed results retain their content. These
Claude result shapes are synthetic fixtures pending a captured real transcript.
Codex close calls cancel the child; Codex transcript drill-in is unavailable.
Child-file reconciliation only transitions working children: session exit completes,
tombstone cancels, missing/active leaves state unchanged. File probes share one exec.

## Ask
Tier A, structured (omp `ask`, Claude `AskUserQuestion`; Codex `request_user_input` is detected
by name but unexercised): a pending ask is a tool call with no result yet.
`arguments.questions[] = {id?, header?, question, options[{label, description}],
multi?|multiSelect?, recommended?}`. `AskPanel` pages the questions ("HEADER · 1 OF 2"):
single-select options answer on tap, and an "Other answer" field takes free text;
multi-select shows checkboxes with Back/Next/Send. Shown above the composer only while
herdr says `blocked`. Answered asks show each question's own answer (`AskAnswer.perQuestion`).

Answer driver (closed loop, `PromptDriver` in HerdwickCore `AskDriver.swift`, injected
`PromptIO`; per-agent key sequences are in its doc comment):
1. `pane.read {source:"visible", format:"text"}` → locate option rows by label (strip
   " (Recommended)") and the cursor row (starts with U+F054).
   Every read must match the question text and the call's option labels, or nothing is sent.
2. One `up`/`down` per `pane.send_keys`, re-reading after each; the cursor must move exactly one
   row or the driver stops before `enter`.
3. `enter`.
4. Confirmed only when the transcript shows the `toolResult` for that `toolCallId` (8 s);
   the card then shows the answer in the history. Any failure → alert with "Open Terminal".

omp key map (from the 18.3.0 bundle): up/down (k/j), pageUp/pageDown, enter confirm, space
toggle (multi), escape/ctrl+c cancel, `n` adds a note; extra row "Other (type your own)".

Verified end to end on 2026-09-25 (throwaway herdr session, omp 18.3.0, Haiku):
- herdr reports omp as `screen_detection_skipped: true` with `agent_session.value` = transcript
  path; status went `working` → `blocked` when the ask rendered.
- `pane.read {source:"visible", format:"text"}` shows the box verbatim; the cursor row starts
  with U+F054 (Nerd Font chevron) before the U+F10C radio glyph; description lines follow
  each option indented. The cursor starts on the **recommended** option.
- One `pane.send_keys ["down"]` moved the cursor Green → Blue; `["enter"]` answered. Within
  3 s the transcript gained `toolResult {toolName:"ask", content "User selected: Blue",
  details:{question, options:["Red","Green","Blue"], multi:false, selectedOptions:["Blue"]}}`
  and herdr went `blocked` → `working`.
- The call: `{"type":"toolCall","id":"toolu_…","name":"ask","arguments":{"questions":[{"id":
  "sheep_colour","header":"Colour","question":"…","options":[{"label":"Red","description":
  "warm"},…],"recommended":1}]}}`.
- Through the app (simulator, same setup): tapping the third option (Corgi) sent
  `down`, `down`, `enter`; the transcript confirmed "Corgi".
Verified end to end 2026-09-25 through the app (simulator → SSH → herdr, scripted model):
omp two questions with "Other" = "Tiny" + multi Sprinkles; Claude two questions Pear + multi
Salad, Soup; both confirmed by the transcript. Core live test: omp custom + multi, Claude
custom + multi.

Tier B, screen prompts (Claude permission, Codex approval): when `blocked` with no pending
ask, the app reads the pane every 2 s; `ScreenPrompt.choice` finds the numbered options and
the title (last "?" line that isn't a `$ ` line or a "Label: " line), with context lines.
`PermissionCard` shows them; a tap runs `PromptDriver.choose` (↑/↓ re-reading after each,
Enter), confirmed by the prompt leaving the screen. Verified in the app: Claude Bash Yes (ran)
and No (rejected, "[Request interrupted…]" notice), Claude Edit Yes (diff in the card), Codex
"Yes, proceed" (ran).

## Onboarding and auth
- Tailnet peers: offer Tailscale SSH only when the peer advertises `sshHostKeys`; otherwise it
  is not shown (the user's host runs no Tailscale SSH server: `RunSSH:false`).
- Both paths offer Password (default unless Tailscale SSH is available) and the manual key.
  `KeySetup` signs in once with the password, shows the host key fingerprint and
  `user@host`, then on "Install this iPhone's key" runs `AuthorizedKeyInstall` (strictly
  validated key line, refuses a symlinked `authorized_keys`, modes 700/600, idempotent) over
  that connection, re-dials with the key against the same host key, pins it, saves the host as
  device-key auth and drops the password. "Keep using password" stores it in the Keychain.
  The password field is cleared once `KeySetup` has it, so iOS doesn't offer to save it.
  Verified 2026-09-25 (simulator → asyncssh server on the tailnet): password sign-in, key
  installed into `authorized_keys`, then publickey logins only; fingerprint matched.
- Host keys: tailnet peers pinned from `sshHostKeys` when present, else TOFU.

## Phases (each a TestFlight build)
1. Inbox + glass discipline + onboarding v2 (fixes every reported bug). Built.
2. Transcript conversations with live tailing and unread. Built.
3. Ask cards + PromptDriver with terminal fallback. Built: multi-select, several questions,
   "Other".
4. Screen prompts; Claude Code / Codex transcripts; rich tool steps (`ToolDetail` →
   `ToolStepView`: shell command + output + exit code, diffs from omp `details.diff`, Claude
   `structuredPatch`, Codex `apply_patch`; plans from TodoWrite/Tasks/`update_plan`/
   `todo_write`). Built.
5. Attention: local alerts, badge, widgets, visibility-based read state, Mark as Read/Unread,
   undo of queued omp messages. Built.
