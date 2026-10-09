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
| `agent_status` | blocked → "Needs you" (pinned in Priority); a finish not yet read here → "Done" with an unread dot; working → "Working"; idle or a read finish → "Idle". Glyphs: filled silhouettes of a like weight, each its own shape: `exclamationmark.bubble.fill` (a question waiting), `checkmark.circle.fill`, `circle.dotted.circle.fill` (still, no spinner), `moon.zzz.fill`, `questionmark.circle.fill`; the Live Activity uses their outlines. Not a chat-bubble family: dots in a bubble read as the agent typing to you |

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
   flies away while the menu is open. A host can be turned off without removing it (a laptop
   that's shut, a machine only reachable at home): the Connect switch in its editor, or a swipe
   in Settings › Hosts, where it then reads Off. An off host is never dialled, retried or woken by
   a network change (`HostConnection.handle` drops every input). It drops out of All Hosts, the
   title swipe, widgets and push, and stays in the Hosts sheet marked Off. Picking it there
   shows "Is Off" with Turn On. Turning off the shown host moves the window to the first host
   that's on; with none on, it stays and shows that state rather than onboarding.
   Leading toolbar button: Search; trailing: Settings. Bottom bar: View
   options at the leading edge (one menu with titled View, Group and Sort sections; Group and
   Sort only for Agents) and "+" (New Agent) at the trailing edge. Row: status
   glyph, conversation title (terminal title minus the agent glyph prefix),
   "status · workspace", unread dot, and (Settings › Message Previews, on by default) one
   line of the newest user/assistant text, from the transcript tail the inbox already reads for
   recency (`TranscriptActivity.preview`, ≤140 chars). Agents with a transcript open the
   conversation; others open the terminal. The magnifier (or ⌘F) opens a search bar over title,
   workspace, folder, host and (with previews on) that line; the magnifier turns into ✕, which
   closes and clears it. While anything shared from another app is unsent, a "Shared · N" row
   tops the list (see architecture.md). With no rows, "No agents" (New Agent) appears only
   once a host is live ("No agents on the connected hosts" while others aren't); while the
   first attempts run, the per-host status lines are all it shows, and once every host is down
   (failed, offline, or retrying after a failure) it shows "No hosts connected" with Add Host.
2. **Conversation**: transcript rendered as chat; pending ask as native cards above the
   composer, on a material surface so the transcript doesn't show through when scrolled beneath;
   composer (`pane.send_input`, text + `enter`). Title = transcript title or agent,
   subtitle = status text in colour + workspace. While the host is (re)connecting, this and a
   subagent's thread also show the link status ("Reconnecting in 4s") as a small material badge
   mid-screen, faded in after 0.5 s so brief blips don't flash it. Toolbar: Terminal, then (spaced apart) a More
   (`ellipsis`) menu: first a row of places side by side (a `ControlGroup`: Find, then Images and
   Changes when there are any), so a slip lands on a visibly different neighbour, not the next
   look-alike text line; then iconed, named submenus: View (Folded/Digest), Session (the
   session's model with Session Details, Show Live Activity, "Why <status>?"), Mute
   Notifications; then Retry Last Turn (omp Alt+R, only after a turn ended in an error) and Stop
   Run (omp, Claude and Codex, while working; confirmed, sends Esc) last, each in a section of
   its own; `.menuOrder(.fixed)`. Session Details is an alert: thinking level, tokens and estimated cost; omp's own
   estimate, Claude and Codex record none; with earlier messages unloaded, opening it first
   totals the whole file on the host in one `awk` pass (`HerdrClient.sessionUsage`: omp and
   Claude assistant usage, Claude once per API message id, Codex's latest cumulative
   `token_count`) and shows "Whole session", since an alert's text is fixed once shown; past
   3 s or on failure, the loaded messages' totals with "Loaded messages only". Mute is 1 hour
   or until unmuted (see Attention); "Why <status>?" is herdr's `agent.explain`, read-only.
   The menu is its own view compared by value and holds nothing that changes per reply: a
   visible menu that SwiftUI rebuilds jumps back to its top, and the conversation re-renders
   with every streamed record.
   Find searches the loaded messages only (its field says so), steps newest-first, shows Folded
   while a match is one Digest hides, and opens the run holding a match. While omp works the composer's + menu offers Send
   After This Run (typed into omp's editor, then Ctrl+Q queues it as a follow-up).
   **Agent dock** (`AgentDock`): one 44 pt glass button, the composer's round-button size,
   standing on the send button as the mic stands on +; a field taller than the pair carries
   both up to its top corners. With a one-line field they flank the pinned Now or catch-up
   line over the field, so a working agent adds no second row. On an agent's
   terminal it stands on the composer's send button too, and ends the keys' row while typing
   mode hides the composer. The bar reserves the slot
   (`AgentDock.slot`, an anchor preference) and the dock's own layer over the thread draws the
   button there, so the stack can open over everything and morph out of it. The stack is
   capped by the room between the top bars and the button, so the keyboard never pushes it
   under the header. Send stays its own
   button: an agent can need the user mid-draft. It is about keeping agents busy, not
   tracking them: its glyph and colour are the most urgent other thread's (orange Needs you,
   green Done, else a neutral conversations glyph), a count of what wants the user (drawn
   outside the glass container, which would composite over it), and no text. A
   tap morphs it (`glassEffectID`, 200 ms ease-in-out; the glyph's replace runs at 2× to land
   with it; a crossfade under
   Reduce Motion) into a stack of the other threads in the inbox's scope, Hidden and Ended left
   out. Settings › Agent Dock turns it off (the pinned line then sits over the field alone) and Dock
   Order picks the order. The default, Attention, Working, Idle: Needs
   attention (Needs you, then Done; within each the one waiting longest first by herdr's
   session-wide `state_change_seq`), then Working, then Idle (each the latest turn first).
   Same as Inbox uses the Agents list's grouping and sort under a leading Needs You. The first
   row that wants the user is set apart (bigger title, two preview lines, a tinted plate) so
   the next move reads at once.
   Rows show status glyph, title and the newest line (or the workspace without previews; the
   host under All Hosts). The order is frozen while the stack is open: status glyphs update in
   place, ended rows drop out and new threads wait for the next opening. A tap replaces the open thread in place, without
   animation on a phone (`scene.open`); a thread without a transcript opens its terminal.
   Opening a thread is not a read; the usual read gate decides. The dock is disabled while a
   send is in flight, since the composer and attachments belong to the thread they started
   in; a send that fails afterwards restores its text to its own draft. Dismiss with the
   button (it becomes Close), a tap outside, or the accessibility escape gesture. In a split
   view the selected thread is the detail stack's root (swapped in place) rather than a pushed
   view: pushing it blanked the column on every change of selection.
   A hold on the closed button opens the **quick switch** instead: a native menu (`Menu` with a
   primary action, so a tap still opens the stack) of only what wants a turn now. That means
   Needs you and Done (the longest waiting first), then Working (the latest turn first), whatever
   Dock Order says. Idle is left to the stack, and it reads "No active agents" when nothing is
   active. `.menuOrder(.priority)` puts the most urgent row nearest the button, so it reads
   upward. The menu is compared by value, so streamed records don't rebuild it while it's open.
   A pick looks the thread up again, since it may have ended. There's no menu while the stack is open.
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
and the busy program's folder (`Pane.workingDirectory`) without focusing it, skips the busy check (its shell may still run startup helpers
such as mise), and retries `agent_pane_busy` for up to 5 s until that shell is ready.
If process inspection is unavailable, herdr still validates the start. A started agent's
transcript doesn't exist until its first message, so a missing file reads as empty and the
conversation shows “New conversation” while `tail -F` waits for the file.
The inbox's folded terminals are grouped by workspace with “No agent yet” captions
and a leading Start swipe action; Machines uses the same empty-workspace wording.

Inbox options (Settings, persisted in `UserDefaults`): Agents or Machines (herdr's host ›
workspace › tab › pane tree, with Close Tab/Close Workspace swipes); all hosts or the current
one; grouping None/Host/Workspace/Status; "Needs You" pinned first in either sort, by the held
rank while browsing, so a thread doesn't jump into or out of it under the reader; sort Recent or
Priority (unread done, working, idle, unknown); collapse idle ("3 Idle", a summary row at the
end of its group's card; a separate idle section reads as a different group). Idle, Terminals,
Hidden and Ended open from a summary row inside their card (`FoldRow`): the rows come and go at
once and only its chevron turns (150 ms ease-out: it moves on the frame the rows land; an ease-in start lagged them). An animated insert can't look right in an
inset-grouped list: UIKit reshapes a kept row's corners only after the insert, so the summary
stayed rounded over the arriving rows (black notches); a fresh summary row per state crossfades
two half-transparent rows (a dark flash); and a custom row background is clipped to the row's
corners too. Not `.grouped` with hand-drawn card corners: every card would need it, for one
transition; nor rows opening above the summary, which then slides down past them. Rows swipe leading to
Mark as Read/Unread (full swipe) and Hide/Unhide (local), trailing to Close. Close is a plain
red action, not `.destructive` (a list slides a destructive row out at once, then back while the
prompt is open). It asks in a popover anchored to the row (`ClosePrompt`), not a
`confirmationDialog`: a dialog runs its action only after its dismissal animation, about 0.5 s
after the tap. Confirming takes the thread off every list at once (`HostConnection.closing`,
200 ms ease-in-out) while herdr ends it, until a snapshot no longer has the pane; a refusal puts
it back with an alert. The context menu has
Rename… and New Agent Here. Rename sets the pane's name in herdr (`pane.rename`, its manual
label), so herdr and every device show it; it wins over the agent's name, terminal title and
the transcript's title, and an empty name goes back to them. herdr announces no event for a
rename, so `renamePane` nudges the session's mirrors (`MirrorRegistry`) into a fresh snapshot.

New Agent (`NewAgentSheet`) is "+" → Start: workspace and agent kind are preselected. The
workspace is the one last started in on that host and
session (id and label must still match; herdr reuses ids after a restart), else herdr's focused
workspace, else the first; with none, the home folder, resolved to a path before the workspace
is made (herdr puts a workspace without one beside its focused workspace). Changing it lists every workspace in
view (All Hosts groups them by host and session) and Choose Folder…, a one-level remote folder
browser (`HerdrClient.folders`, NUL-framed, dot folders hidden, repositories marked with a
one-tap Use) that opens next to the selected workspace's folder; a typed path is a fallback in
its menu. An existing workspace gets a new tab in its folder (its worktree checkout, else its
first tab's), passed explicitly: left to herdr, the tab starts wherever the workspace's focused
process is, so an agent that changed directory drags new tabs along. A folder that exactly
one workspace's panes report reuses that workspace, any other folder gets a new workspace
(labelled by herdr with the folder name). A workspace's folder is its first pane's shell
directory (`cwd`, what herdr names it after); an agent's own folder is the process in front of
its shell (`foreground_cwd`, `Agent.workingDirectory`), which differs when the agent was started
elsewhere. Relative links and images, resume, row and alert captions use the agent's folder; a
resumed agent's tab opens in it. The terminal button beside Start opens a plain shell
in the same place instead. Created panes skip the busy check and wait out startup files; a
failed start keeps its pane for the next attempt. `agent.start` answers before the agent runs,
so the start then waits (up to 10 s) until the mirror shows the agent, so its conversation never
opens on "Agent exited", and, for agents that report a transcript (omp; claude and codex unless
the host lists their `herdr integration` as not installed), until the transcript is reported.
Those open in their conversation, the rest in the terminal.
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
Composer › Snippets) into the draft; a snippet is never sent by itself. The on-screen Return adds a line unless "On-screen
Return Sends" is on; on a hardware keyboard Return and ⌘↩ send, ⇧↩ or ⌥↩ adds a line.
Conversation detail is Folded (default) or Digest: one saved preference, set in Settings
or any conversation's More menu (Find may show Folded until its Done). A third level, Full (every
run open), was retired: opening a run now opens its diffs, and a stored "full" reads as Folded. The transcript follows its newest
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
sent.

Dictation is the mic over the + button, in both composers, mirroring the dock over Send (a tall field carries both to its top corners; the card's stem reaches down to the mic) so the
field keeps the bar's width: the system keyboard's own mic depends on which keyboard is up, and
a dictation keyboard (Wispr Flow) means switching keyboards. Speech is recognized on the device
by SpeechAnalyzer: SpeechTranscriber, or DictationTranscriber where the first isn't offered or the
user has known terms (only it takes hints: the known terms, then the folder, agent and recent file
names, via `AnalysisContext.contextualStrings`); the first use in a language downloads the
system's model. Tap to listen (the tap also puts the keyboard away, to leave room for an ask; tap
the field to bring it back; ⌘⇧D leaves it up). The keyboard is resigned a turn after the tap, not
inside its action: a UIKit text view resigned inside a SwiftUI action sends the bottom inset to
the screen's edge and springs it back (seen on iOS 27). The mic grows (0.28 s critically damped spring,
no bounce)
into one piece of glass shaped like an L (`DictationShape`), taking its room in the layout as it
grows so the thread moves with it, and shrinks back into the mic on Stop or × (0.24 s; Reduce
Motion swaps them outright). Its stem is Stop, standing where the mic was, and
its top runs across the whole bar, hugging the words up to about four lines (then it scrolls,
held at the newest) beside the × that discards them. It says what it's doing until the first
words, then shows the settled words and, dimmed, the model's open guess, which never reaches the
draft; the words are the sign it hears you, so nothing pulses. Settings › Dictation › Show Live Transcript
off keeps it to one status line ("Listening…", then "Hearing you…" once words are recognized),
for when an agent's question card and a growing draft already crowd the bottom. Stop puts the
words in at the cursor as one undoable insert; stopping before any words ends quietly, with
nothing inserted and no error. (Liquid Glass's own morph, `glassEffectID` with
`.matchedGeometry`, only faded a card in at full width here, and a 300 ms grow-from-the-mic scale
felt sluggish; the words' height changes aren't animated.) The mic stays left and the dock right
although trailing voice is the commoner convention (ChatGPT, Claude, WhatsApp): mic and + gather
the draft, dock and Send act on agents, and a missed mic tap can't send. Nothing sends until the words are in (Stop
never sends), and a call, a route change or leaving the app stops it and keeps what was heard.
Auto-lock is held off while words keep coming (`isIdleTimerDisabled`) and handed back after 30 s
without new words, so a forgotten session can't keep the phone awake; the lock then stops it and
keeps the words. It doesn't record in the background, as Voice Memos does: that would need the
audio background mode and a session that outlives the screen.
⌘⇧D starts and stops it; Escape cancels. A lost connection locks the field, + and Send, but not
Stop or ×. The pinned Now line takes a button's height, so it sits on the mic's and the dock's
center line.

