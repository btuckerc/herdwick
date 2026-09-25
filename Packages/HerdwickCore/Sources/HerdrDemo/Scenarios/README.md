# Demo scenarios

A scenario is a scripted herdr host that `DemoHost` serves through the app's real
`CommandRunner` seam. The app runs unchanged against it: in Release it drives the
"Explore a demo host" onboarding path, and in Debug it drives every marketing capture
(`marketing/scenes.json`).

Each scenario is a directory holding `scenario.json`, plus usually a `screens/` folder.

## scenario.json

| Key | Meaning |
| --- | --- |
| `extends` | Name of a sibling scenario to start from. Keys set here replace the base's keys; `setup` and `timeline` are never inherited. |
| `host` | `{name, address, user}` shown as the connected host. |
| `herdr` | `{version, protocol}` returned by `ping`. |
| `sessions` | The `session list --json` result. |
| `snapshot` | The `session.snapshot` result: workspaces, tabs, panes, agents. The ids here are the only valid `pane` values. |
| `screens` | Pane id → `.screen` file, the pane's first frame. |
| `transcripts` | Pane id → omp `.jsonl` file. Adds the agent's `agent_session` path and opens chat rather than the terminal. |
| `childTranscripts` | Parent pane id → child id → omp `.jsonl` file. Child ids must be simple letters, digits, hyphens or underscores. |
| `tailnet` | `{name, peers[]}`, the machines the Tailscale screen lists. Each peer is `{id, name, dnsName, address, online, ssh}`. |
| `setup` | Steps applied before anything is served, without `t`. |
| `timeline` | Timed steps and triggers (see below). |

Paths resolve relative to the file that declares them, so an extending scenario points at
the base's screens or transcripts with `../studio/…`. Transcript records must be valid
JSON objects with a `type`, one per line, including a final newline. Transcripts require
an existing agent; children and append steps require a declared parent transcript.
The fake host uses `/Users/alex/.omp/agent/sessions/studio/<pane>.jsonl`; child files
live under `<pane>/<child>.jsonl`. These paths never touch a real host or filesystem.

## Steps

A step is `{"do": …}` plus its arguments:

- `status`: `pane`, `status` (`idle`, `working`, `blocked`, `done`). Patches the pane,
  agent, tab and workspace roll-ups and pushes `pane_agent_status_changed`.
- `screen`: `pane`, `screen` path. Repaints every terminal attached to the pane.
- `append`: `pane`, `records` path. Appends those JSONL records to the pane's transcript
  and streams the bytes to every open follower. Works in setup, timelines and triggers.
- `drop`: optional `for` seconds. Closes every channel and refuses new ones until it
  recovers; without `for` the host stays down.
- `ui`: `cue` is one of `openPane` (`pane`), `back`, `mode` (`text`: `agents` or
  `workspaces`), `draft` (`text`), `send` or `sheet` (`text`: a sheet name, or omitted to
  dismiss). The app's `DemoDirector` performs cues through the same paths a tap would use.

In `timeline`, a timed step adds `"t"`: seconds after `DemoHost.startClock()`. A trigger is
`{"on": "send_input" | "send_keys", "pane", "then": [steps with "after" seconds]}` and fires
each time the app sends to that pane.
For omp radio prompts, arrow keys move the scripted screen cursor without firing a
trigger; Enter fires `send_keys`. Author the terminal Ask box and transcript question
with matching labels so the real `PromptDriver` can verify submission.

The scenario's `duration` is the last `t`, plus `for` on a drop. `marketing/capture` records
the preview for that long plus 1.5 s.

Everything is validated at load: an unknown pane, status, step or cue throws
`DemoError.invalidScenario`. `DemoHostTests` loads every bundled scenario.

## .screen markup

Plain text laid out at the terminal's current size and sent as a full ANSI frame. The 16
ANSI colours are used so the user's theme recolours the screen.

- Styles: `<b>`, `<dim>`, `<i>`, `<u>`, `<inverse>`.
- Colours: `<red>`, `<green>`, `<yellow>`, `<blue>`, `<magenta>`, `<cyan>`, `<white>`, `<gray>`.
- `</>` resets all styles; every row also resets at its end.
- `<rule>` fills the rest of the line with `─`.
- A line holding only `<footer>` pins the lines after it to the bottom rows. When the body
  is too tall, its last lines stay visible above the footer.
- Long lines word-wrap. A line starting with a short bullet (`●`, `⎿`, `>`) wraps with a
  hanging indent under its text.

## Scenarios here

- `studio`: host `studio`, user `alex`, four workspaces and seven panes. `p1` (omp,
  "Deploy to staging") is blocked on a question; its triggers append the answer, run
  migrations and deploy. `p2` has a finished review. `p5` shows delegated rate-limiter
  checks: one completed child and one working child. `p6` remains a plain shell.
- `preview`: extends `studio` and scripts the App Preview (19.5 s): p1 turns blocked, the
  pane opens, a reply is typed and sent, the agent finishes, the list returns, and the link
  drops for 2.5 s and recovers.
- `replied`: `studio` after the reply, with p1 done and its deploy output on screen.

## Conversation captures

Launch the built app with `-HerdwickDemo studio` plus the arguments below, on either
iPhone or iPad. Wait for `Documents/demo-ready` before taking the screenshot.
No special capture script is needed; these run the actual conversation UI.

| Scene | Arguments |
| --- | --- |
| Conversation / finished review | `-HerdwickScene pane:p2 -detailLevel folded` |
| Conversation question and composer | `-HerdwickScene pane:p1 -detailLevel folded` |
| Working tray and completed subagent | `-HerdwickScene pane:p5 -detailLevel folded -showWorkingSubagents YES` |
| Machines | `-HerdwickScene agents -inboxView machines` |
| Forced terminal, even with a transcript | `-HerdwickScene terminal:p1` |

`pane:<id>` and `openPane` select conversation using the same `hasTranscript` rule as
the inbox. `terminal:<id>` overrides it. `-HerdwickDraft "…"` and timeline `draft`/`send`
cues work in either composer. Readiness waits for the transcript backlog to paint,
or for the first terminal frame. `preview` opens p1 as chat and sends its scripted
reply; `replied` starts with the appended answer and completed deployment.

