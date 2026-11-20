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
| `agent_status` | blocked → "Needs you" (pinned in Priority); working → "Working"; idle or done → "Done", read or not: run state, not read state (round 11: a read finish turned "Idle" with a moon, as if reading changed the agent's work). Unread is the dot and the green filled check (`Tokens.Tint.settled`: system green in the dark, #248A3D in the light, where system green on white is about 2:1; round 41: sa#5, light-mode passes read pale); a read finish keeps the word with a secondary outline check, and under Status grouping sits in "Read" (the inbox section, the dock lane and "N Read" fold) below Working, while unread results sit in "Done" above it (round 12: the read section was "Earlier", which read as a time range). Glyphs: silhouettes, each its own shape: `exclamationmark.bubble.fill` (a question waiting), `checkmark.circle.fill` (unread) / `checkmark.circle` (read), `circle.dotted.circle` (an outline, so the working rows stay quieter than the one that wants you, round 6; turning slowly in inbox rows, still under Reduce Motion), `questionmark.circle.fill`; the Live Activity uses the same glyphs. Not a chat-bubble family: dots in a bubble read as the agent typing to you |

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
1. **Inbox** (`SessionView`): `List`, inline title. The principal `HostTitle` says "Inbox"
   (headline) over the host's name (caption; round 5: the host alone didn't say what the screen
   was) as one control with a small `chevron.down` so it reads as tappable: tap opens the Hosts sheet
   (All Hosts as an exclusive choice, hosts in the user's order with Edit/drag to reorder,
   Add Host, the host's herdr sessions, Edit host). It takes taps only: the earlier swipe to the
   previous/next host was invisible, so with two or more hosts on, a row of glass host chips
   (All, then each host with a live/connecting/failed dot; the chosen one `primaryAction()`)
   sits under the bar, and switching is one tap. In All Hosts the title reads
   "All Hosts · N hosts". `.toolbarTitleMenu` was dropped because its label
   flies away while the menu is open. A host can be turned off without removing it (a laptop
   that's shut, a machine only reachable at home): the Connect switch in its editor, or a swipe
   in Settings › Hosts, where it then reads Off. An off host is never dialled, retried or woken by
   a network change (`HostConnection.handle` drops every input). It drops out of All Hosts, the
   chips, widgets and push, and stays in the Hosts sheet marked Off. Picking it there
   shows "Is Off" with Turn On. Turning off the shown host moves the window to the first host
   that's on; with none on, it stays and shows that state rather than onboarding.
   Top bar: Search leading (its VoiceOver hint names every field it matches, round 29); Select and Settings trailing, separate glass items with a fixed
   spacer between (one capsule read as a single control). Bottom bar: the View menu at the
   leading edge (Needs You Only, Group, Sort, Collapse Read, and Panes…, the host › workspace ›
   tab › pane tree as a sheet; VoiceOver hears what it's set to, "Grouped by Status, Recent first", round 74: sb#10) and "+" (New Agent) at the trailing edge. These live only here,
   not in Settings. Between them, while any agent needs you, a "Needs You N" chip (the attention
   glyph and count, on the bar's own glass alone as its neighbours are; round 66: sa#6, a raised capsule inside it gave nested edges) turns Needs You Only on (round 5: the filter sat behind the View glyph; at accessibility sizes, while something waits, it turns glyph and count beside the fleet's glyphs, round 95: sb#4, opus#15, one question filled the screen and the bar said only "Needs You 1"; VoiceOver hears the rest of the
   fleet after the count, round 91: sb#2); with nobody waiting, once the all-clear card has scrolled
   away, the bar's centre keeps its counts in its words, "1 done · 2 working (1 no update)", in
   footnote grey on no glass of its own, counting as numbers do, at accessibility sizes as
   glyphs and counts, the hourglass apart, as the Fleet falls back (round 93: sb#3, one line cut
   "(1 no update)" first), and nothing with nothing to count
   (round 91: opus#7, the bar went blank, so scrolled down the screen said nothing of the agents
   still running; round 92: opus#4, sb#2, sb#4, shown under the card too it repeated it in other
   words, "2 Working · 1 Done", without the quiet one); while
   it is on the chip says so ("Needs You Only ✕", as Mail's filter does) and a tap there shows
   everything again; under the rows a raised card names up to three agents the filter leaves working (glyph, title, workspace display label in Working-lane order, harness · host when needed, then step or still age, a live one's "for 1m" at its end as the Working lane's row has it, round 90: sb#4; each row opens its conversation or terminal and the filter remains on return; round 38; round 39: sb#8, sb#4; VoiceOver hears "Working" and a still one's quiet in the inbox's spoken words, "no transcript update, last one 6 minutes ago", round 49: sb#7: it read out "no update 6m"), then counts the rest by the inbox's own lanes ("2 more working ·
   1 done · 3 read not shown"; round 33: it said "done" for the Read lane) over Show All Agents (round 12: one card over an empty screen gave no sign
   of the rest). The chip counts as the Needs You header does: an inline answer whose receipt
   shows no longer waits (round 12: the header said 1 while the chip said 2 until the host
   caught up), and with only receipts left it reads "Answered". Hide and Mark as Read
   (swipes, the row's menu and bulk) offer Undo (⌘Z) for 5 s (one that comes while it shows joins it, "Hid 1 · Marked 2 read", and
   Undo restores both; round 42: sb#14, the newer replaced the older) (12 s with VoiceOver, which also announces it, or at accessibility sizes, where the message isn't capped at two lines; round 10): an
   opaque raised capsule with a soft shadow over the bottom bar (glass let the row under it read through it) ("Hid “Deploy to staging”", "Marked 3 read"), with the
   page fading in behind it, the bottom edge's fade grown to its top (round 7: rows showed cut off on both sides of it); Undo looks each agent
   up again, only while its pane still holds the same agent (its `AgentStamp`; round 10: a newcomer in the pane could be marked unread), and unhides it or marks back only those that were unread. When the last agent
   needing you on the shown hosts is answered (not when a filter or a host switch empties Needs
   You), the inbox clears in one moment (round 6: a toast, the chip leaving, the row moving and
   the all-clear came as four separate updates): while an answered row still shows its receipt
   the chip reads "Answered" in neutral (an outline check in `Tokens.secondaryText`; round 7: an
   orange "Needs You" with nothing waiting) and the lane's header too, uncounted (round 9:
   "Needs You" stood over a row already Working), and waits; as the row moves the all-clear takes its
   place and lights up for a beat (`caughtUp`) at its resting height (round 8: growing into a
   card and back moved every section below it twice): a green wash behind the row, the sheep
   signing off with the Done card's check (`HerdSeal`, see Conversation), "All answered" whatever is left to read (round 9: "All caught
   up" turned to "All answered" a beat later as the answered agent's result landed) and today's
   tally ("3 decided today · 1 done", `DecisionLog.decidedToday`), the row, its VoiceOver label and the
   announcement in the same words (round 68: opus#9, sb#4: they said "1 result to read" under "1 done");
   its sheep hops once (keyframes, ~0.3 s, a beat after the row lands, with a soft impact when
   haptics are on; not under Reduce Motion), throwing a green ring and eight dots off it that are gone in 0.8 s (`CaughtUpBurst`; round 70: opus#2: a wash and a hop were too static for the app's one celebration; round 71: opus#1–2: at 250 ms and 1.45× the burst played over the half-faded row and read only frame by frame, so it waits 450 ms and swells to 1.8×; round 15: graders found no signature moment, and the
   swell and double hop shared nothing with the Done card), the chip turns to a green check, which bounces once, and lights green for the beat (round 74: opus#1: only its words changed), status rather than a button while it says Answered or All Answered (round 75: sb#6: a button that did nothing) (not under Reduce Motion; round 17: the moment passed without notice), and "All Answered"
   (a tap does nothing) and VoiceOver hears "All answered" ("All answered. 3 decided today, 1
   result to read, 2 still working", the row's tally, which shows the working count too, even where the Working header says it (round 32: the row said less than its announcement;
   round 23; round 31: the announcement itself left out the agents at work); its counts leave hidden agents and agents being closed out, as the lanes, the dock and the Overview do (round 64: sb#1; round 65: sb#3), and so do the Needs You chip and the caught-up moment (round 65: sb#1), which plays only when an agent that was waiting is still listed: hiding or closing the last waiting one is no answer (`BlockedTally.waiting`; round 66: sb#1); 2 s later (4 s with VoiceOver) the row settles back and the chip leaves.
   At rest the all-clear is one card under no header (round 7: a Needs You header over nothing
   pushed the unread result down), on the Needs You card's raised plate in the slot the last card
   left, at one height through the moment, its wash inside the plate (round 63: sa#15, opus#3: as
   a bare row it read as one more list item): the 44 pt sheep (with its check once anything was decided today), the title in title3 semibold, "All answered" once anything was decided today,
   else "Nothing needs you" (round 10: it turned from "All answered" to "Nothing needs you" a
   beat after the moment), and what's left, as the Overview's legend sets its counts, each beside its rows' glyph and wrapping between counts, never inside one (`Flow`; round 65: opus#3, sa#4: one grey sentence wrapped mid-count): each named as its lane is and its glyphs in one width, so wrapped counts line up (round 66: opus#5, sa#5: "1 to read" over a lane called Done, two green checks side by side, a parenthesis): "1 decided today" (a grey `arrowshape.turn.up.left`), "1 done", "2 working (1 no update)", in the Overview legend's words (round 67: opus#3, sa#4, sb#5: "2 working" beside "1 with no update" read as three agents, and the iPad said it another way); decisions are those in the host sessions shown (`DecisionLog.decidedToday(in:)`, the key's leading host id and session; round 67: sb#1, another session's on the same host counted; round 66: sb#2: a decision on another host counted here, and could title an untouched host's inbox "All answered"), as in the Overview's header; VoiceOver hears "1 decided today, 1 result to read, 2 working (1 with no update)", a still one said apart as the iPad Overview's legend does, in its announcement too; round 49: sb#8: "2 working" here, the qualified count beside it).
   Its count is the one still at work, and stays current (round 4: a count
   frozen in a toast disagreed with it once an agent finished).
   While Undo shows, the list's bottom inset grows by its height so the last rows can scroll
   out from under it. On iPad the sidebar is as wide as a phone (402 pt ideal, an iPhone 17 Pro's width, 320–440), whose rows it shows (round 52: opus#11, sa#10, sb#4: at the default 320 pt titles wrapped and the last report and caution cut beside a roomy detail), but no more than two-fifths of the window, so in portrait it gives the thread the rest, as Mail's and Notes' columns do (round 70: opus#3, sa#3: near 385 pt it took about 46% of a portrait iPad). The host name is the
   sidebar's first row, and the sidebar's bar carries no principal "Inbox · studio" over it (round 54: opus#6, sb#13: it named the host twice), in a large title with the chevron (the sidebar's bar has no room for the
   principal title). An Overview row sits below the host title, its selected fill inset 8 pt as an agent row's is (round 55: opus#7: flush to the edge the two disagreed); it clears the selected route and
   is highlighted accessibly while the detail column shows Overview. **Select** (Mail-style: a
   `Set<PaneAddress>` the rows toggle, each row a button with a circle/checkmark drawn in its status glyph's place short of accessibility sizes, so no row's words rewrap as Select begins (round 73: sa#3, sb#1: a leading mark narrowed the question from two lines to three and moved every row under it), before the row at accessibility sizes, not
   `List(selection:)` edit mode; a card's answer buttons stay in place, disabled and grey, the recommendation's words in the secondary grey inside a neutral hairline rather than faded (rounds 43–44: sa#13, sb#11, opus#8, sa#3, sb#3: faded by the style and again by Select, the words sank near the background), and Other Answer… in the same grey (round 45: sa#8, sb#14: the system's faded tint left it sinking beside the readable recommendation), at its regular width under the row, not pushed over by the marks (round 72: sa#2, opus#9: indented it rewrapped and the card grew as Select began), round 25: they vanished and the list jumped under the thumb; a tap anywhere on it selects the card (round 72: sb#2: only the row above it took the tap); VoiceOver hears each row with its harness and what it says, a question without a command first, as the row shows it (round 73: sb#4), the pending question, verdict or step, round 26: only title, status and place; and "Read from the screen; may be incomplete" when the command was read off a screen that may have cut it, round 27: only the eye saw that caveat) turns the title into "N Selected", the top bar into Select All/Deselect All (⌘A)
   and Cancel (Esc) and the bottom bar into Mark
   Read (⇧⌘U), Hide (⌃⌘A, Mail's Archive; Unhide when only hidden agents are chosen) and Close (N), red, each with the number it acts on, "Mark Read (2)" counting the unread chosen and "Hide (3)" the ones not yet hidden (round 74: sb#7: only Close gave its scope); Select is ⌘E
   (round 7: past ⌘J the keyboard couldn't triage). Mark Read is enabled only with something unread chosen (round 30: on a read selection it did nothing). Select All takes
   the agents on screen (folded idle and Hidden only when opened), never shells or ended
   agents. While selecting the order is held so rows don't move under the thumb; new arrivals
   append at the end. Close asks first in a system alert ("Close 2 agents?", saying how many need you and across
   how many hosts). `BulkTriage` runs the actions one at a time in address order, looking each
   address up again just before acting (see architecture.md › UI); everything done ends
   selection, otherwise the failures stay selected under "Couldn't Update N Agents". Anything
   that changes which rows show (host, All Hosts, Needs You Only, search, grouping, sort, the
   folded sections) ends selection; Select's circles slide in with the mode (`.snappy`, a fade
   under Reduce Motion), and a selected one is a neutral filled check, primary on the page as
   Mail's and Files' are (round 12: the accent green was the unread Done glyph beside it). Rows are Mail-like with a leading status glyph (the presented status's
   symbol in its tint, so state scans down one column; no row plate, no disclosure chevron; Needs You rows and their
   inline answers share one inset rounded surface (8 pt in from the sides, card corners; `Tokens.Tint.attentionWash`: the raised surface, neutral, in both appearances, the orange glyph and the status words marking the attention; round 15: 10 % orange over black read murky brown; round 18: #2C251D a heavy brown plate and the 10 % peach one more hue beside the card's orange and greens; round 26: #262320 and a 7 % peach still read as a brown plate) and no separators, their receipts too, so the card answered becomes the all-clear card in the same slot, plate to plate (round 64: opus#1, the plate dropped at the receipt and a card came back for the all-clear, the lane reflowing twice), so each item you act on reads as one surface, round 8: it sat loose among the rest; round 9: a full-bleed wash read as a highlighted table region; the open
   row, on iPad's sidebar and while a phone pushes, takes an inset rounded fill of the faint accent (`Tokens.selectionFill`, 10 pt
   corners, as Settings' sidebar draws it) and its words keep their colours; back on the phone, the row just closed keeps it 150 ms into the pop, then fades over 0.35 s as the inbox slides in, as UIKit lists deselect on return (round 42: sb#8: the return left no mark; round 84: opus#3: held 750 ms and faded over 450, Back kept moving two seconds; round 85: opus#8, sb#9: at 550 ms and 0.3 s it still faded after the inbox was usable). Select begins and ends in a 0.3 s snappy spring (round 84: opus#3: the default settled in 850 ms). The composer's attach, dictate and send buttons, the sheep and the terminal's keys keep their size at accessibility sizes and show the Large Content Viewer on a long press (round 84: opus#8), as do the thread's Terminal and More and the terminal's Type and Read as Text (round 85: sb#8), and the pushed screens' titles, which the bar holds near the standard size (round 95: sb#3). Rows are buttons that set the scene's route, not selection-bound links: `List(selection:)` painted a full-bleed slab and turned the words white, and no tint or prominence override undid it;
   working rows turn their dotted ring slowly, one turn in about 4 s, still under Reduce Motion: a row at
   work reads as live at a glance, where the still ring passed for idle; once it has gone still, "no update 6m", the ring gives way to an hourglass in `Tokens.secondaryText` (`AgentStatus.stillSymbol`; round 33: the stopped grey ring differed from the live one by colour alone), in the dock, the Overview and Panes too, where its status word greys with it, and the thread's and terminal's headers say "Working · no update 6m" in grey, the terminal's in place of the directory (round 32: with it, the subtitle pushed Type and Read as Text into an overflow menu), counted on the minute as the sidebar counts it (`BarTitle.still`; round 92: sb#1, worked out once on opening, the terminal said 6m beside the sidebar's 7m) (round 31: Panes and those headers still said blue Working; round 30: the live blue ring beside "no update" overstated it): the unread dot in its own gutter inside the row, before the glyph, as Mail's is (it hung in the margin until round 3), and in Mail's blue (`Tokens.Tint.unread`; round 27: in the accent green it was one more meaning of green, beside Approve, Recommended and Done, and led an orange waiting glyph),
   conversation title (terminal title minus the agent glyph
   prefix; semibold while unread; two lines before it truncates, round 45: sa#6, sb#10: the iPad sidebar cut "Token-bucket rate lim…") with the last turn's age at the trailing edge in footnote, caption at accessibility sizes (round 79: sb#6: there it weighed as much as the question it dates) ("5m ago" in inbox rows and the dock's, `AgentRow.ago`, so it reads beside "waiting 4m" and "for 1m", round 56: opus#5, sb#13; round 57: sb#6, the dock's stayed bare; the Overview's Recently Finished too, at the end of its title line, round 58: sb#14, sa#6, its bare "5m" in a column of its own before the rail narrowed the results; a
   weekday within the week, then the date, with its year once it isn't this one (round 94: sb#4); counted in whole clock minutes, so the sidebar and
   the Overview, ticking a few seconds apart, never disagree; VoiceOver hears "last turn 5
   minutes ago", not a bare "5m" that could be the wait), "status · workspace" (just the workspace
   when grouped by status, round 6: the section header already says it; VoiceOver hears it after
   the title; the Hidden fold mixes statuses and keeps the word; then the harness, "Claude",
   "Codex" or "OMP", when the inbox mixes them, round 8: nothing told them apart, though not at
   accessibility sizes, round 9: it wrapped to an orphan "· OMP"), the pending question when
   herdr's prompt has been read (a question leads the row in body semibold, up to three lines,
   its age trailing, and whose it is, "Deploy to staging · web-dashboard · OMP", goes under it
   with the title in primary medium, on one line while it fits, else the title over the rest so
   the workspace isn't cut (round 71: sb#1) and the harness stays (round 75: sa#8, sb#10: the iPad
   sidebar's row dropped "OMP" to keep one line, a step round 72 added while Select still narrowed rows), as Mail's subject line and the Overview's card lead
   with what's asked (round 70: sa#2, raised twice); in the iPad sidebar and at accessibility
   sizes too, where the question follows the state line and the title joins its place in
   footnote (round 72: opus#2, they led with the title while the phone led with the question),
   then the title, where it runs and the harness a size down, hyphens unbroken ("web‑dashboard";
   round 75: opus#6: "web-" broke from "dashboard"; round 76: sb#1: round 75 hid the title and a
   sighted reader couldn't tell whose decision it was, which outweighs Working falling below the
   first screen; round 74: sb#4: the harness stays); an answer's
   reason whole at every size, "Recommended ·" leading it at these sizes (round 75: opus#5: without
   the word only the green edge said it; round 74: sa#3, sb#1, opus#3: two lines cut the condition
   being agreed to; round 75: sb#5: at regular sizes too), and a preview under it in monospace
   (round 75: sb#3: only VoiceOver had it);
   not an approval, whose "Allow bash?" says less than the task and belongs beside its command
   (round 71: sb#7, opus#4); VoiceOver hears the question, then the title; the Other Agents
   sheet leads its question rows the same way, the question heard first (round 71: sa#4,
   opus#8), every row's age trailing its first line as the inbox's does, "no update 6m" left
   in the place line (round 72: opus#5, sa#3, sb#14: at the end of the place it wrapped to
   "waiting 5m" alone); for an approval, its title, then the command itself on its own
   line in subheadline monospaced, the row's text size (round 61: sb#5 r60: in footnote it was quieter than the question), up to two lines, without the harness's "Command:" label; round 6:
   "Allow bash? bun test …" ran the command into the question; when herdr read it off the screen
   and it may be cut short, "Read from the screen; may be incomplete" follows it in footnote medium, primary rather than grey, behind the caution triangle in `Tokens.Tint.caution` (`ScreenReadCaveat`, in the thread's card, the inbox's and the decision's record after it, round 82: sb#9, opus#6: the record kept a grey viewfinder; round 81: sa#4: with a viewfinder glyph it read as small print beside the mint Approve; round 76: sb#9: grey read as incidental beside Approve; round 73: sb#8: "Command may be shortened" didn't say where the doubt came from; round 16: caption read small on the wash; round 23: "Command shortened" claimed a cut on a command shown whole) with a `text.viewfinder` mark (round 74: sa#5: scissors implied a known cut) at the
   words' size, close to it (`.caveat`; round 8: the default label drew it twice the words' size; round 7: the bare mark didn't say what it meant; round 14: "May be cut short" read as jargon), VoiceOver hears it too,
   and Inspect in Terminal, an inline action right above the answer buttons (round 23: under them it invited a decision before a look; round 25: "Full Command in Terminal" promised more of the command than a terminal screen may hold), opens the terminal, round 6; round 16: in the row's "…" menu it read as missing; round 17: "View Full Command" promised a view of its own), else (Settings › Conversations › Message Previews, on by default; a result already read keeps its verdict line too, round 24: title and place alone, which round 17 chose to fit more read agents above the fold, couldn't tell "No blocking findings" from a failure; a result that ends in a bold warning or
   deploy callout leads with it, above the verdict (round 49: sa#1, sb#4: under "No blocking findings" it read as a footnote, in the order the dock and VoiceOver had already dropped), its first sentence only, the thing to do (round 54: opus#3, sb#10: "I left the working tree unchanged" took a third loud line in every row; `TranscriptActivity.caution`; the result card likewise moves only that sentence above its verdict and leaves the rest as the body's last paragraph, round 55: sa#1, sb#5, which, as any short closing remark straight after a list, the card sets as a grey subheadline postscript, footnote at accessibility sizes, unless it holds something to act on (a link, code, a path or a question; round 86: opus#6: "Ready for a quick browser check at https://…" went grey), round 85: sa#1: at the findings' weight the card read as one block; at accessibility sizes the closing time line is in caption, round 86: sb#8), a yellow `exclamationmark.triangle` (`Tokens.Tint.caution`, darker in the light; round 78: opus#7: in Needs You's orange a read result looked like an agent waiting) (in the inbox row hung in the status glyph's column, so the caution's lines share the title's and verdict's edge, round 57: opus#9, wrapped under the icon they left the row's edge ragged; VoiceOver hears "Warning: …" wherever a caution is shown, inbox at every size, dock, quick switch, Overview and Select, `AgentRow.spokenCaution`, round 58: sb#4) and grey lines at the verdict's size, subheadline (round 53: opus#7, sa#2, sb#2: in footnote under the verdict the thing to do read as fine print; the Overview's Recently Finished likewise), its lead
   ("Before deploying:") semibold in primary (round 51: sa#6: all grey it sat under the verdict's weight) (round 42: sa#2, sb#4, opus#5: one line cut it at "existing rows…"),
   as Recently Finished does, `TranscriptActivity.caution`, round 41: sa#1, sb#1, opus#2: "No
   blocking findings" hid "apply 0042 first"; the dock shows its words in place of the verdict, after the same yellow triangle, as does an inbox row already read (round 65: opus#4, sa#2: a read row with caution and verdict stood as tall as the one asking; VoiceOver still hears the verdict after the warning), in up to two lines, its lead in primary and the rest in the app's grey as the inbox sets it (round 59: sb#9, all at 75 % it sank in the glass), and VoiceOver reads both, round 42: sb#2; round 43: sa#7, sb#2: a triangle before the verdict didn't say what to do) one
   line of the newest user/assistant text, from the transcript tail the inbox already reads for
   recency (`TranscriptActivity.preview`, ≤140 chars, a longer one ending at a word with "…", round 8: it stopped mid-word; Markdown list, heading and quote markers dropped and list items joined with " · ", round 6; bold and code-span marks dropped, round 17: "**Move:**" showed literally), at secondary contrast; where a result has one line (the inbox's rows, the dock's Read rows) it ends at its opening sentence when a list item follows (`TranscriptActivity.verdict`; round 28: "No blocking findings in PR #412. · Move: the…"), a heading-like lead keeping the whole line; a pending question is primary. A working row shows instead what it's running now, in its thread's Now line words ("Running bun test src/limits/refill.test.ts"; `TranscriptActivity.step`, the newest unanswered call, a bare `wait` excepted), whatever the setting, as status rather than message text (`HostConnection.rowLine`, for the dock and the Overview too; round 15: Working rows showed narration from minutes before; with no step known it says nothing rather than fall back to narration, and once the agent has gone still the step reads "Last reported: Running bun test …", round 25: a present-tense step beside "no update 6m" claimed work still under way). A live step is set in primary over the grey place line, a quiet one's "Last reported:" stays grey, on two lines as the dock gives it (round 52: sa#7: what it's doing now sat level with "api · OMP"; sb#11: the iPad sidebar cut the command after the prefix). A result's caution takes up to three lines, which only a column narrower than a phone's uses (round 52: sa#10). A blocked row's age counts from its question (`TranscriptActivity.activityAt`, the newest record): "waiting 46m", "just asked" (round 15: a bare "46m" from the turn's start); at accessibility sizes it goes under the status word when both don't fit on one line. A working row shows no age (`HostConnection.ageDate`): its last turn may be a prompt or an earlier turn's end, and a bare "1m" there read as how long it had run (round 18). It says how long it has been at it instead, in the trailing slot, "for 12m" (on its dock row at the end of the place line), counted from its turn's message or its going back to work after an answer, if later (`HostConnection.workingSince`; nothing under a minute; VoiceOver: "working since 12 minutes ago"; round 44: sa#5, sb#4, opus#5: a two-minute run and a two-hour one looked the same); once gone still, "no update 6m" takes its place; its thread's subtitle says that ("Working for 4m"), counted from the agent going back to work after an answer when that's later (`HostConnection.resumed`; round 43: sa#3: just approved, it read "Working for 46m"). Once its transcript has been still for 5 minutes, an inbox working row says so at the end of its meta line, as its dock row does, kept whole while the place gives way (round 23: at the trailing edge it read as an age and cut the iPad sidebar's "Backfill March o…"; the place is the part of that line that truncates, the harness and host after it stay whole, round 24: "data-pipeline · C… · no update 6m"; where the line can't hold it whole, it takes a line of its own under the place, round 25: "Claude · no up…"), "no update 6m" from its newest record, or from when it last went back to work if that is later (`HostConnection.stillSince`: an approval, an answer or a new turn; while an inline answer's receipt shows, nothing; round 24: a row just approved said "no update 45m") (VoiceOver, there too: "no transcript update, last one 6 minutes ago"; round 43: sb#5; round 22: "quiet 6m" didn't say what had gone quiet; round 21: the dock showed it unspoken; round 20: a stalled agent looked exactly like a busy one); it says nothing of the terminal, where a long command writes. At accessibility sizes nothing
   truncates, the title has its first line to itself and the unread dot and a subheadline-sized status glyph
   lead the meta line under it with the status word, which shows there whatever the section
   (round 11: beside the title they took a quarter of its first line; round 12: "● ! 5m" said
   at accessibility sizes, the title normally leads; a waiting decision instead reads the status
   (glyph with "waiting 4m", or "Needs You" without an age), title, workspace and harness in
   footnote ("web-dashboard · OMP", unless the row is already under its place header; round 21:
   an answer could be given before seeing which workspace asked; round 22: at the question's size
   it pushed the answers down), question, each option's explanation and button, then a one-line
   "Other Answer…", the one name at every size and on the thread's card (round 31: "Write Your Own Answer…" beside "Other Answer…" named one action twice; round 23: two lines of "Write Your Own
   Answer…" ended under the bar; round 20: the state followed the question, the action preceded
   its caveat, and writing an answer fell below the fold). VoiceOver follows
   the same order. The command and question stay under the title, and the answer card starts at
   the row's edge, as it does at every size (round 39: sa#3, the title's gutter indented it); receipts, lone option descriptions, thread decision lines, sent pills and dock
   titles drop their line caps there too. Sections are compact with sentence-case headline headers,
   as in Reminders ("Needs You 1", the count `Color.secondary`: the hierarchical secondary
   inside a header dims twice; tiny caps until round 3; a status section of working agents adds how
   many have gone still, "Working 2 (1 no update)", as Overview's legend and the dock's lane say it,
   round 76: sb#5, opus#9: the inbox said "Working 2" beside Overview's "No Update"), growing no further than the first
   accessibility size (round 29: at Accessibility XL the header and the card left Other Answer
   in the bottom fade), 4 pt under the bar there rather than 16, and an answer tile 8 pt closer
   under its row, so Other Answer clears the bottom fade on the first screen with every line
   whole (round 77: sa#3, sb#3, opus#7: restoring the title in round 76 pushed it back); at those sizes the inbox scrolls 160 pt further, so the card's last
   answer can rest above the bar (round 39: opus#15, sa#4, sb#6). A status or
   workspace header counts its idle rows too, so it matches the rows under it (round 6). Headers
   are no taller than their line (`defaultMinListHeaderHeight` 0, 16 pt above, 4 below), the
   list adds no gap of its own between sections (`listSectionSpacing(0)`; round 7: ~40 pt from
   a section's last rule to the next header), nor above the first (`contentMargins(.top, 0)`;
   round 21: ~50 pt of nothing between the title and Needs You), and rows
   pad 3 pt inside the list's insets (round 6: ~45 pt between a header and its first row left
   little above the fold). Secondary words that carry information (a row's place, time and
   preview; the dock's captions; a tool call's line and the Done time; since round 7 also
   option descriptions and previews, decision receipts, the catch-up line, the Overview's
   captions and the link status, which still used the system's) use
   `Tokens.secondaryText`: #B8B8BE in the dark (#D1D1D6 with Increase Contrast), #55555A in the
   light (#3A3A3C), where the system's ~3.5:1 read as faint (round 6; round 14: still a grey layer
   that took effort, so both appearances went up a step).
   Under Needs You Only the Terminals and Ended folds are left out. Rows scrolling under the top and bottom bars fade into
   the page (`edgeFade`, which replaces the system scroll edge effect there: on the simulator it
   left words readable under the title as a dimmed second layer); at the inbox's foot the page is solid under the bar and any toast and fades over only the last 12 pt of the room above the bar, rather than 16 pt past it (round 24: rows faded out in space above the controls where they could have been read); the iPad sidebar keeps the
   system's, its page isn't the plain background. Agents with a transcript open the
   conversation; others open the terminal. The magnifier (or ⌘F, when no conversation is on
   screen, which from a terminal returns to the inbox first, round 40: sb#1; there ⌘F is Find in Conversation, ⌘L Write Message puts the keyboard in its composer (round 46: sb#5: the keyboard triage loop stopped at a custom reply), as it does in a terminal's line composer (round 67: sb#3), and ⇧⌘F, Search Agents, returns to the inbox and
   opens its search, round 12; round 14: it set the flag behind the pushed thread) opens a search
   bar, "Search agents" (round 12: the placeholder listed its four fields; round 14: "and
   messages" promised a conversation search), over title, workspace, folder, host, the harness ("Codex"), the status as the row says it
   ("Needs you", "Done"; round 27: neither found the row that showed it), the pending
   question, a working agent's step (round 28: the command a row showed found nothing) and the latest message line (with previews off too; the hint says so);
   the magnifier turns into ✕, which
   closes and clears it. While anything shared from another app is unsent, a "Shared · N" row
   tops the list (see architecture.md). With no rows, the Herdwick sheep (`HerdMark`) over "No agents yet" and New Agent (or "All quiet" under Needs You Only) appears only
   once a host is live ("No agents on the connected hosts" while others aren't); while the
   first attempts run, the per-host status lines are all it shows, and once every host is down
   (failed, offline, or retrying after a failure) it shows "No hosts connected" with Add Host.
   Its sheep wears its mood (`HerdMark.Mood`): a dim "z" under Needs You Only, the prompt and
   cursor otherwise; the Overview's header sheep shows "?" while an agent needs you and a
   blinking cursor while any work. Under 60 pt the face is too small for a glyph, so waiting,
   quiet and done sit in a badge at the sheep's lower trailing corner instead (an orange
   exclamation mark, the app's Needs You mark, round 40: opus#10, a yellow "?" beside cards marked "!"; a grey moon, a green check; round 22: the dock's "?" was a few pixels). The
   dock's sheep hops once, its badge with it, when another agent starts waiting while the thread
   stays the same (not under Reduce Motion; round 78: opus#5: nothing reacted as the badge
   changed), and VoiceOver hears who by name and where, "Deploy to staging in web-dashboard needs you, 2 waiting besides this thread", with "on <host>" when the inbox spans several, each named so when several arrive at once (round 81: sb#3: "another agent" said nothing of which; round 82: sb#6; round 83: sb#7), without
   focus moving, the sheet open or not, whenever a new agent joins those waiting, not only when the
   count grows (round 79: sb#2; round 80: sb#1, sb#2: one answered as another asked was silent).
   Every other agent read and at rest, it dozes, the grey moon at its corner (round 80: opus#2). The dock's sheep shows no "?": its count badge says someone waits, in dark ink on the orange (round 75: sb#2: white on orange was the least legible count) (round 23: both at once on
   28 pt read as a fussy cluster).
   Reduce Motion holds every mood still.
   On iPad, with no conversation selected, the detail column is an Overview (`OverviewView`,
   round 2; it had been an empty "Choose a conversation"): "2 agents need you · 3 working · 1
   result to read · 4 decided today" (round 9: "All quiet" over unread results; an agent whose
   answer shows its receipt no longer counts, as in the inbox's chip, the dock's badge and Next
   Needs You, through `SceneState.needsUser`, round 14),
   a card per waiting agent with its question and command as the inbox row says them (the
   newest turn first, as the inbox orders Needs You; every one, round 7: five and no "more") and
   the same answer in place (`InlineApproval`; round 6: the card repeated the
   sidebar's question with no way to answer it). Answers live in the window's `InlineAnswers`
   (`SceneState.inlineAnswers`), so a card and its sidebar row show the same "Approving…" and
   receipt, and the card stays until the row moves on; with only receipts left its heading reads
   "Answered", as the inbox's lane does (round 10: "Needs You" over cards already answered).
   The iPad sidebar's Needs You rows never carry the answer, with the Overview or a thread open,
   so a row keeps its height whatever the detail shows (round 11: both columns drew the same
   card; round 14: opening a thread grew the waiting row into a full card beside it); its "…"
   menu and swipes still answer. The page is for triage, not a second sidebar (round 33: every
   grader found its Working and Read lists repeated the sidebar's lanes at greater height; round
   20: the detail column duplicated all six sidebar agents): waiting cards, led by the question
   in headline with its age and chevron, the agent's title and place under it in subheadline
   (round 68: sa#3, opus#1: led by the title, place and age, a card copied the sidebar row
   beside it), two abreast on a
   column wide enough for two 400 pt cards; then Working, headed as the inbox's lane, "Working 2 (1 no update)", a tile per working agent, live or gone still (round 85: sa#4, sb#6: with only the still ones here, since round 33, the live agent was a number in Fleet and its step only in the sidebar's one line); beside the sidebar, which lists them with their place, step and age, short of accessibility sizes, none: the header's legend
   and the Fleet keep the count (round 94: opus#4, sa#7, sb#6; round 90 had made it one raised card of two-line rows, opus#2, sa#3, sb#11,
   a tile apiece repeating the sidebar at twice its height, and the rows were still the sidebar again); a tile is
   on the result rows' template: the turning ring, or once gone still the grey hourglass, in the leading column, the title with "for 1m" at its end, or "no
   update 6m" once still (round 86: sb#4: only the still tile said how long), as a result's age ends its title, and a chevron (round 31: the tile
   alone had no chevron and kept "no update" on the place line; round 29: the place above the
   title read the same object two ways), then the place, then its step, in primary while it reports now and grey once it's what it last reported, the title
   and step keeping two lines each so tiles abreast match (round 24), whole at accessibility
   sizes (round 25; round 60: sb#4 r58, a 20-line cap stood in for "whole"); then, side by side where
   two 340 pt columns fit, **Recently Finished** and after it the Fleet (below) (round 56: sb#6, opus#13: in portrait the Fleet pushed the results to read below the screen; round 36 had the opposite order, when the results pushed the fleet off) — **Recently Finished** (titled "To Review" beside the sidebar, which holds only what is still to
   read there, round 91: sb#5, "Recently" promised a list it filters; a read one there, kept for its caution, says
   "Read · 45m ago" where its age goes, round 94: sa#6, sb#5, it sat under "To Review" while the sidebar called it Read; when every one there is read, the
   title is "Follow-Ups", round 95: sa#5, sb#8, and VoiceOver hears "Read" as it shows, round 95: sb#1) (round 35: a Done section and a Recent Activity
   list, which restated the Needs You and still-work cards, showed one agent up to four times):
   the finished agents with a verdict, newest first; beside the sidebar only the unread ones and those ending in a caution, the other
   read ones being its Read lane (round 63: opus#1, sa#3, sb#8: three read results in both
   columns pushed the Fleet below the screen; round 90: sb#9 r88: a read result's "apply 0042 first" stood only in the sidebar's one line); the
   status glyph on a rail to the next, the title (semibold while unread) with the age at its end as the sidebar
   says it ("45m ago", "3h ago"; clock times beside "waiting 4m" left the reader to do the sum; round 58: sb#14, sa#6, a bare "45m" in a column before the rail narrowed the results), its place (round 36: a reused title was
   ambiguous) and three lines of verdict, two once read (whole at accessibility sizes, where the age leads the words and the rail goes),
   any closing warning before it as the inbox row shows it (round 50: sa#4, sb#1: it came after the verdict here alone; VoiceOver hears it first too), the verdict then its opening sentence alone in up to two lines (round 41: sb#1;
   round 42: sb#4; round 43: sb#8, opus#6: it ran on into the first point and was cut); five,
   then Show All. VoiceOver hears unread, title, place, status and age. The verdict, its opening sentence
   (through the next when the first is only "Fixed." or "Done."; round 32: the bare
   acknowledgement was the brightest line), in primary and the rest in secondary, each list item
   on a line of its own (`TranscriptActivity.opening`; rounds 29–31). **Fleet**, what the
   sidebar can't say: a card per host in scope, one with no agents too ("No agents"; round 35:
   it had no card), its link status when it isn't live (else its agent count), a bar of its
   agents by state (needs you, working, no update, done, read; the no-update segment an outline in the working blue, part of the legend's working count rather than a state it doesn't name (round 86: sa#6: a grey outline),
   read a faint fill) with a legend that wraps, in the bar's order and counted as it is, each
   agent once ("2 working (1 no update)"; no-update is nested in the working total), then each
   workspace, where the work is, with its counts by state as glyph-and-number pairs (needs you,
   working, no update, done, read; round 38: a glyph per agent grew without bound); VoiceOver
   hears "web-dashboard: 1 needs you, 1 read". Section titles are headings (round 35).
   Each host card is a contained accessibility group: its name and agent count/link are one header, its bar and legend one concise summary, and each workspace a separate element (round 36: reaching one workspace meant hearing the whole host).
   The header leads with what needs you ("1 agent needs you", or "All quiet") over what was decided
   today ("3 decided today"; round 22: a generic "Your agents" title), then the whole herd by state in
   one bar across the page with its legend under it ("1 needs you · 2 working (1 no update) · 1 done ·
   3 read"; round 31: "2 working" counted one six minutes silent), the aggregate at first glance
   (round 62: opus#2, sa#4: the fleet's bar sat at the page's foot under the results). With one
   host in scope its Fleet card keeps its name, count and workspaces and leaves the bar and legend
   to the header (they were the same bar twice); beside other hosts each card has its own. When no
   agent needs attention and there are no unread results or active work, the header remains a calm
   all-clear.
   VoiceOver hears "Unread" on every Overview item and dock row not yet read, as on the inbox's
   rows (round 27: only the filled check said it; round 28: the waiting card and tiles didn't),
   and a dock approval whose command may have been cut adds "Read from the screen; may be incomplete" (round 28).
   Fleet rows are ruled apart, 8 pt above and below each (round 78: sa#8: 8 pt apart and unruled they read as a packed table). Fleet summaries keep the counts in the legend's order, in its words ("1 needs you", "2 working (1 no update)", "1 read") while they fit beside the workspace's name, else as glyph and number, the still ones in parentheses after the working total, and when every working agent there has gone still, the grey hourglass in place of the blue ring (round 77: sb#7: the live ring stood over agents with no update; round 69: sa#7: bare pairs had to be matched against the legend; round 70: sb#5: "1 no update" counted apart beside the header's inclusive "2 working (1 no update)");
   a waiting card's VoiceOver label is its question, then its command, whose it is, and its state, place and age (round 69: sb#1: the title, status, place and age came before the question); the visual bar is hidden from VoiceOver rather than repeating them.
   Section titles are the inbox's ("Needs You", `AgentStatus.section`; round 28: "Needs you" here).
   The first unanswered Needs You card uses the shared numbered answer shortcuts only while the
   Overview is visible; with a conversation selected the sidebar has no inline answer owner.
   The iPad sidebar starts with an Overview row; selecting it clears the detail route and returns
   to this surface, with selected styling and a VoiceOver label. The existing keyboard command
   remains available.
   On iPhone a thread pushes from its inbox row; going back, that row shows as open while the
   thread slides off, fading as the inbox slides in, as UIKit lists deselect (round 42: sa#4, sb#8,
   opus#4: the zoom out of the row, added in round 39, took 550 ms against a push's 380 and
   scaled the whole transcript on the most repeated move).
2. **Conversation**: transcript rendered as chat (16 pt side insets, 24 on a regular-width
   iPad, the transcript and composer in one centred column at most 720 pt wide,
   `Tokens.readableWidth`; round 36: lines ran a wide detail's whole width); pending ask as native cards above the
   composer, on a material surface so the transcript doesn't show through when scrolled beneath;
   composer (`pane.send_input`, text + `enter`). Title = transcript title or agent (a name
   Herdwick generated to start it, "omp-e03b45", ranks below the agent's terminal title, and
   until either names it the thread goes by its first user message; round 20),
   subtitle = status text + workspace (the presented status, the inbox's word, in its
   status tint, round 8: untinted it was the faintest thing on screen; after a sent message
   and before the agent starts, "Sent · workspace" in the secondary tint (round 21: "Done"
   beside "Sent · waiting for the agent to start" disagreed); while working, the
   time since the user's message that started the turn, "Working for 4m · studio" (round 18: "Working · 1m" read as an age beside the inbox's), from a whole
   minute and only while no reply has ended that turn; round 5; waiting, the inbox row's own
   words and clock minutes, "Waiting 4m · studio", round 19–20: "Needs you for 3m" cut the
   workspace and counted minutes apart from the inbox; VoiceOver hears its ages in words, "Waiting 4 minutes, studio", `BarTitle.spoken`, round 50: sb#4: "4m" read as four metres), both in
   `BarTitle`: a leading toolbar item without the shared glass, right after Back (round 4; the
   system's inline title centred when it fit and moved to the leading edge when a longer status
   didn't, so answering an agent made its title jump across the bar, and a principal item still
   centred on iPad and in the terminal). The bar offers a leading item almost no width, so it takes
   its own, truncating only past the room Back and the trailing buttons leave (204 pt here, 148
   in the terminal). Title in headline with no subtitle, else semibold subheadline over a footnote
   in `Tokens.secondaryText`, with a medium-weight status word (round 36: the supervisor's status
   was smaller than the body); one line where it fits, two at accessibility sizes
   (round 5: headline over subheadline cut titles the system title had fitted). The terminal uses the same. While the host is (re)connecting, this and a
   subagent's thread show the link status ("Reconnecting in 4s") once, as a material pill in the
   layout above the transcript (not over it), the page solid under the pill's full width like the bar's, fading only past it (round 89: opus#3, sa#8: faded through its lower half, round 86, or all of it, round 85, the row behind showed its ends either side of the glass), slid in after 0.5 s so brief blips don't flash it;
   between attempts the pill has Retry Now (drawn slim, hit-tested across 44 pt; the pill fades rather than slides under Reduce Motion). Under the status, in caption, "Last updated 9:41": when the host last answered, a snapshot or an activity read (`HostConnection.heardAt`, copied to `lostAt` on leaving live; round 7: the offline copy didn't say how old it was; round 8: it gave the disconnect time, which could postdate a stalled link's last answer). The subtitle then keeps to the workspace, since the
   last status may be stale. The transcript fades out under the title (`edgeFade`). With nothing cached the thread says "Not connected" rather than that the transcript is unreadable, and that it loads when the host is reachable again (round 6: the draft is offered by the pinned line and the placeholder, not a third time); under it, what the inbox last read of the agent stands in for the copy it hasn't got: "Last turn 45 minutes ago" over its newest line in quotes, up to four lines (round 6: the screen was otherwise empty). While the host is away (or the thread is the offline copy) the composer still drafts: the field and dictation stay open, its placeholder reads "Write a Draft", and once there is text the pinned line's slot says "Draft saved · Tap Send once reconnected" (round 89: sb#10: "Send once reconnected" could read as a promise to send it later; nothing queues) (two lines at most, whole at accessibility sizes, round 88: sb#7) (round 38: an empty draft's "Offline · You can write a draft" under the reconnect pill said the link was down twice; round 5: it said saved before anything was typed; round 4: the old "Offline · Draft to Send Later" placeholder beside the dimmed Send read as a disabled field), the draft is saved as always, and Send and + wait for the host (the field's VoiceOver Send action is offered only while Send is enabled; round 33: it reported success while nothing could be sent); VoiceOver names the recipient, "Message to Review PR #412, web-dashboard" and "Send to Review PR #412, web-dashboard", the host too when several are shown (round 71: sb#6: switching among like-named agents, "Message" and "Send" didn't confirm whose; round 72: sb#1: the title alone couldn't tell two workspaces' apart); the placeholder is `Tokens.placeholderText`, a step under the app's secondary text (round 72: sb#13: at the system's secondary label it read faint in light); only a thread without an agent locks the field. A sent message's bubble goes in with the scroll to it, the field emptying in the same frame: one 0.3 s `.snappy` glide that carries the card above up with it, the bubble rising out of the composer (`sendMotion`; none under Reduce Motion; round 45: sa#1, sb#6, opus#2: placed without animation the transcript jumped about 45 pt in one frame while only the bubble rose 18 pt by itself). The opening's room below the end (`restInset`) and the top veil clear in that same update (round 19: they cleared once the send returned, so the transcript rose 25 pt too far and dropped back a frame later) and in the same glide: the room is the transcript's bottom padding, not a content margin (round 69: sa#6: a margin went in one frame, and the transcript dropped by it before the glide carried it up). Round 10: the bubble's own insertion animated as well spent ~100 ms below the edge; round 9: a 60 ms fade; round 7: rising from the bottom edge, under the composer's fade, it took ~130 ms to read. Under it, trailing in footnote, "Sending…" while it goes, then "✓ Sent · waiting for the agent to start" until the agent works, asks or writes back (`handedOff`), the words swapped in place (round 17: crossfaded, the two drew over each other) and VoiceOver told "Sent, waiting for the agent to start" once; the header keeps the host's status, never claiming Working early (round 16: the bubble appeared under a header still saying Done, with nothing to say it had been delivered). Toolbar: Terminal, then (spaced apart) a More
   (`ellipsis`) menu: first, while another agent needs you, "Next Needs You: Deploy to staging"
   with its place as the item's subtitle, as the dock's action says it (round 69: sb#7) (round 68: sb#2: at accessibility sizes Next is the transcript's last block, a long result
   away); then a row of places side by side (a `ControlGroup`: Find, then Images and
   Changes when there are any), so a slip lands on a visibly different neighbour, not the next
   look-alike text line; then iconed, named submenus: View (Messages and Steps / Messages Only), Session (the
   harness and the session's model, "Claude · claude-sonnet-4", with Session Details; round 9:
   the harness in the subtitle pushed Terminal off the bar), Show Live Activity, "Why <status>?"), Mute
   Notifications; then, as the inbox row's swipes offer them, Mark as Unread (a read, finished
   agent) and Hide, each going back to the inbox, where a Hide offers Undo as one from the row
   does (`SceneState.hiddenFromThread`; round 61: sb#1 r59, putting a reviewed agent away meant
   going back first), on the inbox's keys too, Mark as Unread ⇧⌘U and Hide Agent ⌃⌘A in the Inbox
   menu while a conversation or the agent's terminal is on screen (round 65: sb#7: in its terminal they were gone) (`SceneState.markUnreadRequest`/`hideRequest`; round 62:
   sb#2, the keyboard triage loop stopped at the thread), not while the iPad sidebar's Select mode
   holds those keys for its Mark Read and Hide (`SceneState.inboxSelecting`); then Retry Last Turn (omp Alt+R, only after a turn ended in an error) and Stop
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
   Find searches the loaded messages only (its field says so), steps newest-first, shows Messages and Steps
   while a match is one Messages Only hides, and opens the run holding a match. While omp works the composer's + menu offers Send
   After This Run (typed into omp's editor, then Ctrl+Q queues it as a follow-up).
   While offline or reconnecting, the last agent status stays on screen (round 39: opus#11), rather than dropping it as stale, as "Last known: Done" in grey (round 41: sa#8, sb#6: a bare "Done" read as current): in the reconnecting pill, "Last known: Done · synced 12:32 AM" under "Reconnecting in 8s" (round 44: sb#14, opus#2: "Done at 1:14 AM" over a result done at 12:29 read as its finish; the time dated as the transcript dates its own, "Tue 11:29 PM" once not today, round 95: sb#2), with the subtitle keeping the workspace whole (round 43: sa#4, sb#4, opus#5: "Last known: Done · web-das…" cut it); in the subtitle when the host has failed and no pill shows.
   **Agent dock** (`AgentDock`): one 44 pt glass button, the composer's round-button size,
   standing over Send in the composer's trailing column, as the mic stands over +. The pinned Now
   or catch-up line sits over the field between them. On an agent's
   terminal it stands over Send too, and ends the keys' row while typing
   mode hides the composer. The bar reserves the slot
   (`AgentDock.slot`, an anchor preference) and the dock's own layer over the thread draws the
   button there. A tap opens the system sheet of the other agents (round 45: sa#2, sb#7, opus#3:
   the hand-drawn glass panel over a frosted thread read as an expanded context menu): on a phone
   it zooms out of the button (`matchedTransitionSource`, `.navigationTransition(.zoom)`) at the
   height of its lanes, measured (a guess from the rows before they first lay out, refitted once
   they do), up to large (round 79: opus#2, sa#6, sb#5: a row-count rule opened it a third blank;
   round 78: at medium it ended inside a Read row; at accessibility sizes the large one only; round
   77: sb#6: half a screen cut the lanes under Needs You off), drags to large, and has the grabber, on a thick material rather than the half-height sheet's clear glass, so the thread's words don't ghost behind the names (round 73: sa#5); on iPad (regular width) it is a popover
   pointing at the button, 400 pt wide. Send stays its own
   button: an agent can need the user mid-draft. On iPad with the sidebar beside the thread (`SceneState.sidebarBeside`, from the detail column's position) there is no dock: the sidebar already lists every agent (round 36: two switchers side by side). It is about keeping agents busy, not
   tracking them: one conversations glyph in primary, with an accessible "Agents" label and a
   value counting only agents that need you; the visible badge uses that same decision-only count,
   in the thread's tint (orange Needs you; an answer showing its receipt no longer counts, round
   14; grey, and "last known" in the value, when every waiter's host is out of reach, round 82: sb#3:
   a live orange 1 sat over an offline thread; drawn outside the glass container, which would composite over it; left off while the thread's
   Next line offers the next agent with its count, round 6). The button's accessibility hint explains
   that it shows agents to switch to, and while another agent needs you its actions include "Next Needs You: Deploy to staging, web-dashboard" (where too, as its rows say it, round 51: sb#1), ⌘J's jump (round 50: sb#6: at accessibility sizes the Next card is the transcript's last block, a long result away). The sheet's inline title is "Other Agents" (it lists every agent but the thread's; round 33:
   "Agents" over "Read 2" beside the inbox's "Read 3" didn't say so; round 35 dropped the
   header's "1 needs you", which the lane under it said), with the system Close button at its
   trailing edge, where Panes and Settings have theirs (round 81: opus#8: leading here, trailing in Panes, Done in Settings), and lists the other threads in the inbox's scope, Hidden and Ended left
   out. Settings › Conversations › Agent Dock turns it off (the pinned line then sits over the
   field alone). Its order is fixed (the Dock Order setting is gone), in labelled lanes: Needs
   You, then Done (round 4: one "Needs attention" lane mixed asks with finished turns; within
   each the inbox's order, the newest turn first, `attentionPrecedes`, so the dock, Next and ⌘J
   agree with the inbox; round 7: herdr's `state_change_seq` gave a third order, comparable
   only within one session), then Working, then Read (results already read; each the latest turn first, `latestTurnPrecedes`).
   Same as Inbox uses the Agents list's grouping and sort under a leading Needs You. The first
   row that wants the user is set apart (bigger title, up to three preview lines, a tinted plate) so
   the next move reads at once. The sheet scrolls; each lane's title carries its count in the title's grey, as the inbox's headers do (round 31).
   Rows show status glyph, title (up to two lines, whole at accessibility sizes) and, for one that
   needs you, what it asks (the inbox's pending question), else the newest line (or the workspace
   without previews; the host under All Hosts): two lines for Needs You, Done and Read, one for Working
   (two once it has gone still, so "Last reported:" leaves room for the command, round 26;
   round 6 had dropped a read thread's line as old news; round 25: the inbox kept the read
   verdict and the dock didn't, so the same agent said different things; round 33: one line cut
   the verdict to "Fixed. The test now runs on the fake cloc…"), the line whole
   at accessibility sizes, at primary 75 % rather than grey, a live working agent's step at full primary (round 53: sb#3: at 75 % it read as one more line of metadata, where the inbox sets it primary). Under the title one meta line:
   the workspace (`displayLabel`, the inbox's and the thread subtitle's name for it; round 7: the
   dock used another), then the harness and the last turn's age on the same "·"-joined line
   ("api · OMP · 2m"), as an inbox row says them (round 14: the dock dropped both, so similar
   agents and stale results looked alike);
   lane labels are subheadline semibold (round 14: caption labels were faint).
   VoiceOver hears each row (and each quick-switch item) as title, host and workspace, then its
   status, a result's caution before its verdict (round 48: sb#4: "No blocking findings" was heard before "apply 0042 first"; Select's labels alike), preview, harness and age (round 5: rows from two hosts with the same title sounded alike; a working one's "working since 12 minutes ago", in the dock, Select's and the Overview's summaries alike, `HostConnection.spokenAge`, round 45: sb#5: shown, never said). Its ages tick on the minute while the sheet is open (round 45: sb#13).
   Holding the button opens the quick switch, a menu of what wants you then what's working, each
   item its title over the row's meta line ("web-dashboard · OMP · waiting 4m", the host first
   under All Hosts; round 16: title and status only, so like-named agents read alike), "no update 6m" for a working one gone still and "for 12m" for one at work (round 45: sb#12), and VoiceOver hears Unread, the harness, and what it asks or its verdict too, a result's closing caution before the verdict (round 46: sb#4) (round 31: the hold menu showed less than the stack; round 32: it said where and when, not what).
   The button shows the app's sheep (`HerdMark`, 28 pt, drawn over the menu: as its label it
   kept the mood it first showed; its mood reflects waiting first, then working, then idle); its count caps at xxxLarge.
   Rows lead with the inbox's unread dot, in Mail's blue, in the row's leading inset, 5 pt clear of the glyph (round 46: opus#10: unread showed by weight only; round 48: sa#12: 2 pt read as one badge). Once a second thread has opened, until the dock or its quick switch is first used, a TipKit popover on the sheep says what it is: "Your Other Agents. Tap the sheep for every other agent. Hold it to jump to an active one." on the raised surface, its message in the app's secondary grey (`AgentsTip`, `tipBackground`; round 48: sa#6, opus#2: two sentences in the system grey on glass read muddy; shown once; the demo resets its store at launch; round 46: sa#2, sb#10, opus#5: nothing on screen said the sheep opened other agents). The sheet is modal to VoiceOver and returns focus to the button as the system's do. Each row's context menu and accessibility actions offer only what applies: Mark as Read or Mark as Unread, and Open Terminal (round 36: dock rows could only open a thread; round 38: VoiceOver heard both read states on every row). No Hide: a row gone from the passing panel would have no Undo, as the inbox's has.
   While open the sheet holds the order it opened with: rows keep their section and
   place, a row whose status has left its lane leads its place line with where it is now
   ("Now working · studio", the word in the status's tint; round 7: a row stayed under a Needs
   You heading after it went back to work), ended rows drop out, and a thread new since it opened joins the end of its lane, or a lane of its own after the rest (round 80: sb#1: an agent that started waiting with the sheet open didn't show until the next opening), and keeps that place until it closes (round 81: sb#2: it re-sorted on its next change). A lane's header accounts for exactly the rows under it: the count of those still in the lane, then those held there after they left by where they are now ("Needs You 0 (1 now working)", beside "(1 no update)"; round 81: sb#1: it counted every row it held; round 82: sb#2: a moved row fell out of every total; round 83: sa#5, sb#1: as a live total it described rows held elsewhere and missed a lane not open), and the first waiting row leads wherever it is (round 81: sb#9).
   An agent whose inline answer shows its receipt counts as working in the dock's lanes, rows
   and hold menu (`SceneState.needsUser`; round 15: the badge had stopped counting it but its
   lane still said Needs You). A tap replaces the open thread in place, without
   animation on a phone (`scene.open`); a thread without a transcript opens its terminal.
   Opening a thread is not a read; the usual read gate decides. The dock is disabled while a
   send is in flight, since the composer and attachments belong to the thread they started
   in; a send that fails afterwards restores its text to its own draft. A pick closes the sheet
   over the thread it opened. Dismiss with a swipe down, Close, the accessibility escape gesture
   or Escape on a hardware keyboard (round 17: no key closed it). Rows' "place · harness · age" line is
   footnote (round 17: at caption size it read as fine print). In a split
   view the selected thread is the detail stack's root (swapped in place) rather than a pushed
   view: pushing it blanked the column on every change of selection.
   A hold on the closed button opens the **quick switch** instead: a native menu (`Menu` with a
   primary action, so a tap still opens the stack) of only what wants a turn now. That means
   Needs you and Done (in the lanes' order), then Working (the latest turn first).
   Read is left to the stack, and it reads "No active agents" when nothing is
   active. `.menuOrder(.priority)` puts the most urgent row nearest the button, so it reads
   upward. The menu is compared by value, so streamed records don't rebuild it while it's open.
   A pick looks the thread up again, since it may have ended. There's no menu while the stack is open.
3. **Terminal**: existing SwiftTerm surface pushed from the conversation or a shell row; observe
   by default, typing mode (takeover) opt-in, behind a "Type" button with the keyboard
   glyph in the bar beside Read as Text (filled, "Stop Typing" to VoiceOver, while on, and a
   "Typing" capsule in the rail as the way back; selected trait, hint "Resizes the pane to this
   screen"; round 5: a bare glyph didn't say it takes over the pane, so VoiceOver hears "Type";
   round 17: in the key rail after ⌃C it fell off the edge). The fallback for anything we can't structure.
⌘T toggles Type/Stop Typing (round 19: terminal Type had no direct hardware-keyboard shortcut).
   While observing, the key bar leads with the keys an approval needs and the interrupt
   (↑ ↓ return esc ⌃C) (the composer already sends a line; Type is for raw keys),
   then tab, shift-tab, ← →, scrolling sideways for the rest (round 15: behind a "Keys" toggle
   they cost an extra tap at every prompt, and all four graders read the terminal as keyless);
   the keys 4 pt apart, so on a phone the next key's rim shows past ⌃C, and the bar's trailing edge fades over its last 24 pt while keys lie past it, a "…" in primary over the fade ("More Keys") scrolling the rail to its end, inside the fade's 24 pt so ⌃C keeps all of its own on a phone, its taps reaching 12 pt past it outward and 44 pt tall, no animation under Reduce Motion (round 90: opus#4, sa#4, sb#2, sb#5: round 89's grey chevron there read as a disclosure arrow, took taps across 24 by 34 pt and always animated; a key of its own beside the rail pushed ⌃C into the fade; round 89: the fade and the rim alone read as a shadow, not more keys), measured from the keys' and the bar's widths rather than scroll changes alone, which miss the first layout (round 88: opus#5, sa#9: the fade never showed until the rail was scrolled, and the phone's rail read as five keys ending flush on ⌃C) (round 15: "esc" was cut in half at the
   rail's end; round 16: then "ctrl-c" was, the key that stops a run; round 18: half a key showed beside the sheep). VoiceOver hears "Type", "Up Arrow", "Return", "Interrupt, Control-C". While typing, SwiftTerm's own
   keyboard accessory (esc, tab, sticky ctrl, arrows) takes over. Pinching the terminal output
   and ⌘+ / ⌘− / ⌘0 set the persisted terminal font size in place, in whole points within
   Settings' 8–32 (round 15: only Settings changed it; round 38: a 20 pt cap left accessibility sizes only Read as Text, sb#15). The key bar sits in the composer's middle slot between the mic and the dock (where a
   conversation's Now line goes), so the screen keeps the conversation's two rows (round 2; it
   had been a third row above them). Keys and composer sit on the theme's own background, as its bar does (round 95: sb#14, a white slab under a cream theme).
   Reading scrolls like a document without touching the host's pane: vertically into earlier
   output (`pane.read recent`, ANSI colours, loaded on open and each time you scroll up into
   it) and sideways when the pane is wider than the phone (observed at its `pane.layout`
   width). Typing mode fits the screen and doesn't scroll. Until the user picks a size
   (Appearance & Terminal), the text is 12 pt on iPhone and 15 pt on iPad (round 4: 12 pt read
   as a thumbnail on a 13-inch screen), grown with the text size up to 20 pt (round 40: sb#13,
   sa#4: at accessibility sizes it still opened at 12 pt); ⌘0 returns to that size and unsets it,
   so it keeps following the text size (round 41: sb#3). In the light themes every ANSI colour but black and
   white (and Solarized Light's text) meets 4.5:1 against the background, darkened in its own hue,
   and SGR dim fades to 75 % rather than 60 % (round 36: colours, prompt and dim text faded into
   cream); the dark themes' bright black, their dim grey, is raised to 4.5:1 (round 36: prompt
   and status lines were hard to read). Read as Text (`doc.plaintext`, not a lines glyph that
   looked like the inbox's View menu; ⇧⌘T, beside Type's ⌘T, round 40: sb#14) opens the last 2000
   lines as wrapped, Dynamic Type monospaced text: selectable, VoiceOver-readable, searchable,
   web links open in the browser and image paths in the host-file preview; search results are buttons that show their place in the output (round 41: sb#11, results were gesture-only). Other paths stay
   text: a host path is never opened locally or run. A host read failure offers Try Again (round 41: sb#12, transient failures required leaving and reopening the sheet).
   Live, it is a copy, said so: the footer gives when it was read ("The last 2000 lines the host keeps for this pane, read at 9:41") and how to renew it, by pulling down or Read Again (`arrow.clockwise`, ⌘R), which reads the pane over the copy on screen; a failed reread keeps the copy and its time and says so in the footer ("Couldn't read again (…). Showing the copy, read at 9:41."), announced to VoiceOver, and after the match count while searching (round 62: sb#1, the footer said what the host keeps, never how old this copy was, and only reopening renewed it; round 63: sb#1, sa#9, a failed reread was silent; round 64: sb#3, the match count hid it). A copy read live keeps its read time once the link drops ("Output read at 9:41. Not connected."; round 64: sb#4, it took the terminal's last-received time), and a reread after the drop keeps that copy rather than the terminal's older frame (round 65: sb#2), its failure announced to VoiceOver as any other is (round 66: sb#4). While searching, each match is a 44 pt button (round 65: sb#4: a one-line match was a sliver). The sheet is titled with the agent or pane, as its terminal's bar names it, over "Output" (round 63: sb#5, "Output" alone didn't say whose).
   Offline, Read as Text opens a snapshot of the currently rendered buffer with its last-received time and does not attempt a host read; Type remains disabled without a live link. Offline, a compact line above the buffer says "Output as of 4m ago · Not connected" (`wifi.slash`; round 36: a stale terminal's "Working" prompt read as live, and a disconnected terminal lost its readable route). Live, the pane streams, so its screen is current whatever the transcript says, and no line shows.
4. **Settings / hosts** sheet, laid out like iOS Settings: Hosts; SSH Key, Tailscale,
   Notifications, Privacy; Conversations, Composer & Dictation, Appearance & Terminal (pages);
   About (the version in its footer; "herdr Website" with an outbound ↗, round 55: opus#13, a bare green "herdr" read as a stray link). Rows are system rows with a monochrome outline symbol in
   a fixed, Dynamic Type–scaled icon column (`SettingsLabel`), no coloured tiles. Inbox view
   options are not here (see the View menu). Onboarding is a sheet flow: the Herdwick sheep
   (`HerdMark`, drawn in SwiftUI from the icon, its cursor blinking unless Reduce Motion) at 60 pt
   beside "Herdwick" over "Your coding agents, in your pocket." (round 8: the stacked hero
   pushed Address and the demo link below the fold) and a sample of what it does rather than a
   list (`SampleAsk`, round 7: three generic symbol-and-text bullets), labelled "Try it · a sample
   inbox" (round 8: nothing said it was a sample): an agent row asking "Allow
   bash?" over its command, with the thread's Approve and Deny. They work on the sample: the
   receipt ("Approved · it's running the tests") replaces them with a success haptic and an
   announcement, the glyph turns to Working's ring, turning as the inbox's do, and 3 s later (12 s with VoiceOver or at accessibility sizes; round 42: sb#15) it asks again.
   Under it, divided as inbox rows, the rest of a small herd: "Token-bucket rate limiter", Working · api, its ring turning, and "Review PR #412" Done with its verdict (round 50: sa#14, opus#12: one card under an empty band didn't say the app watches many agents), heard as inbox rows are, status and age in words (round 51: sb#8); at accessibility sizes the ask alone.
   The hero and sample sit centred in the room above the actions (round 42: sa#8, opus#3: top-aligned,
   they left an empty band). At the screen's foot, in thumb reach (round 41: opus#3: in the top 60 % they left an empty
   40 % under them; taller than the screen it scrolls as one column), "Connect a Computer" is the
   prominent primary action and "Explore a Demo Host" the secondary one under it, both full width
   (round 40: sa#7, the setup steps under the sample turned a first look into setup work; round
   19: the steps had pushed the demo link to the bottom edge), over a note that Herdwick connects
   over SSH and installs nothing. Connect pushes a page titled "Connect": "Connect the computer
   that runs herdr" as two numbered steps (round 18: one paragraph named herdr, the harnesses,
   tabs, systems and SSH before any sequence): 1, install herdr on your Mac or Linux machine,
   with How to Set Up herdr (herdr.dev in Safari) under it; 2, connect to it here, whose detail
   says it's over SSH, running only herdr's own commands, and that Herdwick installs nothing
   (round 7: "Nothing is installed on your computer" contradicted needing herdr); then flat
   choice cards on the raised surface, Tailscale and Address, which push their setup pages.

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
and a leading Start swipe action; Panes uses the same empty-workspace wording.

Inbox options (the View menu, persisted in `UserDefaults` except Needs You Only, which is per
window): all hosts or one (the chips or the Hosts sheet); grouping None/Host/Workspace/Status,
Status by default (round 5: one recency-ordered list mixed working with idle and reordered as
agents finished), its sections Done (unread results), Working, Read (read ones) in that order (round 6: results waiting to be
read first, as the dock's lanes), Read not folded again inside
its own section; installs that had stored None, the old default, read it as Status once
(`inboxGrouping.statusDefault` marks the migration), so a None chosen afterwards stays;
"Needs You" pinned first in either sort, by the held
rank while browsing, so a thread doesn't jump into or out of it under the reader; sort Recent or
Priority (unread done, working, read, unknown); Collapse Read ("3 Read", a summary row at the
end of its group's card; a separate idle section reads as a different group). Panes… opens
herdr's host › workspace › tab › pane tree (`PanesView`, with Close Tab/Close Workspace swipes;
it was once an Agents/Machines view switch; rows leave out the workspace their group's header
names, and a group with an agent waiting shows the Needs You glyph, round 6; a tab's label
starts at its rows' title edge, a shell takes an `apple.terminal` glyph in the status column and
agent rows show their last turn's age, or "no update 6m", as the inbox does, round 8: labels and glyphs sat in
three different columns and nothing said how recent a pane was). Read, Terminals,
Hidden and Ended open from a summary row inside their card (`FoldRow`): the rows come and go at
once and only its chevron turns (150 ms ease-out: it moves on the frame the rows land; an ease-in start lagged them). An animated insert can't look right in an
inset-grouped list: UIKit reshapes a kept row's corners only after the insert, so the summary
stayed rounded over the arriving rows (black notches); a fresh summary row per state crossfades
two half-transparent rows (a dark flash); and a custom row background is clipped to the row's
corners too. Not `.grouped` with hand-drawn card corners: every card would need it, for one
transition; nor rows opening above the summary, which then slides down past them. Rows swipe leading to
Mark as Read/Unread (full swipe) and Hide/Unhide (local), trailing to Close. Close is a plain
red action with `xmark.circle` (round 6: a bin read as deleting a document; closing ends an
agent), not `.destructive` (a list slides a destructive row out at once, then back while the
prompt is open). It asks in a centred system alert ("Close <title>?", Close and Cancel), like
every single-choice destructive confirm in the app (bulk Close, Panes' Close Tab/Workspace, Stop
Run, removing a host, Trust New Key): the anchored popover it replaced floated off its row and
read as a stray card. The action runs once the alert has gone (about 0.5 s), so confirming takes
the thread off every list at once (`HostConnection.closing`,
200 ms ease-in-out) while herdr ends it, until a snapshot no longer has the pane; a refusal puts
it back with an alert. The context menu (long press, or a secondary click) holds everything the swipes do
and more, in sections: a waiting approval's options in the harness's full wording (titled with its
question), then Mark as Read/Unread, Hide/Unhide and Open Terminal, then Rename… and New Agent
Here, then Close…, red, through the same alert.
   A thread has VoiceOver rotors for Results ("Done 4:36 PM", its warning as the card leads with it, then its first line without Markdown marks; round 82: sb#1: "No blocking findings" alone hid the step before deploying), Decisions (each record as its row says it, time and screen-read caveat included, round 82: sb#4, and every answered question with what was chosen, or "dismissed", round 88: sb#13: it named the question only; every question of a multi-question ask and every choice of a multi-select one, the choices joined as a list, round 89: sb#1: only the first of each was heard, in the transcript record's words (`AnsweredAsk.reply`, its per-question answers keyed by the question's text as the parsers key them; round 90: sb#1: keyed by id, every per-question answer went unheard)) and Agent Messages ("From BenchCouncil: …", "redis-check finished"), each stop by the row's scroll id so VoiceOver brings it into view (round 81: sb#4: a long thread had to be read through to find them).
   The inbox list has VoiceOver rotors for Needs You, Working and Unread Results, targeting the existing agent rows, each entry named with its place (workspace, and host when not this one; round 52: sb#2, titles alone), a Needs You question leading its entry as it leads its row, an approval keeping its title first (round 77: sb#8) (under Needs You Only, Working targets the filter card's rows; round 40: sb#5) so users can jump past large decision cards (round 36: at AX sizes a decision filled the screen with nothing to jump to).

An approval that needs you is answered from its row (round 3): when the screen probe has read a
choice prompt (`Wait.prompt`, `.choice` in its question phase, with a yes among its options), a
second row under the agent's, sharing it (no separator between them) and indented to its title, offers Approve
(prominent) and Deny (neutral `choiceButton`: red is kept for the receipt and the menu's destructive
role; round 4), Deny at its own width and Approve taking the rest (round 59: opus#9, sb#8: in equal halves "Approve Once ⌘1" didn't fit and its hint went while Deny kept "⌘2"), in the thread card's rounded shape at a compact
height, the "…" menu beside them rounded too (round 26: capsules here and halves on the card
drew one decision two ways), short verbs for the harness's "Yes" and "No, and tell
Claude…"; anything else (a yes that lasts the session) and Open Thread sit under a "…" menu.
The first unanswered Needs You card also owns ⌘1…⌘9, in the same order as its visible options
(round 19: inbox decisions lacked the thread card's numbered hardware-keyboard shortcuts); other
cards register none, so their choices cannot collide. The shortcuts are disabled while answering
and appear in iPad's ⌘-hold discoverability overlay. With a hardware keyboard attached
(`HardwareKeyboard`, GameController's connect notices) each choice that has one ends its label
with it ("Approve ⌘1"), a level quieter than the label as a menu's key equivalent, here and on
the thread's card (`ShortcutHint`; round 25: the shortcuts, and which card owned them, were
invisible; round 26: as a badge hanging off the button's corner it read as a debug annotation
and covered the label at accessibility sizes). Short of room the hint goes before the label is cut (round 58: opus#1, sa#1, sb#1: "Approve On… ⌘1"); the key still works. Not shown at accessibility sizes, where it took a
word's width from every line of the label (round 33); the keys still work.
At accessibility sizes they stack, Approve over Deny over the menu, as the thread's card does
(round 9: they kept to one row where the card stacked).
A tap runs `PromptDriver.choose` exactly as the thread's card does: the chosen button says
"Approving…"/"Denying…" with a spinner at full contrast (a second tap is ignored), and the
others, Other Answer and the "…" menu are disabled meanwhile (round 14: they only
ignored taps, so VoiceOver found controls that looked available and did nothing); the chosen
button is heard as progress, not a button (round 77: sb#2). Once the prompt has left the screen the row keeps its place (`InlineAnswer` pins its
rank, so the row doesn't jump while the eye is on it) and the buttons give way to the receipt
in place ("Approved once" after the sheep's seal, `HerdSeal`, that signs off a Done card, its check
popping in; a red cross for Denied; round 27: a stock check made the loop's best moment its
plainest), with a success haptic (a light tap for Deny)
and VoiceOver hearing "Approved · <title>"; 0.8 s later (2.5 s with VoiceOver or at accessibility sizes; round 43: sb#3), once the
agent's status has also held for 0.4 s (1 s more at most; round 6: an agent that picked up and
soon finished took the row to Working, then on to Done; round 7: 3 s more let a row move 4.7 s
after the answer, under a reader already on the next one; round 8: 1.2 s and 1.5 s more still
kept the list moving for seconds), the row moves,
with a snappy list animation, to where its new status puts it. A failure says why in an alert
with Open Thread and an error haptic. An ask is answered from its row too (round 5) when the
inbox already holds its transcript (the warmed conversation, `ConversationRegistry.parsed`) and
it is one question with a single pick among one to three options: the options sit where
Approve and Deny would, as the thread card's options at a compact size (round 26: capsules
with the explanation after them drew one decision a second way, and an answer could be tapped
before its caveat was read): full-width rounded choices (`Tokens.Radius.choice`), stacked, the
agent's recommended one on the inset surface (white in the light, a step up from the card in the
dark) washed 10 % in the accent (round 51: sa#4: plain, it read as one more grey plate in the card) inside an accent hairline, the rest on the same inset surface inside a grey hairline, all with
primary words (`ChoiceStyle`; round 28: a green fill under green words read muddy in the light and
left the caption and ⌘ hint faint; round 29: the neutral grey, darker than its card in the
light, read as disabled; round 62: opus#6, `.bordered`'s grey on the grey card still read as
disabled in the dark, Deny and "…" the faintest controls in the app), never filled, as in the thread (round 6: a filled option read as Approve); inside the button,
"Recommended" in accent semibold footnote over the label, with the ⌘ hint at the end of that
first line so the lines under it keep the tile's width (round 27: a hint column narrowed the
explanation), and the composer's send arrow (`arrow.up.circle.fill`, title2, in the accent) in a
column of its own at the trailing edge, centred on the tile, with the ⌘ hint under it, one cluster for the one action (round 87: round 85's sa#8: alone in the top corner the hint read as a stray label; beside the arrow it widened the column and wrapped the explanation; other options keep it at the end of their first line), since a tap
sends it (round 48: sa#4, opus#14: outlined, it read as a note rather than the answer's
button); at accessibility sizes "Recommended · " leads the explanation instead of taking
a line of its own, and the arrow leads the label inline rather than taking a column from the
explanation (round 49: opus#4, sb#6: without it there the tile read as a note again) (round 27: the recommended tile filled the screen and pushed Write Your Own
Answer below it) (the accent on the card, as Write Your
Own Answer's, is `Tokens.Tint.onAttention`, #2E6B3F in the light, round 14; the app's accent itself is #336B48 in the light, 5.2:1 or better on every light surface it labels, round 81: opus#7: #3F7A55 held 4.4:1 on the grouped grey and the recommended wash) and the option's
explanation under it in footnote `Tokens.secondaryText` (two lines, uncut at accessibility
sizes), and VoiceOver hears the option with "Recommended", its explanation and preview (round
11: a lone tinted pill read as already chosen, so a lone option that isn't recommended is
neutral; round 7: only a lone option's explanation showed, and none was spoken); a label wraps
to three lines rather than truncating, and nothing is cut at accessibility sizes; the row's
separator starts at the title, not the first button's label),
then "Other Answer…" as on the thread's card, a 44 pt target that the layout doesn't see, as "Inspect in Terminal" above an approval's buttons (round 56: sb#1, their 28 pt lines were the triage loop's smallest targets), leading-aligned when it wraps (round 8: centred ragged lines at accessibility sizes; round 6: it hid behind an unlabelled
"…" and Open Thread); at accessibility sizes nothing is cut either: a lone option's
"Recommended · …" explanation and Other Answer wrap, and the inbox scrolls to them
(rounds 12–16 shortened or dropped them to keep the card on the first screen; round 17: the
explanation only VoiceOver heard left the visible answer without its caveat). It
opens the thread with the ask's answer editor out and focused
(`SceneState.writeAnswer`, taken by that thread's `AskPanel`). A tap on an option runs
`PromptDriver.answer` as the thread does, which checks the screen shows that question before
each key; the inbox follows the transcript meanwhile, since the agent logging the answer is
the proof, then "✓ Answered “…”" stands as for an approval (up to three lines, so the answer it
confirms isn't cut). Several questions, several picks
or free text stay in the thread. Waits' summaries fold line breaks into spaces, so a
wrapped command doesn't spend the row's two lines. When nothing needs you and every shown host
has answered, the top of the inbox keeps a slim row, under no header, where Needs You was: the herd mark,
"Nothing needs you" over what's left: "2 results to read" while a Done is unread, then "3
working", grouped by status too (round 32: left to the Working header, the row said less than VoiceOver's announcement), or "You're all
caught up" when neither is left (round 6: "all caught up" sat over an unread Done); never with a host away: that all-clear wouldn't be. Rows on
the phone have the page's opaque colour under them, so a swiped row slides as a cell. Every
answer given from the app, here or in the thread, is kept as a decision (`DecisionLog`, keyed by host, session, pane and transcript; round 8: without the session two sessions' panes could share a record; 7 days,
300 at most; the demo's only for the run) and the thread shows it as a quiet footnote line after
the call it answered ("You approved · 12:41 AM" over the command, "Tue 12:41 AM" once it isn't today's, as the
transcript's other times, round 83: sb#8; past six days the date, "Mar 3, 12:41 AM", round 91: sb#9, a
week-old "Tue" read as this week's, and before this year with the year, round 92: opus#13, checked
before the weekday so New Year's week keeps it, round 93: sb#15; `checkmark.shield`, which draws itself on when the
record is made that moment, round 83, not under Reduce Motion; a red `xmark.shield` for Denied), so the record outlives the receipt (round 5); the command under it is footnote monospaced, as on the card (round 25: in caption it read as a different object from the one approved); a command read off the screen that may have been cut short keeps "Read from the screen; may be incomplete" under it, as the card had (`DecisionLog.Entry.detailMayBeCut`; round 24: the record looked more certain than the request). An answered ask's line
sits under its question-and-answer block and says only "You answered · 2:07 AM" (VoiceOver hears
the answer too): the block already says what was asked and answered (round 6). Until the agent
writes again after an approval, a step line at the transcript's end says what runs, "Running bun
test src/charts/move.test.ts" (the running command, else the approved one, else "Working…";
`TailWorkLine`, still under Reduce Motion; round 21: the card left a card-sized hole before the
reply). The same "Working…" line follows the user's own message once the host says the agent is at work, until its first word (round 59: opus#1, the bubble sat over empty black for seconds with only the subtitle saying it had started).
At accessibility sizes, the line wraps vertically so its full step remains visible (round 39: sb#7).

Rename sets the pane's name in herdr (`pane.rename`, its manual
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
In the demo the full New Agent form starts an agent on the demo host in a new tab of an
existing workspace: it opens idle, and a message sent to it turns it Working, then Done with a
canned reply about 3.5 s later (round 8: the demo's New Agent was a dead end). Folder browsing,
terminal starts and New Worktree are hidden, since the demo host doesn't implement them. The
workspace's footer says "Demo host: agents here are scripted samples." (round 23: under
Connect a Host it was far from the place and Start). A Host row above the workspace names the
demo host, and its menu's Connect a Host… leaves the demo for onboarding (round 24: as a section
of its own it stood mid-form as a step of starting the agent). A scripted turn restates the first line of what was asked ("Done: add a dark mode
toggle to Settings.", round 23: "Made the smallest change…" could have answered anything),
then its tests and where the diff is.
Launch presets (Settings › Conversations › Launch Presets) name an agent kind plus arguments,
one per line, passed as literal argv (`agent.start {args}`: no shell, quoting or variables);
New Agent shows a Preset picker when any exist, and no preset starts exactly as before.
New Agent can instead start in a new worktree of the chosen workspace's repository: a typed
branch name, herdr's default base, `worktree.create` with `focus:false`, then the agent in the
returned workspace's root pane. Workspace rows show herdr's worktree metadata (repository,
checkout); the snapshot has no branch field, so none is guessed. Preset and worktree sit in a
collapsed Options group. New Agent opens full height on the optional First Message ("What
should it work on?", under its own header so the field doesn't read as a greyed-out label,
round 18), a four-line editor focused on open as Mail's compose is (round 21), then host,
workspace and agent rows with the demo footnote, Open Terminal, then
Options (round 40: sa#10, opus#13: the place rows led and a floating full-width Start band
over the keyboard cut the editor to one line). Start sits in the navigation bar's confirmation
slot, as Mail's Send does: "Start", or "Start & Send" once there's a message (round 41: sa#6,
sb#5: a bare Start hid the send); its spoken label also names the agent ("Start OMP and Send"), and ⌘Return presses it (round 30: the
keyboard loop that opened the sheet with ⌘N ended there). While it starts, the button is a spinner and Cancel is off,
through the sheet's exit too (round 60: "Start & Send" came back enabled as the sheet slid away).
Start Without Sending is a row under the message, inside its card (round 65: sa#10: a detached row two sections down sat apart from the words it qualifies). The demo's Host value is the Agent picker's grey (round 65: sa#9: tinted green and dimmed, a valid host read as disabled). The field's footer says what happens to the message ("Sent when the agent is ready; Start Without Sending
keeps it as a draft"; round 23: it repeated both buttons' labels). Either way
the message is the new conversation's draft (`SceneState.firstMessage`, so the demo's too); with Send, the thread
sends it once the agent has reported its session and isn't busy, a second later so its prompt
reads input. Until then a line over the field says "Sends when OMP is ready" with Don't Send
(sending or clearing it yourself also stands it down); not up within 30 s, the line says it
wasn't sent (announced to VoiceOver) and the text waits in the composer (round 20: the queued
message looked like any draft and a timeout was silent). Meanwhile the thread is titled by
the queued message, its subtitle says "Starting · web-dashboard" in grey and the empty
transcript shows a spinner over "Starting OMP…" (round 48: opus#1: "omp-773dd5 · Done" over
"Send a message to get started" while the message was set to go). Left first, it just waits there.
An agent without a transcript opens in the terminal, the message unsent.

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
Composer & Dictation › Snippets) into the draft; a snippet is never sent by itself. The on-screen Return adds a line unless "On-screen
Return Sends" is on; on a hardware keyboard Return and ⌘↩ send, ⇧↩ or ⌥↩ adds a line (the
placeholder adds "· ⇧↩ new line" when a keyboard is attached and the hint fits the field whole).
Conversation detail (`DetailLevel`) is Messages and Steps (`folded`, the default: each run of
steps on one line) or Messages Only (`digest`: steps only while running or failed), each item
saying so under its name (round 16: "Folded" and "Digest" named the mechanism, not what shows):
one saved preference, set in Settings › Thread View
or any conversation's More menu, its View item opening the levels with the current one checked (round 50: opus#9: "View: Messages and Steps" wrapped to two lines; iOS 26 menus show no subtitle on a submenu or menu picker; Find sits in a palette row only beside Images or Changes, else a plain row, where alone it read as a stray tile) (Find may show Messages and Steps until its Done). A third level, Full (every
run open), was retired: opening a run now opens its diffs, and a stored "full" reads as `folded`. The transcript follows its newest
message through replies, the composer resizing and the keyboard until you scroll away;
scrolling back to the end, or sending, resumes following. Focusing an empty composer on a
thread that isn't working stops following, decided as the field is about to take focus
(`ComposerTextView.onWillFocus`, so the keyboard's first frame sees it): the keyboard covers
the end and the Done line and verdict being replied to stay in view (round 19: all three
graders lost them; set once focus had changed, it came a frame too late). A thread ending on a
result also brings that result's top under the bar as the keyboard rises, so its room holds the
reply being answered (round 20: it held the tool rows before it and one line of the verdict).
Sending clears the draft at once and keeps the field focused (disabling it resigned the
keyboard, which slid down and up on every send); a failed send puts the text back ahead of
anything typed since. Unsent text is kept per conversation (`DraftStore`: one atomic,
complete-protection file keyed by host, session and agent session, text only, pruned after 14 days;
a pane-keyed draft moves to the agent session once it's known, and a pane that switches to
another conversation shows that one's draft), so it survives leaving the conversation and
relaunching. A new thread shows one quiet line, "Send a
message to get started.", only once its transcript is live and empty and nothing is being
sent.

The composer is three columns: the mic over +, the field, the dock over Send. The side buttons
stand two high so the field has the bar's whole middle (a one-row `[+] [field ⋯ mic] [send]
[dock]` bar was tried and left the field too narrow). They keep 8 pt (`Space.s`) from each
other and from the field, the gap between the app's other glass buttons (the user: at 4 pt the
pairs read as cramped beside the rest of the UI). A field taller than the pair carries the
mic and the dock up to its top corners. The field is a rounded rect (22 pt), not a capsule: a
capsule's ends swell with each line and ran the text and the caret off the glass. It grows to
six lines, then scrolls. At accessibility text sizes the field takes its own row with the
buttons under it. The mic is the composer's own, in both composers, so dictation works
whatever keyboard is up: the system keyboard's own mic depends on which keyboard is up, and
a dictation keyboard (Wispr Flow) means switching keyboards. Speech is recognized on the device
by SpeechAnalyzer: SpeechTranscriber, or DictationTranscriber where the first isn't offered or the
user has known terms (only it takes hints: the known terms, then the folder, agent and recent file
names, via `AnalysisContext.contextualStrings`); the first use in a language downloads the
system's model. Tap to listen (the tap also puts the keyboard away, to leave room for an ask; tap
the field to bring it back; ⌘⇧D leaves it up). The keyboard is resigned a turn after the tap, not
inside its action: a UIKit text view resigned inside a SwiftUI action sends the bottom inset to
the screen's edge and springs it back (seen on iOS 27). While listening the mic is Stop (red), and a
plain card (a quaternary fill, not glass: it is content) sits above the bar, hugging the words
up to about four lines (then it scrolls, held at the newest) beside the × that discards them.
An earlier L-shaped glass card grown out of the mic (`DictationShape`) was dropped as a second,
busier composer surface. It says what it's doing until the first
words, then shows the settled words and, dimmed, the model's open guess, which never reaches the
draft; the words are the sign it hears you, so nothing pulses. Settings › Composer & Dictation › Show Live Transcript
off keeps it to one status line ("Listening…", then "Hearing you…" once words are recognized),
for when an agent's question card and a growing draft already crowd the bottom. Stop puts the
words in at the cursor as one undoable insert; stopping before any words ends quietly, with
nothing inserted and no error. Mic and Send stay apart (the mic over +, Send across the field),
so a missed mic tap can't send. Nothing sends until the words are in (Stop
never sends), and a call, a route change or leaving the app stops it and keeps what was heard.
Auto-lock is held off while words keep coming (`isIdleTimerDisabled`) and handed back after 30 s
without new words, so a forgotten session can't keep the phone awake; the lock then stops it and
keeps the words. It doesn't record in the background, as Voice Memos does: that would need the
audio background mode and a session that outlives the screen.
⌘⇧D starts and stops it; Escape cancels. A lost connection locks the field, + and Send, but not
Stop or ×. The pinned Now line takes a button's height (at least 44 pt, three lines at
accessibility sizes), so it lines up with the dock.

Settings › Composer & Dictation › Dictionary has replacements and known terms, applied in that order to the
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
"1 in background", or just "Working…"; too narrow for all of it on one line, the call sits over
the rest in footnote; the whole quiet line, not only that footnote, is in the app's secondary grey (round 17: system grey caption read faint; round 18: the main label in system grey read as disabled), then stands alone (round 16: "Running bun test refill.test.ts · b…" cut the
subagent's name); derived only from the transcript's running calls,
working subagents and background commands, and gone offline. Tapping it opens Now: working
subagents (with elapsed time; each opens its thread), running calls and background commands in
full. It replaced the transcript's "Working…" row and the Working Subagents tray and setting.
While it shows, the transcript leaves the present to it: a run's line says only what finished,
and a run of nothing but running calls appears once one settles. While Next holds the slot,
the transcript keeps the present itself (round 59: opus#1, a run started under "Next: Deploy to
staging" showed in neither place).
Otherwise, on return to a conversation, it's the catch-up line: "New since 9:41 · 3 edits · 2
replies · 1 error" ("New" in the accent, red errors), counted after the last item the reader saw at the end
(`ReadCursors`: the newest item with a transcript-given id, saved per conversation like drafts
while the end is on screen, pruned after 30 days). Tapping it scrolls to the same line in the
transcript, between accent hairlines before the first new item (round 8: grey hairlines let the
boundary pass unnoticed); where that one line doesn't fit, and always at accessibility sizes,
"New since 9:41" in accent semibold stands over the wrapping counts, without hairlines (round 14:
the fixed line had no way to wrap). That line coming into view, or sending,
dismisses the pinned one. The demo takes the seen
item from `-HerdwickSeen`, read ten minutes before launch (round 14: a fixed 9:16 AM showed
under an earlier status-bar clock).
After the user answers an ask or approval here, while another agent needs them, the line offers
the next one: "Next: Review PR #412 · web-dashboard · 2 waiting ›" (the workspace in secondary,
after the host when it runs on another one; round 6: the title alone didn't say where it runs;
where that doesn't fit, "Next: Review PR #412 · web-dashboard", then "Next: Review PR #412" over "web-dashboard" in caption, then "Next: Review PR #412",
never a cut word, round 7: "· w…"; round 8: the short form dropped the place; VoiceOver hears the
whole, with the count, "2 waiting"), the top Needs You row of the inbox, which the dock and ⌘J follow too, opened
in place as a dock pick does; answering again or messaging a running turn clears it (round 5: an
answered thread left the user to go and find the next), while a reply delivered to a finished agent
hands it off as an answer does and offers the next too (round 42: sb#3: the line went with the
send, leaving only the dock's badge), from the tap on, so a line resting there stays through the send (round 44: sa#14: it blinked out and back; a failed send clears it). It also rests there whenever the open
agent has finished and nothing of its own is pinned (no catch-up line, no send under way), off
the iPad's sidebar, so the line names who the sheep's count stands for (round 39: opus#10,
sa#7, sb#15: a sheep with an orange 1 didn't say it led to another agent). At accessibility sizes the
resting line is "Next: Review PR #412" alone, on at most two lines (round 40: opus#2, sa#12, sb#3: hidden there,
the finished thread didn't say who was next; with its place and count it took three lines; round 44: sa#8, sb#6, opus#4: on one line it read "Next: Deploy t…"; the result's caution leads the card there instead). Since round 48 it
doesn't pin there at all: it is the transcript's last block, after the result, a line of the transcript 44 pt tall, not a card
(round 68: sa#4: its plate stood as tall as the result's last paragraph), with the orange glyph, "Next: Review PR #412 ›" in subheadline semibold (round 86: sa#3, sb#3: in body semibold it rivalled the result), the chevron ending the words so the
line reads as a way on, not a heading (round 69: opus#4) and its place and count under it in
footnote at full width under it, unclipped, at accessibility sizes in subheadline medium, the workspace only when it isn't this thread's (round 90: sb#3: dropped everywhere, a large-text reader lost where an agent elsewhere runs; round 89: sa#4, sb#2: three large lines stood between the result and the composer) (round 48: sa#1, sb#3, opus#8: pinned over the composer it left
the verdict a sliver of the screen; round 49: sa#4, sb#15: the glyph's column and a chevron cost the title
its width, so the glyph is inline with the words and there is no chevron); the sheep keeps its count meanwhile. After an answer
or a reply too (round 49: sb#5: pinned again then, it took the room back in the busiest moment). It's drawn as a glass capsule with a
semibold primary label (round 6: as a plain line it read as status, not the next move), except while the open agent works or the keyboard is up, when it is a quiet line in the app's grey, its orange glyph and chevron kept (round 60: sa#1, the capsule outweighed the new task's running step after Start & Send; round 61: sa#2 r60, with the keyboard up it held the strongest place over the field while the result being answered faded above it; the two swap
once the keyboard has settled, so the capsule rides up with the field first, round 93: opus#3, swapped as the
keyboard began, the quiet line was set at the field's final place while the field still rose, over the transcript), and
VoiceOver hears it with the thread's host and workspace like a dock row. The keyboard has the
same move anywhere: Inbox › Next Needs You (⌘J) opens the dock's first Needs You other than the
open thread, and waits, as the dock does, while the open thread's send is in flight (a focused
value, `herdwickSending`); Show Needs You Only / Show All Agents (⇧⌘J) toggles the filter. In a conversation, Open Terminal (⌥⌘T) pushes its terminal, where Type is ⌘T (round 86: sb#1: the keyboard loop had to reach for the bar's Terminal).
Next Agent / Previous Agent (⌥⌘↓ / ⌥⌘↑) step through every agent in the dock's lane order
(Needs You, Done, Working, Read; `AgentDock.keyboardOrder`; the dock and the walk ignore Needs You
Only, the inbox list's filter, round 40: sb#2), opening each in place, from the
inbox or the Overview starting at the first and stopping at either end; they wait for a send
the same way (round 10: a keyboard could jump to the next ask but not walk the rows). The walk
holds the order it started with (`SceneState.keyboardWalk`): ended agents drop out, new ones
join the end, and stepping from an agent not on it starts a fresh one (round 11: reading a result
moved it from Done to Earlier, now Read, so the next step skipped or repeated agents). Next
Needs You, Next Agent and Previous Agent are disabled where they would do nothing: no other
agent waiting, or the end of the walk (round 35: enabled, they did nothing). Bare
arrows stay with the composer and the transcript.
The choices of an ask or approval card on screen take ⌘1…⌘9 in the order shown (Approve ⌘1,
Deny ⌘2, then the lasting grants, then the rest; none while a choice is under way; round 7: a
hardware keyboard reached the next question but had to touch the screen to answer it).
After an answer the "Answered"/"Approved" pill holds while the agent is still shown blocked (up
to 8 s), so the Needs You banner doesn't flash back between the answer and herdr's next state;
the banner also waits while an answer is being sent or a pick is open (round 6: it flashed in
under the panel as the answer went).

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
quiet grammar (`QuietHeader`): a `.subheadline` secondary line with a trailing chevron (the step runs' `caption` semibold, at the column's end, so every chevron in a transcript lines up; round 65: a subagent result's stood 13 pt short of the runs'), one line, whole at accessibility sizes (round 66: sb#3), drawn 28 pt tall and answering taps across 44, step runs included (round 67: opus#1, sa#2: a run drawn 44 pt tall stood further from its neighbours than a subagent's line, so the machinery's gaps were uneven), that
turns down to open it in place, or goes to a subagent's thread; bodies are `.subheadline`,
literal commands, output and diffs `.caption.monospaced()` and unboxed. A run, a message between
agents and a subagent start with one tertiary symbol in a fixed, Dynamic Type–scaled column (`QuietSymbol`, centred in a 16 pt box scaled with the text inside the 22 pt column, round 89: opus#7: leading-aligned, wide glyphs nearly met their words and the hourglass left a gap), so the kinds
tell apart at a glance: for a run, its calls' kind when they share one (`StepRun.sole`:
`apple.terminal` commands, `doc.text` reads, `pencil` edits, `magnifyingglass` searches,
`hourglass` waits; the same per call once opened; round 14: one wrench for every tool made the
trail hard to scan), else `wrench.and.screwdriver`; `person.2.fill` for a message
between agents or a subagent; outcome tints the leading symbol green only for verified success
(passed tests/checks or a completed turn), red for failure, blue for running, and otherwise secondary:
ordinary reads, edits, searches, waits and launches stay neutral; a failed run's symbol is a red `exclamationmark.triangle.fill` instead of a red rail;
a message's body is indented under its text (round 2 reversed "no
icons": all three round-1 graders found runs, peers and narration indistinguishable). No cards,
spinners or timers (the Now line's working ring, the inbox's dotted circle turning slowly, still under Reduce
Motion, is the one live mark, in Working's blue (round 15 gave it a 20 pt sheep with a pulsing
dot, when the working agent had no face; round 48: sa#9: beside the dock's sheep it read as two of
one button), round 41: sb#10, the
accent green beside a blue Working read as tests passed; round 38: routine reads, waits and
launches had turned green too). A run's line counts what it did:
("1 error · Edited Chart.tsx · 3 reads · Ran bun test · 1 search · 1 message · 2 images"; edits
of one file name it; until UX round 1 every kind was counted, "1 edit", which read as vague).
A test command's totals lead its collapsed run line ("✓ 8 tests passed", in primary at medium weight, round 46: sa#7: grey like its counts it didn't win the line; the other work's counts in footnote grey on the line under it, "2 edits · 3 reads · 2 commands", round 45: sa#4: on one wrapping line the outcome read as one more log entry; "2 tests failed" in red, never wrapping inside the outcome; round 20: a test outcome joined an unrelated filename and truncated mid-word); the counts after it wrap to a second line whole rather than truncate (round 24: "1 re…", "2 i…"). When an outcome is present, only other-work counts follow, ordered edits, commands, reads and searches; filenames and commands remain in the opened run. Without an outcome, a lone step keeps its title ("Read refill.lua", "Ran git diff main...HEAD"). `StepRun.tests` is the newest settled test command's `TestTally`, read from the end of its own output only when that output wasn't capped, or none when it printed none, so unknown stays unsaid and an older run never speaks for it (round 8: "Ran bun test" didn't say how it went). VoiceOver hears the failure, the totals and the words. While running a line says what it's doing
("Waiting on npm run bench…", commands by name without flags, a path by its file name: "Ran bun test move.test.ts"; round 11). Only calls with no noun (a
stopped process, a wait) keep their title. Beside its chevron a secondary count says how many
lines opening it shows (`StepRun.steps`) when the counts don't add up to it (thinking, waits).
While a permission card waits on the newest run, its line says "Waiting for approval · bun test",
not "Running bun test" (round 5: "Running" above a card asking whether to run it contradicted it).
A lone command still in `waitingOn` (sent to the background, never answered) reads "Started
npm run dev · Background", not "Ran" (round 4: "Ran" claimed a finish that hadn't happened).
Opening a run opens its edits' diffs (and a lone call's detail) with it: one tap to the change.
A diff, command or search output, or written file sits in a box at most 320 pt tall that scrolls by itself
(`CappedScroll`; a diff scrolls both ways), so a long one never pushes the step's and run's
headers out of reach; only output past 500 lines waits for "Show all". An opened command shows itself whole only
when its line may have cut it. Messages between agents read "From X" and
"To X" (a brief shows its "Change" section first), results "X finished · 2m05s", a settled wait for that one agent just before it folded into it rather than a "Waited for X" row over it, and a wait a message broke in on into that message (`ToolActivity.waitedFor`; round 89: opus#12, sb#14: one handoff read as two events); each body is quoted, in the app's secondary grey on a 2 pt hairline rule under the header's symbol, so another agent's findings sit apart from this agent's own conclusion in primary (round 80: sa#1, opus#2: findings and the paraphrase of them read at one weight); each shows four lines
(round 68: sa#1, sb#7: at two a three-line NO-GO stopped at "Fix: deny o…"; round 69: sb#4: whole
only when it fit four, a message just past four fell back to two; at accessibility sizes all of it, the message itself rather than its gist, round 49: sb#10: two held three words there; round 70: sb#2: six still cut a peer's verdict; round 71: sb#10: a brief still showed its gist), then a "Show More" text button (`inlineAction`, 44 pt tall since round 5; round 4: the chevron alone wasn't read as
more text) whenever the lines cut it or the gist differs from the text; VoiceOver hears it as
"Show More: redis-check finished" (round 48: sb#11: a rotor of bare "Show More"s didn't say whose). A reply or result answering a lone brief (`answeredBriefs()`: the only
brief sent to that agent since it last spoke) carries the brief, under "Asked" when opened,
and the brief leaves its run; two briefs before one answer stay where they were rather than
guess which was answered. The More menu's Changes lists each file the tools recorded edits or
writes to, with each call's diff or written text, newest first: never a net diff, and a
shell's own changes aren't there.

Transcript rows sit 24 pt apart, except one run's narration and its work (steps, subagents, another agent's reply or a subagent's finish), which sit 12 pt apart wherever work is on either side, so the result after them, the user's next message, a decision and the catch-up line keep the full break; two narration paragraphs with no work between keep it too (`TranscriptRows.gap`; round 87: sa#3: a uniform 24 pt spent the review's screen on gaps before the result; round 88: opus#3, sa#2: a wait and the reply it waited for still stood 24 pt apart). A Markdown list's bullet column stops scaling at accessibility sizes (the marker at its own width, 4 pt from the text, the hanging indent kept; round 87: opus#8, sa#7: scaled, it took a fifth of a result card's width).

The agent's reply that closed a turn (`Conversation.finishedTurns`: the turn ended on its words,
not on a tool call or an error notice) sits on a raised card (`TurnResult`, round 4;
`Tokens.Surface.raised`, card radius, in the light a 0.5 pt separator edge as every raised card has (`raisedCard()`, `Tokens.Surface.edge`: the cards over the composer and the Overview's too; clear in the dark; round 89: opus#14, sa#13: pale grey on white they barely left the page), 16 pt padding, 12 pt at accessibility sizes so a finding holds more than two or three of the large words a line (round 87: opus#8, sa#7); round 7: behind a hairline rule it still
read as one more paragraph) under its header: the sheep's seal (`HerdSeal` on an accent
disc at 20%: the app icon's sheep with an accent `checkmark.circle.fill` at its lower corner;
round 15: Delight was the weakest area and a turn's end was an anonymous check, and without the
disc the dark fleece was lost on the dark card), at 28 pt beside "Done" in semibold primary
and " · 9:12 · took 2m 5s" secondary on one line, the timing under "Done" in footnote only when the line can't hold it (round 60: sa#3: a 32 pt seal beside two lines gave bookkeeping three lines' weight above the verdict). A turn that ends while its
thread is open (more than a second after opening, within 20 s of its end) and hasn't been shown
yet this launch signs in: the sheep settles from 0.9 with a slight overshoot as the disc grows
and the check pops in 80 ms behind, done by ~420 ms; opening a thread that already holds it,
scrolling back or reopening shows it still (round 15: opening a just-finished thread replayed
it as though it had just ended), and Reduce Motion shows it finished. "Took" is
the turn's length from the user's message, shown from 1 s (round 6 read "45m 52s"
as working time; round 7: the narrow form dropped the qualifier; round 14: "Finished" was a
third word beside the subtitle's and the Live Activity's "Done", and "45m 52s after your
message" under an approval read as the approval's response time). When the user approved or
answered during the turn (a non-denial `DecisionLog` entry between the turn's start and end),
it counts from that decision instead: "Took 12s after you approved" / "after you answered"
(round 15: "Took 45m 47s" under "You approved · 7:54" counted the wait for the user as the
agent's work). At accessibility sizes there is no header (round 42: sa#1, sb#1, opus#1: the seal and "Done"
took the lines the caution's end needed above the fade; the nav subtitle already says Done): a
closing caution leads if there is one (round 44: sa#1, sb#1: under a three-line verdict its end still fell into the fade), in the card's own column with no inset plate (round 45: sa#3, sb#8: the plate's 12 pt each side cost it lines) and as VoiceOver's first heading (round 45: sb#1: heading navigation landed past it on the verdict), then the verdict, as VoiceOver's next heading, the body, and a "Done · 9:12 ·
took 2m 5s" line closing the card (round 56: opus#4, sa#7: between the verdict and its findings it broke the reading for two large lines; round 38 had found it a scroll away there, the lesser cost now the caution leads) (round 40: sa#2, sb#6: under the time the caution sat a
screen down) (round 20: the clock and duration displaced the verdict). The header is a heading for VoiceOver's rotor ("Done 9:12, took 2 minutes, 5 seconds since your message"); a
gap under it (12 pt) and between the reply's paragraphs and lists (8 pt; code, tables and images 14 pt) sets the
header, verdict and body apart (round 14: one undifferentiated block of prose). A
short first paragraph of plain prose (one line of at most 140 characters, not a list or heading,
with more after it) is the reply's verdict and leads in `.title3.weight(.semibold)` ("No blocking findings in PR
#412."; round 9: verdict, reasons and caveat sat at one weight; round 38: as `.headline` it read
at the bullets' size); at accessibility sizes body-sized and semibold (round 41: sa#3, sb#15: title
sized there, it pushed the caution into the fade). At standard sizes too a closing caution comes before the verdict, under the header (round 49: sa#1, sb#4: "No blocking findings" led and was heard first, one order there and another at accessibility sizes). It states only what the transcript
records: no summaries are written for it. The body separates paragraph/list groups by
`Tokens.Space.s`; bold lead-ins such as "Before deploying:", "Next:", "Note:" and "Warning:" get
a callout marked by its semibold lead and a 3 pt rule, no glyph (VoiceOver says "Warning"; round 53: sa#14: an inline triangle beside the rule gave the first line a fussy indent; round 51: sa#7: in a gutter the caution sat deeper than the verdict under it; a callout holding a list keeps a glyph gutter so its items stay Markdown), the rule down its leading edge
(yellow for a warning, `Tokens.Tint.caution`, faint grey otherwise; round 78: opus#7: orange is Needs You's) rather than an inset plate (round 50: sa#2: a grey slab
inside the grey card read as assembled; round 48: sa#9: nested plates in the light), 12 pt from the words, 8 pt at accessibility sizes (round 51: opus#9: there the caution was a glyph alone) (round 52: sa#6: the triangle split "Before deploying" across lines there),
neither in a gutter beside them (round 40: sa#2, sb#6) nor on a line of its own (round 42) (round 36: the result read as a wall of similar
text and deployment caveats failed to stand out). A thread that isn't working (nothing being sent
either) opens, once per opening, on its latest turn whole (round 16: every
grader saw threads open on a request sliced through its letters under the fade). From where the
reader's last message sits (its frame in the transcript, reported as it lays out) and where the
end would rest: whole there already, the end; its top 30 pt or less above that view, its top just
under the bar's fade (the transcript's top content margin is the fade's 16 pt; round 16: a 24 pt
band), the turn's end then hiding only its padding; cut through there with 56 pt or less of it
showing (the fade included: rows still show, faded, under it), the end with that much room
below it (`restInset`, gone at the next message or send),
so it rests just out of view. Over a decision card the end stays on the card and the message's
foot shows under the fade, as a chat's does (round 19: room there read as an empty band above
the ask card; round 20: a fade run deeper over it read as a black band under the bar). Otherwise one that ends on such a reply opens at the card's top: a
card that fits still ends at the bottom, a longer one shows its Done line and verdict first, and
the newest is followed again once the reader reaches the end (round 10: at accessibility sizes
the review opened on its last lines). The agent counts as read only once the end is on screen
(within 80 pt), as always.
When a final top-level warning callout is present, it moves directly beneath the verdict and before the supporting body, without repeating it (round 39: sa#12, sb#2).

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
    `AttributedString`; the prose between code blocks, lists, tables and rules is one `Text`, so a
    selection runs across paragraphs; a list is a marker column and a text column, so wrapped
    lines hang under the text, not the bullet (round 22)),
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
  arrives while you're scrolled back stays unread. A read finish still says Done, with an outline check, under Earlier; reading a
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
- Alerts for Needs You and Done (round 14: "Finished"), each a Settings toggle that asks permission when turned
  on. They fire on a new unread state (one per pane and `state_change_seq`, remembered so a
  reconnect never repeats one), not for the conversation on screen, and are withdrawn once
  the agent is read or answered. Tapping one opens that agent. With Needs You on, the badge
  counts blocked agents across hosts; finished work is not a debt. The badge is recounted
  when Needs You is turned off or a host is removed.
- Waits herdr doesn't report (2026-10-30): omp's Plan Review leaves herdr `idle`/`done`, and a
  `bash` call with `pty: true` stopped at a prompt (`read -p`, a `[y/N]`, a password) leaves it
  `working` with no new `state_change_seq`. `HostConnection` looks for both in the conversations
  it has parsed (the inbox's eight most recent per host, plus any open one) after each activity
  read: `Conversation.pendingPlanReview`, or `Conversation.pendingTerminalInput` at least 10 s
  old whose console overlay (`ConsoleScreen`: `Console … ⟨running⟩` to `input forwarded to
  PTY`) is on the pane and either asks for input (`?`/`:` at the end, y/n, password) or stays
  the same for 10 s, so a dev server or `top` doesn't count. Such an agent presents as Needs You
  everywhere (`presentedStatus`: inbox, filter, counts, badge, dock, widgets, Live Activity) and
  is read by its wait id (PTY call or plan), kept apart from the sequence (`waitsSeen.…`). Its
  alert is once per wait (App Group `alertedWaits`), held back like other alerts while the push
  watcher owns the host. A Plan Review present at a link's first check after going live, or a
  terminal prompt confirmed on the same console the first read then saw, was the push
  watcher's to alert, so it stays silent here; a later prompt alerts. Plan Reviews settle with
  each check; consoles are read after (3 s cap each), and an omp finish is alerted only once its
  conversation was checked at that sequence, so a Plan Review never alerts as Finished first.
  The conversation shows the console with a reply field (y/n buttons when offered) that types
  into the pane only while the same command shows the same prompt the reply was written for;
  a typed reply is dropped when the prompt changes. In addition, omp, Claude and Codex panes
  are screen-probed after activity reads where a prompt can be, even outside the warm
  transcript cache: herdr says blocked, or the agent stopped with a tool call still open, or
  it has no transcript reference (omp without the integration reports an approval as idle).
  A working agent's screen is never read as a prompt. A parsed question, review or approval
  is a Needs You wait, independent of herdr's classification, and its row reads "Allow bash?
  Command: …" rather than the last message. Cursor/check changes retain the same wait;
  approval context and action changes create a new one. The first live probe is silent, and
  failed reads retain a known wait rather than pretending it closed. Alerts and badges use
  the existing wait path; this does not extend the away-from-app push watcher's detection.
  The demo `approval` scenario shows one (`-HerdwickDemo approval`, pane `p2`).
- The app only sees hosts while it runs. In the background iOS wakes it now and then
  (`BGAppRefreshTask`, earliest 15 min): it reconnects each link for one snapshot (20 s cap),
  which raises alerts and updates the widgets, then lets go.
- Widgets (`HerdwickWidgets`: Home small and medium, Lock Screen rectangular/circular/inline)
  read an `AttentionSnapshot` the app writes to the App Group: every visible agent as the app
  presents it (needs you, unread done, working, read done; newest change first within each), when
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
  alone. Per agent one `herdr agent wait` blocked on herdr's socket (measured on herdr 0.9.1: no CPU,
  no context switches in 20 s, ~6 MB), one `agent list` (~20 ms CPU) every 120 s for agents started
  meanwhile, one `curl` per alert, and it exits after 24 h or when herdr stops. While an agent
  works, the watcher probes its transcript tail (last 256 KB, `perl`/JSON::PP) every 15 s; the
  `agent wait` runs beside it and cuts the probe's sleep short, so a finish is never held back.
  A `bash` call with `pty: true` and no result after 10 s adds one pane read: once the console
  overlay (`⟨running⟩` … `input forwarded to PTY`) reads the same twice in a row, it posts
  `blocked` at the working sequence, once per call. An `idle`/`done` whose last record is omp's
  "Plan ready for review." (probed again after 2 s) posts `blocked` instead of done. Without
  JSON::PP the watcher only follows herdr's states, as before. No daemon, no port, no install.
  Settings lists each covered session with "Last armed <time>", why it was skipped
  (not connected, host not selected) or the error: a handoff, not proof of delivery.
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
  lingers as "done"; Hide Live Activity dismisses it at once. A tap on the card or the Dynamic
  Island opens that agent's conversation (its `AttentionLink`, as alerts do; round 9: it opened
  the inbox, which then had to be searched). The card (`WatchedRunWidget`) reads as the inbox
  does, in two tiers: on top the app's sheep (`HerdMark`, 34 pt,
   and 22 pt in the compact Island, wearing the run's mood as in the app: the cursor while it works, the
   orange badge when blocked, the check when done, the moon once closed or stale; round 91: opus#2, sa#9,
   the same still sheep on every card), the title (two lines; round
  17: the clock cut it to "Token-bucket rate li…") over "workspace · host", and at the trailing
  edge, while working, the elapsed time in title3 semibold in the status's tint over the word
  "elapsed" (round 17: a bare "1:48"), counting up from the message that started the turn
  (`ContentState.since`, the thread's "Working · 19m" time, else when watching
  began); under them a status chip (glyph and word in its tint on a 18% capsule: "Needs you",
  "Working", "Done", or "Update overdue" when stale) beside the agent's latest step on up to two
  lines in subheadline medium, primary (round 87: sa#14: in footnote it was the card's faintest line, under the name and the clock): what it asks while it needs you (the inbox's pending question; round 45: sb#2: "Needs you" sat over its last step), else the Now line's words while something runs ("Waiting on npm run bench"), else the newest
  call as its run's line says it ("Ran bun test move.test.ts"; `ContentState.detail`, sent
  by the app while it's open, only from the watched conversation, round 46: sb#1: every open thread fed it, so another agent's command could show under the title; optional so relay pushes without it still decode). Back at work after
  an answer, the clock counts from then (`ContentState.since`, the thread's `workingSince`; round 48:
  sb#2: it kept the first turn's start). A relay push carries the status alone, so the clock
  shows only while `since` is set and never falls back to a start in the attributes (round 49:
  sb#1: after a status-only push it counted from the first turn again). An agent gone from herdr (closed, or
  another agent in its pane) ends the card as "Closed", `xmark.circle` in grey, "No longer
  running in herdr.", not a green Done with an earlier turn's result (round 49: sb#2). A
  finished run's card says what it came to, the result's caution first, else its verdict, or
  "Finished. Open to read the result." with inbox previews off (round 48: sb#5: a Done card kept
  "Running bun test…"). The Dynamic
  Island shows the sheep and that clock compact (the glyph once it stops; stale, an overdue
  clock in grey there and in the minimal view, round 18: the timer ran on while the card said
  Update overdue), the sheep, title on up to two lines (round 18: one cut it), place and clock
  expanded with the chip and step below, and a keyline in the status's tint
  (round 12: three plain lines, "Finished" where the app says "Done", no glyph or time; round
  14: a bare timer apart from "Working" meant nothing, and nothing said what the agent was
  doing; round 15: a generic tinted disc read thin; round 16: four stacked lines with the
  status badged on the sheep read as a text slab, the time no larger than the words).
- "Answer from Notifications" (on by default; off restores the former "Reply in App" draft-and-open
  behaviour). Local Needs You approval alerts offer background Approve and Deny actions, using the
  current screen prompt; inline single-question asks offer an authenticated text Reply driven by
  the same verified prompt driver and recorded in the Decision Log. Done alerts offer an
  authenticated text Reply sent to the agent in the background. Every action requires Face ID or
  the passcode (round 36: graders repeatedly asked to approve or reply from an alert; the user
  overruled the former never-send rule). Safeguards, from the round 38 release audit:
  - Only the app's own alerts answer; a push, whatever category it names, only opens.
  - An answer needs the alert's exact wait (`waitID`) to still be the agent's current wait.
  - Approve (titled "Approve Once", round 57: opus#2, as the inbox and thread say it) picks only a plain one-time option ("Yes", "Yes, proceed", "Approve Once"), label and
    detail both, never a scoped grant such as omp's "Approve Directory" or a "Yes" wrapped onto
    "and don't ask again"; a prompt without one gets no Approve button.
    The label is read from the live screen, never from the payload.
  - The action wakes the host's own links (it never makes one that session discovery could stop
    mid-send), holds the host and session linked until it finishes, even a host not otherwise
    shown, and lets them sleep again in the background.
  - After 20 seconds it writes nothing more and says so.
  - Herdr's blocked alert arrives before the screen probe finds the prompt; once the wait is
    known, that alert, if still in Notification Centre, is replaced quietly by one with actions.
  A changed prompt or unavailable host sends nothing, keeps typed text as a draft and posts an
  explanatory local alert. Alerts while away (relay pushes) carry no command text, so they offer
  no actions and open the conversation: approving a command the alert can't show would be blind.
- Host clock: once per connection the app samples `date +%s`; if the host is more than a minute
  off beyond the round trip, Panes shows a warning under that host. It's only a warning.
- Ruled out: CloudKit (web tokens are single-use), Local Push Connectivity (restricted
  entitlement, named Wi-Fi only), Tailscale (the phone's node is down while suspended).
  T3 Code's "settled" shelf was not adopted:
  Hide already parks work and resurfaces it when it needs you.

## Subagent transcript state
Core derives working children from omp `task`, Claude `Agent`/`Task`, and Codex
`spawn_agent` calls. omp async-result notices may complete multiple children; wait
results and notices coalesce into one result per child, with cancellation taking
precedence. Result rows remain in Messages Only. Claude async launch results replace the
provisional call ID with `agentId`; completed results retain their content. These
Claude result shapes are synthetic fixtures pending a captured real transcript.
Codex close calls cancel the child; Codex transcript drill-in is unavailable.
Child-file reconciliation only transitions working children: session exit completes,
tombstone cancels, missing/active leaves state unchanged. File probes share one exec.

## Ask
Tier A, structured (omp `ask`, Claude `AskUserQuestion`; Codex `request_user_input` is detected
by name, but the driver doesn't know its prompt, so that card only offers "Answer in Terminal"):
a pending ask is a tool call with no result yet.
`arguments.questions[] = {id?, header?, question, options[{label, description, preview?}],
multi?|multiSelect?, recommended?}`. `AskPanel` pages the questions ("HEADER · 1 OF 2"), each question in body semibold, as the inbox row sets it (round 72: sa#5: in body regular it read weaker than in the inbox), after Needs You's orange glyph as the approval card's title has it (round 75: opus#10: the two waiting cards looked like different things):
a one-question single-select ask sends the tapped option at once (the tapped option reads
"Answering…" with a spinner while the driver runs and the panel stops taking taps, the chosen option without
greying out and heard as progress, not a button, the others, Other Answer and Answer in Terminal disabled so VoiceOver doesn't offer them, round 75: sb#1, round 76: sb#2; options are full-width `choiceButton`s on the inset surface in a grey hairline, and only the agent's own
recommended option is washed in the accent inside an accent hairline (`ChoiceStyle`, primary words as the rest; round 28: a green tint under green words read muddy; round 29: a grey fill read disabled), never filled, and says "Recommended" in an accent footnote over its label, which VoiceOver hears in the option's label as the inbox's do (round 12: only as a hint, lost with hints off) (round 6: the tint alone read as disabled beside a filled Approve; round 11: a lone tinted option read as already chosen); on a one-tap ask, where a tap sends it, it carries the inbox's send arrow in a trailing column, its ⌘ hint under it as the inbox's (round 88: opus#1, sa#3: the hint still sat in the top corner here, two layouts for one tile), inline before the label at accessibility sizes (round 49: sa#2: outlined here it read as an informational inset); VoiceOver hears "Sends now" at the end of every one-tap option's label, the inbox's too (round 54: sb#1), and the inbox's hint, "Answers “…” on the agent's screen." (round 53: sb#1; round 52: sb#1), with
"Other Answer…" (with `square.and.pencil`, beside Answer in Terminal on one line where they fit, round 89: opus#11: two loose links of different leading read as stray text) opening the "Other answer" and note editor first; with several questions a tap
selects and Next/Send moves on. Multi-select shows checkboxes with Back/Next/Send. An ask the
driver can't drive shows "Answer in Terminal" as its one action. On omp, "Other" also sits under checkboxes
and joins the checked options, and each question takes an optional note (omp's `n`, typed into
its note editor and confirmed back on the question); an option's `preview` shows under it, and
VoiceOver hears each option as its label, description and "Preview: …" (round 6: the
description and preview were silent).
Shown above the composer while herdr says `blocked` or a screen-confirmed wait presents as
Needs You. Answered asks show each question's own answer (`AskAnswer.perQuestion`)
and its note as a quote (a leading rule, no card). omp's "Chat about this" isn't offered.
Ask, approval and console-input cards share one shape: the raised surface at the card radius,
context on inset plates, `choiceButton` rows, and "Answer in Terminal" (or Open Terminal) as
an iconed inline action. An approval is the exception in its buttons (see Tier B). A short conversation sits at the top of the screen, not the bottom
(`.defaultScrollAnchor(.top, for: .alignment)`), except under a decision card, where it sits on
the card so the question follows its context (round 18: an empty band between them); it still opens at its end.

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
4. Wait for the prompt to settle on the next question, the review page, or (after the last
   question) no prompt. The screen trails the keys: the reads right after `enter` in omp's
   "Custom answer" box still show the box, and a frame caught mid-redraw can parse as nothing
   or as an unknown question, so those keep it waiting (up to `settle`) instead of failing. Before
   this, every omp "Other" answer (single, multi-select, several questions) was taken by omp but
   reported "The agent's prompt changed partway through", leaving the next question open so a
   retry said "a different prompt". Reproduced and verified fixed 2026-10-23 in a throwaway herdr
   session against omp 18.12.6 (Haiku): "Other" alone, first and last of two questions, beside
   checkboxes, after a multi-select question, with a note, and multi-line text.
5. Confirmed only when the transcript shows the `toolResult` for that `toolCallId` (10 s);
   the card then shows the answer in the history. Any failure → alert with "Open Terminal",
   and "Try Again" while the ask is still pending (not for answers only the terminal takes).

2026-10-30, multiple-choice asks left open on omp's "Review answers" page with the cursor on
Submit (reproduced live). The driver took any read with no prompt after the last question as
the end and only waited for a result; a frame caught mid-redraw while the review page draws
reads that way (the likely path to the stuck page). Now, until the result is logged
(`confirmTimeout`), it keeps reading: a review page
of this ask is still submitted. `answer` also resumes from a later matching question or the
review page, which is what Try Again runs (after checking whether the result has arrived
meanwhile). A review page is submitted only when its tab row matches the ask's questions (a
single question: none, or its own one) and every recorded answer agrees with the replies,
matched by the whole row label: each chosen option and custom text present, no unchosen option
and no `Other:` text when none was sent, and the note (omp's `Note:` row) equal to the one sent,
or a prefix of it only when the row is cut short with "…". The
alert's copy no longer claims nothing was sent once keys may have landed. Live,
`HERDWICK_LIVE=1 swift test --filter LiveAskDriverTests` (omp 18.12.6, Haiku, a throwaway
session): single, multi-select and mixed asks at the default size and in a 48-column pane, each
confirmed by the transcript's `toolResult` and no prompt left on screen.

2026-11-03, approval and rich-question reliability:
- A freshly painted omp approval ignored an immediate Enter twice in the live test
  (`notConfirmed`, same dialog still visible), while a later manual Enter succeeded. The
  driver now allows 500 ms for initial input readiness, then re-reads and verifies the
  complete choice plus its cursor before sending Enter. This repaired the live approval
  case without retrying a potentially consequential Enter.
- Live omp 18.12.6 approval captures show `blocked` with the herdr integration; disabling
  extensions leaves the same visible approval classified `idle`. The transcript already
  contains the assistant's tool call and `tool_execution_start`, but no result. Thus a
  tool-start record alone is not evidence that the tool has permission to run.
- Current approvals include “Approve bash for this session”, “Approve Once”, “Approve File”
  and “Approve Directory”, not just Approve/Deny. The old parser omitted these logical
  rows, so moving to Deny could land on an approval instead. All captured action rows now
  participate in closed-loop cursor checks; help text below the action divider does not.
- A real markdown heading (`## Deployment 🐑`) was retained in transcript comparison even
  though omp rendered no hashes. Block headings and fenced-code markers are normalized,
  while unmarked partial question titles no longer match arbitrary prefixes. Scrolling
  may change the displayed title's truncation, so movement verifies the question through
  its full matching predicate instead of also requiring a byte-identical viewport title.
- Ask content uses the existing Markdown renderer and a capped scroll region, so long
  questions, descriptions, previews and options remain reachable. Permission context is
  scrollable rather than clipped by a physical-line count (one long row can wrap past ten
  lines). Cards always offer Answer in Terminal; terminal-only context is explicitly labelled.
- Real captures are `omp-approval-session`, `omp-approval-cached-write`, and
  `omp-matrix-wide` with sanitized transcript fixtures. Unit replays exercise every captured
  approval action and reject changed option details. Live coverage adds rich Other answers
  with quotes, a newline and emoji at 48 and 120 columns, plus a real tool approval.


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
`PermissionCard` shows them as a decision (UX round 1, 2026-11-04; it had shown every option
alike): a plain yes/approve/allow is the prominent button (omp's bare "Approve" shown as "Approve Once" beside a lasting grant, the inbox's Approve too when the grant is in its "…" menu (round 57: sb#1), the option chosen still the screen's; round 56: sa#15, its scope was left to be inferred), a lasting variant ("… for this
session", "don't ask again", "always") a neutral `choiceButton` that names its scope, a
no/deny/reject a neutral `choiceButton` too (round 5: a red-tinted slab read as a warning beside
the inbox row's neutral Deny), and anything else neutral. Classification is by
label, scope first, since "Yes, and don't ask again" is a yes. With both a yes and a no, they sit
side by side when their labels fit, each label centred in its half (stacked and leading-aligned
otherwise, and always at accessibility sizes), Deny at its own width (at least 96 pt) and Approve taking the rest, as the inbox and the onboarding sample size them (round 60: opus#6: equal halves here, unequal in the inbox); the lasting grants follow under a hairline as
borderless rows of their own (round 8: a grey slab made one as heavy as Deny), a
`clock.badge.checkmark` mark in secondary beside the label in plain text colour (round 22: `.primary` in a borderless button took the green tint, a second green action under Approve) over "Won't ask again for matching
requests" in footnote, and confirm in a dialog before they're given ("Matching requests from
this agent won't ask you again."; round 7: a quiet text action, it read as one more link, like
Answer in Terminal, with nothing saying it lasts; round 5: three stacked slabs made the safe
choice hard to find); the inbox row's "…" menu and context menu ask the same before granting
(`grantConfirmation`; round 8: they granted it at once), then anything else. Without the pair, the options
come in turn, then the grants. VoiceOver hears an option with its detail
(round 6). The chosen option says "Approving…",
"Denying…" or "Choosing…" with a spinner at full contrast and is heard as progress, not a button;
the others are disabled meanwhile, so VoiceOver doesn't offer them, and a lasting grant being
chosen doesn't ask again on a second tap (round 77: sb#1: they only ignored taps; round 78: sb#1). The command sits on the inset plate in selectable `.callout` primary monospace,
naturally wrapped, with any "Read from the screen; may be incomplete" caveat directly beneath it (round 36:
the most consequential content was the smallest text); without omp's own "Command:" label (the
plate already says it), long context expands to all lines. When the context was read off the screen
and may be cut short, the caveat says so (`text.viewfinder`; round 23: "Command shortened" claimed a cut
on a command shown whole; round 4: without it the plate looked complete; round 6 dropped "Read off
beside it, caveat and link read as one dense annotation), and the card's one terminal link then
reads "Inspect in Terminal", else "Answer in Terminal" (round 14: a second link under a
shortened plate repeated it; round 2: a separate "Full text in the terminal"
caption had sat orphaned under the plate). A tap runs `PromptDriver.choose` (↑/↓ re-reading after each,
Enter), confirmed by the prompt leaving the screen; the slot it leaves then shows what was sent
in the past tense ("Approved once", so the record keeps the scope the card drew, round 79: sb#3;
"Approved · this session" for a scoped yes, "Denied" with a red
cross; its mark bouncing once, a fade under Reduce Motion) for 2.5 s; an answered ask shows
"Answered “…”". VoiceOver hears the same receipt. Verified in the app: Claude Bash Yes (ran)
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
6. Comfort rework (2026-11-03, from two adversarial reviews, a Sol council and a tie-break):
   Mail-style Select with bulk Mark Read/Hide/Close, host chips
   instead of the title swipe, Panes as a sheet instead of a view switch, View menu as the one
   home of inbox options, plain dictation card,
   fixed dock order, one-tap single-question asks, New Agent's Draft Message and Options group,
   iOS-Settings-style Settings (Hosts; SSH Key, Tailscale, Notifications, Privacy;
   Conversations, Composer & Dictation, Appearance & Terminal; About), the feed's backlog
   decoded off the main actor and a bounded Markdown cache. Built. Deferred: Approve from a
   notification, answer pills in inbox rows, auto-sending the first message, hold-to-talk and a
   lazy transcript (each needs its own driver, protocol or measurement work first).
