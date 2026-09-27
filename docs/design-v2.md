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
| `agent_status` | blocked → "Needs you" (pinned in Priority); a finish not yet read here → "Done" with an unread dot; working → typing dots; idle or a read finish → "Idle" |

Order (Recent, the default): one timeline by each conversation's last turn: the newest message
the user sent (a prompt, or a steer mid-turn) or the moment the agent finished a turn, by the
transcript's own clock. Work inside a turn never counts: thinking, narration beside tool calls,
tool calls and results, status changes, reads. Turn ends come from each format's own marker:
omp's `stopReason` other than `toolUse`, Claude's `stop_reason` other than `tool_use` or its
`turn_duration` record, Codex's `task_complete` (`TranscriptEntry.turnEnded`). `HostConnection`
reads what each transcript gained since the last look in one host command per round
(`HerdrClient.readChunks`, `TranscriptActivity`): on connecting, on each snapshot, every 10 s
while live, and when the inbox appears. It pages back from the tail when a long tool run hides
the last turn, and keeps what it knew per host, session and conversation across launches and
outages (`turns.<host>.<session>` in `UserDefaults`). Unknown times sort last; ties fall back to
the pane address, never the title. Priority pins blocked agents in "Needs You" and orders the
rest by status, then last turn. The inbox follows
live order only when resting at the very top; scrolled or scrolling, it holds its order and floats
a "New Activity" button that applies it and scrolls to the first row. It stays held until the
list is back at the very top, because a few points down `List` keeps visible rows fixed and
would insert the newest above them out of sight. Returning to the inbox or changing sort or
grouping applies it too. Cross-host order assumes the hosts' clocks agree.

