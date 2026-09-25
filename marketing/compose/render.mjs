// Composes App Store stills, App Previews, social and press assets from the simulator
// captures in marketing/build/captures/ (see marketing/capture.sh) into marketing/build/out/.
// Layout and copy live in marketing/slides.json. Runs on the Mini: Chrome via Playwright,
// ffmpeg and ImageMagick.
import { chromium } from 'playwright';
import { mkdir, readFile, rm, access, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const marketing = resolve(here, '..');
const captures = join(marketing, 'build/captures');
const out = join(marketing, 'build/out');
const work = join(marketing, 'build/work');
const manifest = JSON.parse(await readFile(join(marketing, 'slides.json'), 'utf8'));
const palette = manifest.palette;
const icon = resolve(marketing, '../App/Assets.xcassets/AppIcon.appiconset/AppIcon.png');
const only = process.argv.slice(2); // e.g. `stills`, `previews`, `social`, `press`
const wants = part => only.length === 0 || only.includes(part);

const url = path => 'file://' + path;
const esc = s => String(s).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
const lines = s => esc(s).replaceAll('\n', '<br>');
const capture = (device, name) => join(captures, device, `${name}.png`);
const exists = async p => { try { await access(p); return true; } catch { return false; } };

function run(cmd, args) {
  return new Promise((res, rej) => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'inherit', 'inherit'] });
    p.on('exit', code => (code ? rej(new Error(`${cmd} exited ${code}`)) : res()));
  });
}

// MARK: HTML

const baseCSS = `
@font-face { font-family: Head; src: url('${url(join(here, 'fonts/InterTight-Bold.ttf'))}'); }
@font-face { font-family: Mono; src: url('${url(join(here, 'fonts/JetBrainsMono-Medium.ttf'))}'); }
* { box-sizing: border-box; margin: 0; }
html, body { width: 100%; height: 100%; overflow: hidden; background: transparent; }
.canvas { position: absolute; inset: 0; overflow: hidden; }
h1 { font-family: Head; font-weight: 700; letter-spacing: -0.035em; line-height: 0.98; }
p { font-family: Mono; letter-spacing: -0.01em; line-height: 1.3; }
.shot { position: absolute; overflow: hidden; }
.shot img { display: block; width: 100%; height: 100%; object-fit: cover; }
.bezel { position: absolute; border: solid rgba(255,255,255,0.13); pointer-events: none; }
`;