Settings › Dictation › Dictionary has replacements and known terms, applied in that order to the
words in the card (settled and guessed) and at Stop, never to typed text. Recognizers hear an
unfamiliar word as familiar ones ("poster SQL", "item potent"), so the dictionary works twice, as
superwhisper's and VoiceInk's do: known terms bias the recognizer (above), then the words are
rewritten. Replacements rewrite phrases the speech model keeps getting wrong ("poster SQL" →
PostgreSQL): whole words or phrases, ignoring case, apostrophe style and how the words are joined
(spaced, run together, hyphen or comma), longest match first, written exactly as entered, never
chained; they see the words as heard, so they go first. Known terms (`KnownTerms`, a comma or line
list like the Dictation app's custom words) are spelled as entered wherever a run of words, not
broken by punctuation, spells them once case, spacing and punctuation are set aside ("git hub",
"R and D"), a plural or possessive keeping its "s". A term of eight letters or more also takes a
run a few letters off (edit distance 1 from 8 letters, 2 from 10, 3 from 14, same first letter;
"poster SQL" → PostgreSQL, "a board controller" → AbortController); shorter terms match only
exactly, because the Dictation app's Levenshtein-plus-Soundex fallback, applied to every length,
would turn "shift" into a Swift term, "clause" into Claude, "a" into AI.

One line over the composer says what's happening, in the card slot (asks, permission prompts
and Needs You take it first). It is bare, quiet text that hugs its words with the chevron right
after them (not a run line's chevron out at the column's edge, which would hang short of the
agent dock beside it), in the bottom inset (`safeAreaInset`; a `safeAreaBar` would blur
the scroll edge but stops the transcript's text being selectable on iOS 26, so the inset
brings its own 16 pt fade of the background above it): no chip of its own. While the agent or any
of its subagents works, it's the Now line: the newest running call ("Waiting on npm run
bench", "Running npm test +1"), then "BenchCouncil working" or "3 subagents working" and
"1 in background", or just "Working…"; derived only from the transcript's running calls,
working subagents and background commands, and gone offline. Tapping it opens Now: working
subagents (with elapsed time; each opens its thread), running calls and background commands in
full. It replaced the transcript's "Working…" row and the Working Subagents tray and setting.
While it shows, the transcript leaves the present to it: a run's line says only what finished,
and a run of nothing but running calls appears once one settles.
Otherwise, on return to a conversation, it's the catch-up line: "Since 9:41 · 3 edits · 2
replies · 1 error" (red errors), counted after the last item the reader saw at the end
(`ReadCursors`: the newest item with a transcript-given id, saved per conversation like drafts
while the end is on screen, pruned after 30 days). Tapping it scrolls to the same line in the
transcript, a hairline before the first new item; that line coming into view, or sending,
dismisses the pinned one. The demo takes the seen
item from `-HerdwickSeen`.