## Screens (4)
1. **Inbox** (`SessionView`): `List`, inline title. The principal `HostTitle` shows host name
   over address (or connection state) as one control, no chevron: tap opens the Hosts sheet
   (All Hosts as an exclusive choice, hosts in the user's order with Edit/drag to reorder,
   Add Host, the host's herdr sessions, Edit host). Swipe it to move to the previous/next
   host (push transition); their names peek dimmed at the edges. In All Hosts the title reads
   "All Hosts · N hosts" and doesn't swipe. `.toolbarTitleMenu` was dropped because its label
   flies away while the menu is open. Leading toolbar button: Search; trailing: Settings. Bottom bar: View
   options at the leading edge (one menu with titled View, Group and Sort sections; Group and
   Sort only for Agents) and "+" (New Agent) at the trailing edge. Row: status
   glyph, conversation title (terminal title minus the agent glyph prefix),
   "status · workspace", unread dot, and (Settings › Message Previews, on by default) one
   line of the newest user/assistant text, from the transcript tail the inbox already reads for
   recency (`TranscriptActivity.preview`, ≤140 chars). Agents with a transcript open the
   conversation; others open the terminal. The magnifier (or ⌘F) opens a search bar over title,
   workspace, folder, host and (with previews on) that line; the magnifier turns into ✕, which
   closes and clears it. While anything shared from another app is unsent, a "Shared · N" row
   tops the list (see architecture.md).
2. **Conversation**: transcript rendered as chat; pending ask as native cards above the
   composer; composer (`pane.send_input`, text + `enter`). Title = transcript title or agent,
   subtitle = status text in colour + workspace. Toolbar: Terminal, then (spaced apart) a More
   (`ellipsis`) menu with detail level, Find in Conversation, Retry Last Turn (omp Alt+R, only
   after a turn ended in an error), Stop Run (omp, Claude and Codex, while working; confirmed,
   sends Esc), Show Live Activity, the session's
   model, thinking level and token/cost totals of the loaded messages, Mute Notifications (1 hour
   or until unmuted; see Attention) and "Why <status>?" (herdr's `agent.explain`, read-only).
   Find searches the loaded messages only (its field says so), steps newest-first and switches to
   Full detail when a match is folded away. While omp works the composer's + menu offers Send
   After This Run (typed into omp's editor, then Ctrl+Q queues it as a follow-up).
3. **Terminal**: existing SwiftTerm surface pushed from the conversation or a shell row; observe
   by default, typing mode (takeover) opt-in. The fallback for anything we can't structure.
   Reading scrolls like a document without touching the host's pane: vertically into earlier
   output (`pane.read recent`, ANSI colours, loaded on open and each time you scroll up into
   it) and sideways when the pane is wider than the phone (observed at its `pane.layout`
   width). Typing mode fits the screen and doesn't scroll. Read as Text opens the last 2000
   lines as wrapped, Dynamic Type monospaced text: selectable, VoiceOver-readable, searchable,
   web links open in the browser and image paths in the host-file preview. Other paths stay
   text: a host path is never opened locally or run.
4. **Settings / hosts** sheet; onboarding is a sheet flow.

Agentless panes keep the terminal and command composer (“Run a command”); Send submits
with Enter, with attachments (including images) pasted as shell-quoted paths. Under the
header, an accent glass-prominent Start control launches OMP, Claude or Codex in that pane.
The kind is remembered per host profile (`lastAgentKind.<profileID>`) and also seeds
New Agent. A foreground non-shell process triggers “Start in New Tab” /
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
one; grouping None/Host/Workspace/Status, with "Needs You" pinned first in Priority; sort Recent or
Priority (blocked, unread done, working, idle, unknown); collapse idle. Rows swipe leading to
Mark as Read/Unread (full swipe) and Hide/Unhide (local), trailing to Close (confirmed); the
context menu has New Agent Here.

New Agent (`NewAgentSheet`) is "+" → Start: workspace and agent kind are preselected. The
workspace is the one last started in on that host and
session (id and label must still match; herdr reuses ids after a restart), else herdr's focused
workspace, else the first; with none, the home folder. Changing it lists every workspace in
view (All Hosts groups them by host and session) and Choose Folder…, a one-level remote folder
browser (`HerdrClient.folders`, NUL-framed, dot folders hidden, repositories marked with a
one-tap Use) that opens next to the selected workspace's folder; a typed path is a fallback in
its menu. An existing workspace gets a new tab that inherits its folder; a folder that exactly
one workspace's panes report reuses that workspace, any other folder gets a new workspace
(labelled by herdr with the folder name). The terminal button beside Start opens a plain shell
in the same place instead. Created panes skip the busy check and wait out startup files; a
failed start keeps its pane for the next attempt. The start waits (up to 10 s) until the mirror
shows the agent, so its conversation never opens on "Agent exited". Agents that report a
transcript (omp; claude and codex once `herdr integration install` has run on the host) open
in their conversation, the rest in the terminal.
Launch presets (Settings › Conversations › Launch Presets) name an agent kind plus arguments,
one per line, passed as literal argv (`agent.start {args}`: no shell, quoting or variables);
New Agent shows a Preset picker when any exist, and no preset starts exactly as before.
New Agent can instead start in a new worktree of the chosen workspace's repository: a typed
branch name, herdr's default base, `worktree.create` with `focus:false`, then the agent in the
returned workspace's root pane. Workspace rows show herdr's worktree metadata (repository,
checkout); the snapshot has no branch field, so none is guessed.

Ended agents sit in a collapsed Ended section of the inbox: at most 50 local descriptors (host,
session, harness, transcript path or session id, folder, workspace, title, when seen), recorded
while the agent is live. Only an authoritative live snapshot marks an exit; a disconnect,
preview snapshot, filter or host switch never does. Opening one shows its transcript read-only.
Resume starts `omp --resume <path>`, `claude --resume <id>` or `codex resume <id>` as literal
arguments through the normal start flow in a new unfocused tab of the original workspace; if
that workspace is gone or changed it asks where. Remove forgets the descriptor only.

On connecting, and after a start that opened in the terminal for lack of a transcript, the app
checks `integration.list`. A missing integration for an installed harness is offered only where
it matters, never on Home: Settings › host › Integrations (all missing), and for that agent's
harness in New Agent, the "No conversation" placeholder and the terminal toolbar. The install is
confirmed (`integration.install`); the terminal works without it; restart the agent afterwards.

The composer attaches files and images, uploaded to the host and cleaned up after the chosen
retention (1 hour/day/week, default a day). Its + menu inserts saved snippets (Settings ›
Messages › Snippets) into the draft; a snippet is never sent by itself. The on-screen Return adds a line unless "On-screen
Return Sends" is on; on a hardware keyboard Return and ⌘↩ send, ⇧↩ or ⌥↩ adds a line.
Conversation detail is Full, Folded (default) or Digest: one saved preference, set in Settings
or any conversation's More menu (Find may show Full until its Done). The transcript follows its newest
message through replies, the composer resizing and the keyboard until you scroll away;
scrolling back to the end, or sending, resumes following.
Sending clears the draft at once and keeps the field focused (disabling it resigned the
keyboard, which slid down and up on every send); a failed send puts the text back ahead of
anything typed since. Unsent text is kept per conversation (`DraftStore`: one atomic,
complete-protection file keyed by host, session and agent session, text only, pruned after 14 days;
a pane-keyed draft moves to the agent session once it's known, and a pane that switches to
another conversation shows that one's draft), so it survives leaving the conversation and
relaunching. A new thread shows one quiet line, "Send a
message to get started.", only once its transcript is live and empty and nothing is being
sent. "Working…" holds its row at the end for the whole turn and only fades while a step
spins in its own row, so tool steps starting and finishing don't shift the transcript.
A message to or from a subagent (`agent://` peer) links to that subagent's thread.

Images: transcripts hold them by reference (`TranscriptImage`, a class compared by identity).
omp stores them as blobs (`"data": "blob:sha256:<hex>"` at `~/.omp/agent/blobs/<hex>`, found
beside the transcript's `sessions` folder); Claude and Codex inline base64, kept undecoded.
User messages carry them above the bubble (clear of its selectable text): in Full detail as
120 pt thumbnails, otherwise one "Image"/"N images" label that shows them in place. A tool
step that returned images gets a photo icon and shows them when its row is expanded (always in
Full), with no separate label; a thumbnail opens the preview. Bytes are read from the host only when shown (`readFile`, two at a
time, capped at 20 MB even if the file grows mid-read), decoded by ImageIO straight to the
size needed (360 px thumbnails in a bounded cache, 3000 px in the zoomable preview). The
transcript isn't lazy, so a thumbnail row scrolled off screen drops its bitmap and takes it
back from the cache (or the host) on return. A code span naming an image file, or a read of
one that returned no images, opens it in the preview.

Settings say only what a label can't: detail levels are checkmark Toggles in a menu (a Picker's
tag spreads over a two-Text row), and Keep Uploads and Alerts While
Away each a one-line footer (when uploads are swept; what never leaves the computer), plus
Alerts While Away's How It Works page.

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
  can appear after herdr reports the id. Several agents' files are located concurrently (at
  most four at a time). A conversation keeps its loaded transcript through reconnects and
  while the agent's reference is missing, and starts over only when a different agent
  session appears in the pane. Subagent and ended transcripts resume following after a
  reconnect.
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
    `AttributedString`; the prose between code blocks, tables and rules is one `Text`, so a
    selection runs across paragraphs and list items),
    `thinking` and `toolCall`s → one folded "N steps · <last summary>" row; a tool call merges
    with its `toolResult` by `toolCallId` (state, first 200 output lines).
  - `custom/tool_execution_start` → running step (replaced by its call); `compaction`,
    displayed `custom_message`, assistant `errorMessage` → centred notices; `title`,
    `title_change`, `session.title` → title; model/thinking/usage/credential/`session_init`
    records and `developer` messages → hidden.
  - Unknown record types survive as raw rows (a newer omp never silently loses content).
    Checked against all 46 local omp session files: zero raw rows.
  - omp branches: records keep their `id`/`parentId` envelope, and the active leaf is the last
    record that carries conversation (message, custom message, branch summary, compaction).
    When a record's parent isn't the leaf, the visible items are rebuilt from its ancestor path
    within the loaded window, so an abandoned branch's messages and asks disappear. An ancestor
    older than the window leaves the loaded prefix in place with a line saying it may be from
    another branch; Show Earlier loads more. Claude and Codex render in file order.
  - `Conversation.modelID`, `thinkingLevel` and `usage` (input/output tokens, cost when
    recorded, deduplicated per message, active path only) feed the conversation menu.
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
  counts blocked agents across hosts; finished work is not a debt. The badge is recounted
  when Needs You is turned off or a host is removed.
- The app only sees hosts while it runs. In the background iOS wakes it now and then
  (`BGAppRefreshTask`, earliest 15 min): it reconnects each link for one snapshot (20 s cap),
  which raises alerts and updates the widgets, then lets go.
- Widgets (`HerdwickWidgets`: Home small and medium, Lock Screen rectangular/circular/inline)
  read an `AttentionSnapshot` the app writes to the App Group: every visible agent as the app
  presents it (needs you, unread done, working, idle; newest change first within each), when
  the app saw that state begin, and whether every host answered. Small shows the three counts
  and the most pressing agent; medium adds the two most pressing agents, each a link, with a
  live "4m ago", and drops to one agent (then counts only) when the widget or text size leaves
  no room, so nothing clips. The app reloads timelines only when that content changes, and
  rewrites the snapshot for freshness alone at most once a minute. While the snapshot is fresh
  the widget asks for a reload at its 30-minute stale point, which re-reads the latest
  snapshot. Widgets say when
  what they show is old or a host was offline and never claim "all clear" then.
  `herdwick://open?host=&session=&pane=` deep-links alerts and widgets.
- Alerts while away (opt-in, Settings › Alerts While Away, with a How It Works page). As the
  app backgrounds it arms a watcher on each live link over the SSH it already holds
  (`PushWatch`, inside a background task) and disarms it when the link next comes up in the
  foreground, including after the app was closed. The watcher is a POSIX `sh` script written
  to `~/.herdwick/<installation UUID>-<host profile UUID>/` (`watch.sh`,
  `push.<session>.env` 0600 with secrets from stdin, `watch.<session>.pid`), so two phones or two
  profiles for one computer never stop each other's watcher; watchers from older builds are left
  alone. Per agent
  one `herdr agent wait` blocked on herdr's socket (measured on herdr 0.9.1: no CPU, no context
  switches in 20 s, ~6 MB), one `agent list` (~20 ms CPU) every 120 s for agents started
  meanwhile, one `curl` per alert, and it exits after 24 h or when herdr stops. No daemon, no
  port, no install. `idle` after `working` counts as done (herdr skips `done` for the pane
  focused at the desk). Settings lists each covered session with "Last armed <time>", why it
  was skipped (not connected, host not selected) or the error: a handoff, not proof of delivery.
- The post carries only the device token and opaque ids (host UUID, session, pane, state,
  seq) plus an HMAC-SHA256 (`openssl`, key from the 0600 env file; it is briefly an `openssl`
  argument on the host) over `v1|host|session|pane|state|seq` with a secret only the phone and
  host hold. The relay (`relay/`, a Cloudflare Worker holding the APNs key) validates
  them, forwards the MAC untouched, rate-limits 20 a minute per device, sends a generic
  `mutable-content` alert with a collapse id per agent, and stores and logs nothing. The
  relay can't verify the MAC (only the phone and host hold the secret), so it accepts posts
  with or without one and deploys before the app; delivery is authorized by possession of the
  device token, which only the phone and the host's 0600 env file hold. The notification service
  (`HerdwickNotifications`) fills in the thread's title and place from the names the snapshot
  keeps for every agent the app has seen (hidden ones and other hosts' included), or the host's
  name for an agent it never saw. Only a push whose MAC verifies and whose seq is above the
  pane's watermark (never lowered; a herdr counter reset stays stale until it passes it) records
  the seq in the App Group so the app never repeats the alert, moves the agent in the snapshot,
  sets the badge and reloads widgets; others only show the generic alert. A user can't run their own relay for this build: that would mean
  sharing the APNs key. Self-built copies set `HerdwickPushRelay` to their own team's relay.
- Mute Notifications (conversation menu) keys on host, herdr session, pane and the agent's
  session reference, so a reused pane isn't muted; it lasts an hour or until unmuted, silences
  local alerts, and is handed to the watcher at arming (a later mute can't recall an alert
  already sent). It never changes read or blocked state.
- Show Live Activity (conversation menu, while working) starts one Live Activity in the foreground for that agent.
  The app updates it while open; with Alerts While Away on, the same watcher sends that pane's
  working, needs-you and finished changes to the relay with the activity's push-to-update token
  (`kind: liveactivity`, MAC domain-separated as `v1|liveactivity|…`), which the relay sends as
  `apns-push-type: liveactivity` (update, or end on finish; four-hour stale date). Alert toggles
  and mutes don't silence an activity the user asked for. No push-to-start, one run at a time,
  and no promise of continuous liveness: the watcher expires after 24 h. A finished run's card
  lingers as "done"; Hide Live Activity dismisses it at once.
- Reply in App: a local Finished alert offers a text field ("Reply in App", foreground and
  authentication required). The typed text is saved as that conversation's draft and the app
  opens it for review; nothing is sent from the notification. Remote pushes don't offer it: the
  v1 MAC doesn't bind the transcript, so a reply couldn't be proven to land in the right agent.
- Host clock: once per connection the app samples `date +%s`; if the host is more than a minute
  off beyond the round trip, Machines shows a warning under that host. It's only a warning.
- Ruled out: CloudKit (web tokens are single-use), Local Push Connectivity (restricted
  entitlement, named Wi-Fi only), Tailscale (the phone's node is down while suspended).
  T3 Code's "settled" shelf was not adopted:
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
`arguments.questions[] = {id?, header?, question, options[{label, description, preview?}],
multi?|multiSelect?, recommended?}`. `AskPanel` pages the questions ("HEADER · 1 OF 2"):
single-select options answer on tap, and an "Other answer" field takes free text;
multi-select shows checkboxes with Back/Next/Send. On omp, "Other" also sits under checkboxes
and joins the checked options, and each question takes an optional note (omp's `n`, typed into
its note editor and confirmed back on the question); an option's `preview` shows under it.
Shown above the composer only while
herdr says `blocked`. Answered asks show each question's own answer (`AskAnswer.perQuestion`)
and its note. omp's "Chat about this" isn't offered.

Answer driver (closed loop, `PromptDriver` in HerdwickCore `AskDriver.swift`, injected
`PromptIO`; per-agent key sequences are in its doc comment):
1. `pane.read {source:"visible", format:"text"}` → locate option rows by label (strip
   " (Recommended)") and the cursor row (starts with U+F054).
   Every read must match the question text and the call's option labels, or nothing is sent.
   Rows are logical (options, then "Other", then Claude's `Submit`): a pane smaller than the
   box (herdr's default 80×24) cuts the question with "…", scrolls the options with a `█`/`│`
   scrollbar column and may wrap a label, so the visible rows must be a consecutive run of the
   call's rows, matched by label prefix (Claude by row number). Before this, every multi-question
   ask in such a pane failed to "Answer in the terminal". Verified 2026-09-27 at 82×24 against
   omp: three questions with multi-select, the last option of a scrolled list, and "Other".
2. One `up`/`down` per `pane.send_keys`, re-reading after each; the cursor must land on the next
   logical row (the list may scroll under it) or the driver stops before `enter`.
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

Tier B, screen prompts (Claude permission, Codex approval, omp tool approval `╭─ Allow tool: …`
and omp Plan Review): when `blocked` with no pending ask, the app reads the pane every 2 s;
`ScreenPrompt.choice` finds the numbered options and
the title (last "?" line that isn't a `$ ` line or a "Label: " line), with context lines;
`ScreenPrompt.ompChoice` reads omp's boxes (cursor U+F054, no numbers, every option visible or
nothing parses). omp's Plan Review leaves herdr at `idle`, so it is watched when the transcript's
last omp call is a `write` to `xd://propose` answered "Plan ready for review."
(`Conversation.pendingPlanReview`) and nothing followed; its card shows only the plan text on
screen and says so (`contextMayBeTruncated`). "Approve and execute" starts a new omp session.
`PermissionCard` shows them (every option alike: the first is not necessarily the safe one;
long context expands to all lines); a tap runs `PromptDriver.choose` (↑/↓ re-reading after each,
Enter), confirmed by the prompt leaving the screen. Verified in the app: Claude Bash Yes (ran)
and No (rejected, "[Request interrupted…]" notice), Claude Edit Yes (diff in the card), Codex
"Yes, proceed" (ran). omp approval and Plan Review parsing and cursor moves verified live on
omp 18.3.1 (fixtures `omp-approval*.txt`, `omp-plan-review.txt`).

## Onboarding and auth
- Tailnet peers: offer Tailscale SSH only when the peer advertises `sshHostKeys`; otherwise it
  is not shown (the user's host runs no Tailscale SSH server: `RunSSH:false`).
- Both paths offer Password (default unless Tailscale SSH is available) and the manual key.
  The host is trusted before any password leaves the phone: `KeySetup` first dials with no
  authentication and a validator that records the presented host key and refuses it, so the
  server never receives a userauth request (live test `refusedHostKeySendsNoUserAuth` checks
  sshd's log). It shows the fingerprint and `user@host` ("Checking the server…"); a tailnet key
  that doesn't match the peer's advertised `sshHostKeys` stops setup. Only after "Trust" does
  it sign in with the password pinned to that key ("Signing in…"), then on "Install this
  iPhone's key" runs `AuthorizedKeyInstall` (strictly
  validated key line, refuses a symlinked `authorized_keys`, modes 700/600, idempotent) over
  that connection, re-dials with the key against the same host key, pins it, saves the host as
  device-key auth and drops the password. "Keep using password" stores it in the Keychain.
  The password field is cleared once `KeySetup` has it, so iOS doesn't offer to save it.
  Verified 2026-09-25 (simulator → asyncssh server on the tailnet): password sign-in, key
  installed into `authorized_keys`, then publickey logins only; fingerprint matched.
- Host keys: tailnet peers pinned from `sshHostKeys` when present, else trust on first use as
  above. A changed key fails the connection; "Trust New Key…" shows the pinned and presented
  fingerprints side by side before replacing the pin, and Forget Pinned Host Key asks first.

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
