# Marketing assets

Every app screen in the listing is the real app, built from this tree, running the scripted
demo host (`Packages/HerdwickCore/Sources/HerdrDemo`) in the simulator. To refresh
the assets from a newer build, run the two steps again:

```sh
marketing/capture.sh   # build on the Mini, capture every scene and the previews
marketing/render.sh    # compose stills, previews, social and press; validate
```

Both run on the Mini (`MINI=<host>` overrides `mini`) and copy their results back into
`marketing/build/`, which is ignored by git.

## Pipeline

1. **Scenario** (`HerdrDemo/Scenarios/`): the fake host's sessions, panes, terminal screens
   and timeline. See `Scenarios/README.md` for the format and the `.screen` markup.
2. **Capture** (`capture/capture.mjs`, run with bun): for each device in `scenes.json`,
   boots the simulator, overrides the status bar (9:41, full battery), installs the app and
   launches each scene with `-HerdwickDemo studio` and the scene's arguments. It waits
   for the app to write `Documents/demo-ready`, then takes the screenshot and checks its
   size. The preview launches with `-HerdwickHold YES`, starts recording, releases the
   hold by writing `Documents/demo-go`, and records the scenario's duration plus 1.5 s.
   Output: `build/captures/<device>/<scene>.png`, `preview.mov` and `preview.json`.
3. **Compose** (`compose/render.mjs`, run with node; bun's Playwright crashes Chrome on
   macOS): lays captures into HTML at the exact output size, renders them in Chrome, then
   strips alpha with ImageMagick. Videos go through ffmpeg. Layout and copy live in
   `slides.json`. `node render.mjs stills|previews|social|press` renders only those parts.
4. **Validate** (`compose/validate.mjs`): checks pixel sizes, no alpha, and the App Preview
   video specs (H.264, 30 fps, 15–30 s, stereo AAC).

## Scene arguments

| Argument | Effect |
| --- | --- |
| `-HerdwickDemo <scenario>` | Connect to the bundled demo scenario instead of a real host. |
| `-HerdwickScene <scene>` | `agents`, `workspaces`, `pane:<id>`, `onboarding`, `tailscale` or `settings`. |
| `-HerdwickDraft <text>` | Pre-fill the open pane's composer. |
| `-HerdwickDrop YES` | Drop the link once live, to show reconnecting. |
| `-HerdwickHold YES` | Hold the timeline until `Documents/demo-go` exists. |

App settings pass the same way (`-appearance dark -theme.dark gruvbox-dark -fontSize 14`).
`defaults` in `scenes.json` applies to every scene, then the device's `args` (the iPad
uses a larger terminal font), then the scene's own; later values win.

## Outputs (`build/out/`)

| Path | What |
| --- | --- |
| `appstore/en-US/iphone-69/NN-<id>.png` | iPhone 6.9" screenshots, 1320×2868 |
| `appstore/en-US/ipad-13/NN-<id>.png` | iPad 13" screenshots, 2064×2752 |
| `appstore/en-US/<device>/preview.mp4` | App Previews (886×1920 iPhone, 1200×1600 iPad) |
| `appstore/en-US/iphone-69/preview-poster.png` | Poster frame, 5 s in |
| `social/og-1200x630.png`, `x-card-1600x900.png` | Link cards |
| `social/launch-1080x1920.mp4`, `launch-1920x1080.mp4` | Launch videos |
| `press/hero-3840x2160.png`, `icon-2048.png` | Press kit |

## Listing

`listing/` follows fastlane `deliver` layout (`en-US/*.txt`, categories, review notes).
`listing/app-store-connect.md` covers the fields set by hand (privacy, age rating) and
the trademark rules for mentioning herdr and Tailscale. `launch.md` has the launch posts.

## Rules

- Only real captures, with text overlays and framing. No mocked UI (guideline 2.3.4 for
  previews).
- No Apple, herdr or Tailscale logos. Tailscale is named in plain text only.
- Fonts in `compose/fonts` are OFL (`OFL.txt`).