Motion is scarce and short. Disclosures (runs, steps, More/Less) snap open; only the chevron
turns (180 ms ease-in-out), and opening a line stops following the latest, so the line stays
under the finger while content grows below it (the bottom anchor for size changes holds only
while following and not mid-gesture). Cards over the composer (asks, prompts, Needs You, the
pinned line) appear in place without travel. Status overlays (connecting badge, New Activity)
fade in 150 ms; the badge waits 0.5 s. User-requested moves (host swipe, New Activity's scroll)
are 240 ms ease-in-out, never springs; the host push is scoped to the host's content so the
navigation reset doesn't ride along. Nothing animates streaming, reordering or reflow (no
list-wide animation on the inbox). Reduce Motion drops translation (host switch fades), the
chevron's turn, the scroll animations and the Now dot's pulse. Sheets and navigation are the system's.

Two voices: the user's bubble and the agent's prose (`.body`). Everything else (step runs,
tool steps, messages between agents, subagent results, notices, answered questions) shares one
quiet grammar (`QuietHeader`): a `.subheadline` secondary line with a trailing chevron that
turns down to open it in place, or goes to a subagent's thread; bodies are `.subheadline`,
literal commands, output and diffs `.caption.monospaced()` and unboxed. No icons, cards, success
green, spinners or timers (the Now line's pulsing dot is the one live mark); red means a failure:
a step's line starts "Failed:", a count reads "1 error". A run's line (up to two lines) counts
what it did, however few the calls, errors first in red, then changes ("1 error · 6 edits ·
3 reads · 2 commands · 1 search · 1 message · 2 images"; one call reads "1 edit", its file on
the step inside, and the failed step inside names itself), and while running says what it's
doing ("Waiting on npm run bench…", commands by name without flags). Only calls with no noun (a
stopped process, a wait) keep their title. Beside its chevron a tertiary count says how many
lines opening it shows (`StepRun.steps`) when the counts don't add up to it (thinking, waits).
Opening a run opens its edits' diffs (and a lone call's detail) with it: one tap to the change.
A diff, command or search output, or written file sits in a box at most 320 pt tall that scrolls by itself
(`CappedScroll`; a diff scrolls both ways), so a long one never pushes the step's and run's
headers out of reach; only output past 500 lines waits for "Show all". An opened command shows itself whole only
when its line may have cut it. Messages between agents read "From X" and
"To X" (a brief shows its "Change" section first), results "X finished · 2m05s"; each shows two
lines, More the rest. A reply or result answering a lone brief (`answeredBriefs()`: the only
brief sent to that agent since it last spoke) carries the brief, under "Asked" when opened,
and the brief leaves its run; two briefs before one answer stay where they were rather than
guess which was answered. The More menu's Changes lists each file the tools recorded edits or
writes to, with each call's diff or written text, newest first: never a net diff, and a
shell's own changes aren't there.