function page(body, css = '') {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${baseCSS}${css}</style></head><body>${body}</body></html>`;
}

/// A screen capture with rounded corners, a hairline bezel and a soft shadow.
function shot(src, { x, y, w, h, r, rotate = 0, day = false, shadow = true }) {
  const bezel = Math.max(2, Math.round(w / 360));
  const style = `left:${x}px;top:${y}px;width:${w}px;height:${h}px;border-radius:${r}px;transform:rotate(${rotate}deg)`;
  const glow = shadow ? `box-shadow:0 ${Math.round(w / 18)}px ${Math.round(w / 6)}px rgba(0,0,0,${day ? 0.18 : 0.55})` : '';
  return `<div class="shot" style="${style};${glow}"><img src="${url(src)}"></div>` +
    `<div class="bezel" style="${style};border-width:${bezel}px;border-color:${day ? 'rgba(0,0,0,0.10)' : 'rgba(255,255,255,0.13)'}"></div>`;
}

function glow(accent, { x, y, size, opacity = 0.2 }) {
  return `<div style="position:absolute;left:${x - size / 2}px;top:${y - size / 2}px;width:${size}px;height:${size}px;border-radius:50%;background:${accent};filter:blur(${Math.round(size / 4)}px);opacity:${opacity}"></div>`;
}

function header(slide, { x, y, width, head, sub, align = 'left', day = false }) {
  const text = day ? palette.dayText : palette.text;
  return `<header style="position:absolute;left:${x}px;top:${y}px;width:${width}px;text-align:${align}">
    <h1 style="font-size:${head}px;color:${text}">${lines(slide.headline)}</h1>
    <p style="font-size:${sub}px;color:${slide.accent};margin-top:${Math.round(head * 0.34)}px">${lines(slide.subline)}</p>
  </header>`;
}

/// iPhone still layouts at 1320×2868; iPad at 2064×2752.
const stillLayouts = {
  phone(slide, W, H) {
    const w = 1060, h = Math.round(w * H / W), x = (W - w) / 2, y = 700;
    return glow(slide.accent, { x: W * 0.78, y: 1500, size: 1300, opacity: 0.16 }) +
      header(slide, { x: 130, y: 210, width: W - 260, head: 124, sub: 44 }) +
      shot(capture('iphone', slide.capture), { x, y, w, h, r: 150 });
  },
  loupe(slide, W, H) {
    // The whole phone, and a magnified band of it (`slide.band`: top and bottom as
    // fractions of the capture's height) in a card laid over its upper half.
    const w = 940, h = Math.round(w * H / W), x = (W - w) / 2, y = H - h - 90;
    const [top, bottom] = slide.band;
    const cw = 1200, scale = cw / W, ch = Math.round((bottom - top) * H * scale);
    const src = capture('iphone', slide.capture);
    const card = `<div style="position:absolute;left:${(W - cw) / 2}px;top:${y + h * top - ch - 150}px;width:${cw}px;height:${ch}px;
        border-radius:56px;overflow:hidden;border:4px solid ${slide.accent};box-shadow:0 50px 140px rgba(0,0,0,.7)">
        <img src="${url(src)}" style="position:absolute;left:0;top:${-top * H * scale}px;width:${cw}px">
      </div>`;
    return glow(slide.accent, { x: W * 0.5, y: y + h * top, size: 1400, opacity: 0.14 }) +
      header(slide, { x: 130, y: 210, width: W - 260, head: 124, sub: 44 }) +
      shot(src, { x, y, w, h, r: 134 }) + card;
  },
  trio(slide, W, H) {
    const [a, b, c] = slide.captures.map(name => capture('iphone', name));
    const side = 640, sh = Math.round(side * H / W), mid = 760, mh = Math.round(mid * H / W);
    return header(slide, { x: 130, y: 210, width: W - 260, head: 124, sub: 44, day: true }) +
      shot(a, { x: -60, y: 1060, w: side, h: sh, r: 90, rotate: -5, day: true }) +
      shot(c, { x: W - side + 60, y: 1060, w: side, h: sh, r: 90, rotate: 5, day: true }) +
      shot(b, { x: (W - mid) / 2, y: 860, w: mid, h: mh, r: 108, day: true });
  },
  tablet(slide, W, H) {
    const w = 1720, h = Math.round(w * H / W), x = (W - w) / 2, y = 640;
    return glow(slide.accent, { x: W * 0.8, y: 1400, size: 1500, opacity: 0.14 }) +
      header(slide, { x: 172, y: 190, width: W - 344, head: 128, sub: 46 }) +
      shot(capture('ipad', slide.capture), { x, y, w, h, r: 64 });
  },
};

// MARK: Rendering

let browser, tab;
async function openBrowser() {
  try {
    browser = await chromium.launch({ channel: 'chrome' });
  } catch {
    browser = await chromium.launch();
  }
  // One tab for everything: Chrome on macOS quits when its last page closes.
  tab = await browser.newPage({ deviceScaleFactor: 1 });
}

async function png(html, W, H, file, { transparent = false } = {}) {
  // Loaded from a file so the page may reference captures and fonts by file URL.
  const source = file.replace(/\.png$/, '.html');
  await writeFile(source, html);
  await tab.setViewportSize({ width: W, height: H });
  await tab.goto(url(source), { waitUntil: 'load' });
  await tab.evaluate(() => document.fonts.ready);
  await tab.screenshot({ path: file, type: 'png', omitBackground: transparent });
  await rm(source);
  // App Store Connect rejects alpha; overlays for ffmpeg keep it.
  if (!transparent) await run('magick', [file, '-background', palette.canvas, '-alpha', 'remove', '-alpha', 'off', file]);
}

async function stills() {
  const devices = { iphone: ['iphone-69', 1320, 2868], ipad: ['ipad-13', 2064, 2752] };
  for (const [device, [dir, W, H]] of Object.entries(devices)) {
    const target = join(out, 'appstore/en-US', dir);
    await rm(target, { recursive: true, force: true });
    await mkdir(target, { recursive: true });
    for (const [i, slide] of manifest.stills[device].entries()) {
      const canvas = slide.day ? palette.dayCanvas : palette.canvas;
      const body = `<main class="canvas" style="background:${canvas}">${stillLayouts[slide.layout](slide, W, H)}</main>`;
      const file = join(target, `${String(i + 1).padStart(2, '0')}-${slide.id}.png`);
      await png(page(body), W, H, file);
      console.log(`still ${dir}/${String(i + 1).padStart(2, '0')}-${slide.id}`);
    }
  }
}

// MARK: Video

/// Encoder settings App Store Connect accepts for previews; social cuts reuse them.
const h264 = ['-c:v', 'libx264', '-profile:v', 'high', '-level:v', '4.0', '-pix_fmt', 'yuv420p', '-r', '30',
  '-b:v', '11M', '-maxrate', '12M', '-bufsize', '24M', '-c:a', 'aac', '-b:a', '256k', '-ar', '48000', '-ac', '2',
  '-movflags', '+faststart'];

/**
 * Puts the recorded screen into `screen` on a W×H canvas, with a caption layer per caption.
 * `captionHTML(text)` returns the caption markup for this format. `framed` draws the canvas
 * around a rounded window with a bezel; App Store previews pass false and fill the frame
 * with the capture itself (guideline 2.3.4: captures of the app plus text overlays).
 * `endCard` (HTML) fades in over a held last frame for `endHold` seconds.
 */
async function composeVideo({ device, W, H, screen = { x: 0, y: 0, w: W, h: H }, framed = true, captionHTML, file, endCard = null, endHold = 0 }) {
  const meta = JSON.parse(await readFile(join(captures, device, 'preview.json'), 'utf8'));
  const { lead, tail, captions } = manifest.preview;
  const length = lead + meta.duration + tail;
  const total = length + endHold;
  const dir = join(work, `${device}-${W}x${H}`);
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true });

  // Overlays in order: the window frame when framed, then captions, then the end card.
  const layers = [];
  if (framed) {
    const frame = join(dir, 'frame.png');
    const bezel = Math.max(2, Math.round(screen.w / 360));
    await png(page(`<main class="canvas">
        <div style="position:absolute;left:${screen.x}px;top:${screen.y}px;width:${screen.w}px;height:${screen.h}px;border-radius:${screen.r}px;box-shadow:0 0 0 ${W + H}px ${palette.canvas}, inset 0 0 0 ${bezel}px rgba(255,255,255,0.13)"></div>
      </main>`), W, H, frame, { transparent: true });
    layers.push({ file: frame, start: 0, end: total, still: true });
  }
  for (const [i, caption] of captions.entries()) {
    const png_ = join(dir, `caption-${i}.png`);
    await png(page(`<main class="canvas">${captionHTML(caption.text)}</main>`), W, H, png_, { transparent: true });
    layers.push({ file: png_, start: caption.start + lead, end: Math.min(caption.end + lead, length) });
  }
  if (endCard) {
    const png_ = join(dir, 'end.png');
    await png(page(`<main class="canvas" style="background:${palette.canvas}">${endCard}</main>`), W, H, png_);
    layers.push({ file: png_, start: length, end: total });
  }

  const inputs = ['-f', 'lavfi', '-i', `color=c=${palette.canvas}:s=${W}x${H}:r=30:d=${total}`,
    '-ss', String(Math.max(0, meta.goAt - lead)), '-t', String(length), '-i', join(captures, device, 'preview.mov')];
  for (const layer of layers) inputs.push('-loop', '1', '-t', String(total), '-i', layer.file);
  inputs.push('-f', 'lavfi', '-t', String(total), '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000');

  const fade = 0.25;
  const graph = [
    `[1:v]fps=30,scale=${screen.w}:${screen.h}:flags=lanczos,setsar=1,tpad=stop_mode=clone:stop_duration=${endHold + 1}[screen]`,
    `[0:v][screen]overlay=${screen.x}:${screen.y}:shortest=0[b0]`,
  ];
  let last = 'b0';
  layers.forEach((layer, i) => {
    const input = 2 + i;
    if (layer.still) {
      graph.push(`[${last}][${input}:v]overlay=0:0[c${i}]`);
    } else {
      const fadeOut = layer.end >= total ? '' : `,fade=t=out:st=${(layer.end - fade).toFixed(2)}:d=${fade}:alpha=1`;
      graph.push(`[${input}:v]format=rgba,fade=t=in:st=${layer.start.toFixed(2)}:d=${fade}:alpha=1${fadeOut}[l${i}]`);
      graph.push(`[${last}][l${i}]overlay=0:0:enable='between(t,${layer.start.toFixed(2)},${layer.end.toFixed(2)})'[c${i}]`);
    }
    last = `c${i}`;
  });
  graph.push(`[${last}]trim=duration=${total},setpts=PTS-STARTPTS,format=yuv420p[v]`);
  const audio = 2 + layers.length;

  await run('ffmpeg', ['-v', 'error', '-y', ...inputs, '-filter_complex', graph.join(';'),
    '-map', '[v]', '-map', `${audio}:a`, '-t', String(total), ...h264, file]);
  console.log(`video ${file.slice(out.length + 1)} (${total.toFixed(1)} s)`);
}

function topCaption(W, size, y) {
  return text => `<h1 style="position:absolute;left:0;top:${y}px;width:${W}px;text-align:center;font-size:${size}px;color:${palette.text}">${esc(text)}</h1>`;
}

/// A caption on an opaque band across the top, over the status bar.
function bandCaption(W, band, size) {
  return text => `<div style="position:absolute;left:0;top:0;width:${W}px;height:${band}px;background:${palette.canvas};display:flex;align-items:center;justify-content:center">
    <h1 style="font-size:${size}px;color:${palette.text}">${esc(text)}</h1></div>`;
}

/// A caption on a dark pill centred at `y`, over the empty middle of the screen.
function pillCaption(W, y, size) {
  return text => `<div style="position:absolute;left:0;top:${y}px;width:${W}px;display:flex;justify-content:center;transform:translateY(-50%)">
    <h1 style="font-size:${size}px;color:${palette.text};background:rgba(27,29,31,0.92);padding:${size * 0.45}px ${size * 0.8}px;border-radius:${size}px;border:2px solid rgba(255,255,255,0.1)">${esc(text)}</h1></div>`;
}

async function previews() {
  // Full-bleed captures (886×1920 and 1200×1600 match the captures' aspect) with captions.
  if (await exists(join(captures, 'iphone/preview.mov'))) {
    const dir = join(out, 'appstore/en-US/iphone-69');
    await mkdir(dir, { recursive: true });
    await composeVideo({ device: 'iphone', W: 886, H: 1920, framed: false,
      captionHTML: bandCaption(886, 124, 50), file: join(dir, 'preview.mp4') });
    await run('ffmpeg', ['-v', 'error', '-y', '-ss', '5', '-i', join(dir, 'preview.mp4'), '-frames:v', '1', join(dir, 'preview-poster.png')]);
  }
  if (await exists(join(captures, 'ipad/preview.mov'))) {
    const dir = join(out, 'appstore/en-US/ipad-13');
    await mkdir(dir, { recursive: true });
    await composeVideo({ device: 'ipad', W: 1200, H: 1600, framed: false,
      captionHTML: pillCaption(1200, 880, 60), file: join(dir, 'preview.mp4') });
  }
}

// MARK: Social and press

function endCard(W, H, scale) {
  const { title, line } = manifest.social.endCard;
  const size = Math.round(260 * scale);
  return `<div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:${Math.round(40 * scale)}px">
    <img src="${url(icon)}" style="width:${size}px;height:${size}px;border-radius:${Math.round(size * 0.225)}px">
    <h1 style="font-size:${Math.round(120 * scale)}px;color:${palette.text}">${esc(title)}</h1>
    <p style="font-size:${Math.round(40 * scale)}px;color:${palette.gold}">${esc(line)}</p>
  </div>`;
}

async function social() {
  const dir = join(out, 'social');
  await mkdir(dir, { recursive: true });
  const { headline, tagline } = manifest.social;

  if (await exists(join(captures, 'iphone/preview.mov'))) {
    const h = 1500, w = Math.round(h * 1320 / 2868);
    await composeVideo({ device: 'iphone', W: 1080, H: 1920, screen: { x: (1080 - w) / 2, y: 330, w, h, r: 96 },
      captionHTML: topCaption(1080, 76, 130), file: join(dir, 'launch-1080x1920.mp4'),
      endCard: endCard(1080, 1920, 1), endHold: 2.5 });
    const lh = 960, lw = Math.round(lh * 1320 / 2868);
    await composeVideo({ device: 'iphone', W: 1920, H: 1080, screen: { x: 1920 - lw - 250, y: 60, w: lw, h: lh, r: 62 },
      captionHTML: text => `<h1 style="position:absolute;left:150px;top:0;height:1080px;width:880px;display:flex;align-items:center;font-size:104px;color:${palette.text}">${esc(text)}</h1>`,
      file: join(dir, 'launch-1920x1080.mp4'), endCard: endCard(1920, 1080, 0.8), endHold: 2.5 });
  }

  // Link cards: the app's name, the headline, the blocked pane right, cropped by the edge.
  for (const [name, W, H] of [['og-1200x630.png', 1200, 630], ['x-card-1600x900.png', 1600, 900]]) {
    const s = W / 1600;
    const w = Math.round(560 * s), h = Math.round(w * 2868 / 1320);
    const body = `<main class="canvas" style="background:${palette.canvas}">
      ${glow('#F0A04B', { x: W * 0.8, y: H * 0.5, size: 900 * s, opacity: 0.16 })}
      <header style="position:absolute;left:${110 * s}px;top:0;height:${H}px;width:${780 * s}px;display:flex;flex-direction:column;justify-content:center">
        <div style="display:flex;align-items:center;gap:${22 * s}px;margin-bottom:${56 * s}px">
          <img src="${url(icon)}" style="width:${76 * s}px;height:${76 * s}px;border-radius:${17 * s}px">
          <span style="font-family:Head;font-size:${44 * s}px;color:${palette.text}">Herdwick</span>
        </div>
        <h1 style="font-size:${104 * s}px;color:${palette.text}">${esc(headline)}</h1>
        <p style="font-size:${34 * s}px;color:${palette.gold};margin-top:${34 * s}px">${esc(tagline)}</p>
      </header>
      ${shot(capture('iphone', 'pane-blocked'), { x: W - w - 150 * s, y: 90 * s, w, h, r: Math.round(w * 0.14) })}
    </main>`;
    await png(page(body), W, H, join(dir, name));
    console.log(`social ${name}`);
  }
}

async function press() {
  const dir = join(out, 'press');
  await mkdir(dir, { recursive: true });
  // Three distinct screens side by side, none cropped: the list, a reply, the machines.
  const W = 3840, H = 2160, w = 700, h = Math.round(w * 2868 / 1320), gap = 70, left = 1480;
  const phones = ['agents', 'pane-reply', 'tailscale'].map((name, i) =>
    shot(capture('iphone', name), { x: left + i * (w + gap), y: (H - h) / 2 + (i === 1 ? -70 : 50), w, h, r: 100 }));
  const hero = `<main class="canvas" style="background:${palette.canvas}">
    ${glow('#F0A04B', { x: 2700, y: 1100, size: 2200, opacity: 0.12 })}
    <header style="position:absolute;left:260px;top:0;height:${H}px;width:1300px;display:flex;flex-direction:column;justify-content:center">
      <img src="${url(icon)}" style="width:220px;height:220px;border-radius:50px;margin-bottom:90px">
      <h1 style="font-size:200px;color:${palette.text}">Herdwick</h1>
      <p style="font-size:64px;color:${palette.gold};margin-top:50px">Coding agents,<br>from anywhere.</p>
    </header>
    ${phones.join('')}
  </main>`;
  await png(page(hero), W, H, join(dir, 'hero-3840x2160.png'));
  await png(page(`<main class="canvas" style="background:${palette.canvas};display:grid;place-items:center">
      <img src="${url(icon)}" style="width:1400px;height:1400px;border-radius:315px;box-shadow:0 60px 200px rgba(0,0,0,.6)">
    </main>`), 2048, 2048, join(dir, 'icon-2048.png'));
  console.log('press hero, icon');
}

await openBrowser();
try {
  if (wants('stills')) await stills();
  if (wants('press')) await press();
  if (wants('social')) await social();
  if (wants('previews')) await previews();
} finally {
  await browser.close();
}