Images: transcripts hold them by reference (`TranscriptImage`, a class compared by identity).
omp stores them as blobs (`"data": "blob:sha256:<hex>"` at `~/.omp/agent/blobs/<hex>`, found
beside the transcript's `sessions` folder); Claude and Codex inline base64, kept undecoded.
User messages carry them above the bubble (clear of its selectable text): one "Image"/"N
images" label that shows them in place as 120 pt thumbnails. A tool
step that returned images shows them when its row is expanded, with no
separate label; its run's line counts them, and the More menu's Images opens every tool image in the
whole session as a grid, newest first. Unloaded history is listed on the host
(`transcriptToolImages`: one awk pass returning only image-bearing tool-result lines, inline
base64 swapped for a `hwline:<line>:<ordinal>` reference fetched one image at a time; an 80 MB
omp session with 737 images answers in 0.08 s with 390 KB). The loaded images show at once and
keep their cached thumbnails; a failed listing leaves them with "Loaded messages only". A
thumbnail opens the preview. Bytes are read from the host only when shown (`readFile`, two at a
time, capped at 20 MB even if the file grows mid-read), decoded by ImageIO straight to the
size needed (thumbnails at their tile's pixel size in a bounded cache, 3000 px in the zoomable
preview). The transcript isn't lazy, so a thumbnail row scrolled off screen drops its bitmap and takes it
back from the cache (or the host) on return. A reply paragraph of only image embeds
(`![alt](shots/a.png)`, host paths resolved against the agent's folder) shows them as that
thumbnail strip, always inline and never cached across hosts; web images stay plain links
(never fetched by the app). A composer attachment opens the same preview from its chip before sending.
The Images grid fills the width with square tiles (about 110 pt, 4 pt apart); a tile is
hit-tested by its own square, never its cropped overflow. The preview's bar shares the
original bytes as a named file (`Image 2.png`) and saves them to Photos; a long press on any
thumbnail offers Save to Photos too. Saving asks for add-only access on first use
(`NSPhotoLibraryAddUsageDescription`); a denial offers Settings, and a save confirms with a
brief "Saved to Photos".

Mentioned files open without the agent linking them a certain way (`FileLinks`): a code span,
a word in prose with a `/` or an image extension (not a URL; a bare `a.swift` could be Node.js),
an inline embed, a Markdown link with no scheme or `file:`, a read's path, or a terminal line
naming an image or text file becomes a link, a line reference (`:42`, `#L10-L20`, omp's read
selectors) dropped. A bare name resolves to the newest path a tool read,
wrote, edited or printed (`Conversation.touchedFile`; a full path only to itself, a URL never), reusing that read's images without asking
the host. Images open in the zoomable preview; text and source in a file viewer (first 3000
lines of at most 2 MB, Markdown rendered, shareable).

Settings say only what a label can't: detail levels are checkmark Toggles in a menu (a Picker's
tag spreads over a two-Text row), and Keep Uploads and Alerts While
Away each a one-line footer (when uploads are swept; what never leaves the computer), plus
Alerts While Away's How It Works page. Hosts list each name above its address.

Settings choices are menus (`SettingsMenuRow`), not menu-style Pickers: iOS 26 morphs a closing
menu back into its source in window space, so scrolling while it closed left the value floating
where the row had been and the row blank. The menu's label is identity glass (draws nothing) in
its own `GlassEffectContainer`, which keeps the value in the row; only the menu's platter fades
where it was. The menu sprouts from its label's frame, so the label is the trailing value alone
(a full-row label opened the menu centred over the title); like a menu Picker, the title doesn't
open it. Appearance stays segmented.

Liquid Glass only on: system toolbars (automatic), the composer container, the key bar, ask
option buttons. Never glass inside a toolbar item or inside another glass container. Status is
text/glyphs, never a glass capsule. Remove glass from `StatusBadge`, `ConnectionPill`,
`FailureCard`.

## Conversation source of truth
- herdr's snapshot gives `agents[].agent_session = {source, agent, kind, value}`. omp reports
  `kind:"path"` (`~/.omp/agent/sessions/<slug>/<ts>_<id>.jsonl`); Claude Code and Codex report
  `kind:"id"`, and `HerdrClient.locateTranscripts` finds every such agent's file with one exec:
  each agent's own `CLAUDE_CONFIG_DIR`/`CODEX_HOME` (from `/proc/<foreground pid>/environ` on
  Linux), then the shell's, then `~/.claude` / `~/.codex`; `projects/*/<id>.jsonl` or
  `sessions/*/*/*/rollout-*-<id>.jsonl`. The app retries 4× (2/4/6 s): a fresh session's file
  can appear after herdr reports the id. A conversation keeps its loaded transcript through reconnects and
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
- `ConversationFeed` (app) over `HerdrClient.followFile` (HerdwickCore): only the open
  conversation is read, over one exec channel so opening costs a single round of channel
  setup. The host measures the file and sends `<size> <start>` plus its first 4 KiB in base64
  (line 1 is a padded `title` record rewritten in place, so the title comes from there), then
  `exec tail -c +<start+1> -F <path>` from the last 256 KiB (partial first line dropped). The
  remote `tail` dies when the channel closes, because the shell is waiting on stdin. Claude
  Code and Codex paths come from the inbox's preview reads when it has found them, so opening
  skips the host lookup. "Show Earlier Messages" reloads with 4× the window. A dropped channel
  (backgrounding closes the transport) keeps the painted conversation; the view follows again
  on the same transport after 2 s or when the reconnect bumps `liveID`. Only a first read that
  never painted shows "Couldn't read this agent's transcript".
- Opening is instant: `ConversationRegistry` (owned by `AppModel`, handed to each
  `HostConnection`) keeps a `ConversationState` (feed, location, pending sends) per
  conversation, so the view reads app-owned data instead of starting from nothing. The inbox's
  activity reads already fetch each agent's transcript tail and then its new bytes; for the
  eight most recent conversations per host (last turn, or last opened here) those same bytes
  are parsed off-main into a `WarmConversation` with its byte offset. Opening paints that at
  once and `followFile(resumeOffset:)` continues from the offset (the host falls back to the
  window when the offset is past the file's end, e.g. a truncated file). The spinner shows only
  when nothing is renderable. A warm conversation is not yet caught up (`isCaughtUp`): read
  state and pending settlement wait for the follow to reach the end, and the pinned catch-up
  line waits for a live read. An unopened conversation that grows past twice the window is
  replaced by a fresh tail. At most eight inactive parsed conversations per host are kept
  (warm targets first), a memory warning drops them (the next activity read warms them
  again), and a conversation with pending sends is never evicted. With offline transcripts on,
  a follow resumes only onto a saved copy that ends at the same offset; otherwise it reads the
  window again behind the warm paint, so the copy stays contiguous. Two windows showing one
  conversation share one follow. A file truncated and regrown past the offset isn't detected
  (transcripts are append-only).
- `TranscriptReader` → `TranscriptEntry` → `Conversation` (HerdwickCore `Transcript.swift`;
  omp shapes below):
  - `message/user` → user bubble; `message/assistant` `text` → agent text (Markdown blocks:
    headings, lists and task lists, quotes, code, tables that scroll sideways; inline via
    `AttributedString`; the prose between code blocks, tables and rules is one `Text`, so a
    selection runs across paragraphs and list items),
    `thinking` and `toolCall`s → one folded run row (above); a tool call merges
    with its `toolResult` by `toolCallId` (state, first 200 output lines).
  - `custom/tool_execution_start` → running step (replaced by its call); `compaction`,
    displayed `custom_message`, assistant `errorMessage` → notices (errors red). omp's
    `async-result` `<system-notice>` is split by `details.jobs`: task results complete
    subagents, and each finished background command becomes a "Finished <command>" step
    carrying its output, where it arrived. Redacted (empty) thinking shows nothing; `title`,
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
- A sent message shows as the user's bubble from the tap, not once the agent writes it down
  (seconds, and a new thread has no transcript until then). Pending sends live in the
  conversation's `ConversationState` and are saved with its draft (`DraftStore`), so they
  survive leaving the conversation and relaunching; they are never resent. Each records the
  conversation's last stable item when sent (any kind, so a window of only tool output still
  has one), and leaves when a user message after it in the transcript holds its text
  (whitespace aside; attachments add paths); each transcript record settles one
  pending send, so two identical sends need two records. A failed send takes it back to the
  composer; a long press offers "Remove Pending Message".
- Sending while an omp agent works queues the message as steering: it shows dimmed under the
  conversation, "Queued · Tap to Edit", until the transcript records it. Tapping the newest
  sends omp's Alt+Up (restore the last queued message to its editor), checks omp's editor on
  screen (`OmpEditor`), clears it with Ctrl+C (which leaves the turn running) and puts the
  text back in the composer. If omp took the message first, its editor stays empty and
  nothing is cleared. If the editor holds a different message (one queued at the desk since),
  it is left there and nothing is cleared.

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
- Alerts while away (opt-in, Settings › Notifications › Alerts While Away, with a How It Works page). As the
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
   omp renders both as markdown, so the comparison drops emphasis and code markers, link
   targets, entities and all whitespace on both sides (`PromptDriver.comparable`).
   Rows are logical (options, then "Other", then Claude's `Submit`): a pane smaller than the
   box (herdr's default 80×24) cuts the question with "…", scrolls the options with a `█`/`│`
   scrollbar column and wraps a long label onto indented lines (matched with them), so the
   visible rows must be a consecutive run of the call's rows, matched by label prefix (Claude by
   row number). A narrow pane also wraps omp's tab row: every header line up to the one ending
   in `Submit` is tabs. Before these, a multi-question ask in such a pane failed to "Answer in
   the terminal" ("a different prompt"). Verified 2026-09-27 at 82×24 against omp: three
   questions with multi-select, the last option of a scrolled list, and "Other"; 2026-10-02 at
   48 columns against omp 18.4.4: six questions with a three-line tab row, a three-line label,
   markdown in questions, and multi-select, every answer recorded as chosen.
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
  device-key auth and drops the password. "Keep Using Password" stores it in the Keychain.
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
