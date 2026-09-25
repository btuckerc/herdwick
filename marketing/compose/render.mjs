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
// Exported from App/AppIcon.icon: ictool --export-image --rendition Default --design-generation 27.
const icon = resolve(marketing, 'icon.png');
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
`;

function page(body, css = '') {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${baseCSS}${css}</style></head><body>${body}</body></html>`;
}

// MARK: Panorama stills
//
// Each device's stills are one continuous canvas (`slides.json` › `panorama`): a grid, two
// colour pools and a gold thread run across every slide, and a fragment of the next slide's
// screen straddles each boundary so the set reads as one strip. The canvas is rendered once
// and cut into slides, so the seams match exactly. Geometry is per device, in slide-local
// pixels; every screen is a real capture, whole or cropped (`crop`: x, y, width, height as
// fractions of the capture).

/// A capture in a generic device frame: a graphite surround and a hairline edge.
function device(src, { x, y, w, r, size: [cw, ch], transform = '' }) {
  const h = Math.round(w * ch / cw), s = 12;
  return `<div style="position:absolute;left:${x - s}px;top:${y - s}px;width:${w + 2 * s}px;height:${h + 2 * s}px;border-radius:${r + s}px;background:${palette.plane};border:2px solid ${palette.edge};box-shadow:0 36px 90px rgba(0,0,0,.53);transform:${transform}">
    <img src="${url(src)}" style="position:absolute;left:${s - 2}px;top:${s - 2}px;width:${w}px;height:${h}px;border-radius:${r}px"></div>`;
}

/// A region of a capture on a raised card, at `w` wide and never upscaled past 1:1.
function card(src, crop, { x, y, w, size: [cw, ch], edge = palette.rule }) {
  const [cx, cy, cwf, chf] = crop;
  const scale = Math.min(1, w / (cwf * cw));
  const width = Math.round(cwf * cw * scale), height = Math.round(chf * ch * scale);
  return `<div style="position:absolute;left:${x}px;top:${y}px;width:${width}px;height:${height}px;border-radius:28px;overflow:hidden;background:${palette.canvas};border:2px solid ${edge};box-shadow:0 40px 110px rgba(0,0,0,.6)">
    <img src="${url(src)}" style="position:absolute;left:${-cx * cw * scale}px;top:${-cy * ch * scale}px;width:${cw * scale}px;max-width:none"></div>`;
}

function panelHeader(slide, index, g) {
  const h = g.header;
  return `<header style="position:absolute;left:${h.x}px;top:${h.y}px;width:${h.width}px">
    <p style="font-size:${h.eyebrow}px;color:${palette.muted};letter-spacing:0.06em;text-transform:uppercase"><span style="color:${palette.gold}">${String(index + 1).padStart(2, '0')}</span>&nbsp;&nbsp;${esc(slide.eyebrow)}</p>
    <h1 style="font-size:${h.head}px;color:${palette.bright};margin-top:${Math.round(h.eyebrow * 1.3)}px">${lines(slide.headline)}</h1>
    <p style="font-size:${h.sub}px;color:${palette.text};opacity:0.78;margin-top:${Math.round(h.head * 0.22)}px">${lines(slide.subline)}</p>
  </header>`;
}

/// One slide's screens, at slide-local coordinates. Returns [behind, front] layers.
function panelScreens(slide, device_, g, size) {
  const cap = name => capture(device_, name);
  switch (slide.layout) {
    case 'full': {
      let front = device(cap(slide.capture), { ...g.full, r: g.radius, size });
      if (slide.calloutCapture) front += card(cap(slide.calloutCapture), slide.crop, { ...slide.callout, size, edge: palette.gold });
      return front;
    }
    case 'detail': {
      const d = g.detail;
      return device(cap(slide.capture), { ...d.screen, r: g.radius, size }) +
        card(cap(slide.calloutCapture ?? slide.capture), slide.crop, { ...d.callout, ...slide.callout, size, edge: palette.gold });
    }
    case 'trio': {
      const [a, b, c] = slide.captures.map(cap);
      const t = g.trio;
      return device(a, { ...t[0], r: g.radius * 0.6, size, transform: 'perspective(2400px) rotateY(6deg) rotateZ(-3deg)' }) +
        device(c, { ...t[2], r: g.radius * 0.6, size, transform: 'perspective(2400px) rotateY(-6deg) rotateZ(3deg)' }) +
        device(b, { ...t[1], r: g.radius * 0.7, size });
    }
    default:
      throw new Error(`unknown layout ${slide.layout} on ${slide.id}`);
  }
}

function panorama(device_, slides) {
  const g = manifest.panorama[device_];
  const [W, H] = g.size, N = slides.length, total = W * N;
  const at = (i, html) => `<div style="position:absolute;left:${i * W}px;top:0;width:${W}px;height:${H}px">${html}</div>`;
  const grid = `linear-gradient(to right, rgba(220,215,205,0.04) 1px, transparent 1px), linear-gradient(to bottom, rgba(220,215,205,0.04) 1px, transparent 1px)`;
  const pools = `radial-gradient(circle ${g.pool}px at ${total * 0.23}px ${H * 0.6}px, rgba(232,194,122,0.10), transparent), radial-gradient(circle ${g.pool}px at ${total * 0.76}px ${H * 0.62}px, rgba(156,196,138,0.08), transparent)`;

  // The thread: a rule under the headers across the strip, dropping at each seam that has
  // a bridge into the fragment that straddles it.
  let thread = `<line x1="0" y1="${g.thread}" x2="${total}" y2="${g.thread}"/>`;
  const bridges = [];
  slides.forEach((slide, i) => {
    if (!slide.bridge || i === N - 1) return;
    const seam = (i + 1) * W, b = g.bridge;
    thread += `<line x1="${seam}" y1="${g.thread}" x2="${seam}" y2="${b.y}"/><circle cx="${seam}" cy="${g.thread}" r="9"/>`;
    bridges.push(at(i, card(capture(device_, slide.bridge.capture), slide.bridge.crop ?? b.crop, { x: b.x, y: b.y, w: b.w, size: g.size })));
  });
  const svg = `<svg width="${total}" height="${H}" style="position:absolute;left:0;top:0" stroke="${palette.gold}" stroke-width="4" fill="${palette.gold}">${thread}</svg>`;

  const screens = slides.map((slide, i) => at(i, panelScreens(slide, device_, g, g.size))).join('');
  const headers = slides.map((slide, i) => at(i, panelHeader(slide, i, g) + (slide.cta
    ? `<p style="position:absolute;left:${g.header.x}px;top:${g.cta}px;font-size:${g.header.sub}px;color:${palette.gold}">${esc(slide.cta)}</p>`
    : ''))).join('');
  return `<main class="canvas" style="width:${total}px;background:${palette.canvas};background-image:${pools}"><div style="position:absolute;inset:0;background-image:${grid};background-size:120px 120px"></div>
    ${svg}${bridges.join('')}${screens}${headers}</main>`;
}

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
  await tab.evaluate(() => Promise.all([document.fonts.ready, ...[...document.images].map(i => i.decode())]));
  await tab.screenshot({ path: file, type: 'png', omitBackground: transparent });
  await rm(source);
  // App Store Connect rejects alpha; overlays for ffmpeg keep it.
  if (!transparent) await run('magick', [file, '-background', palette.canvas, '-alpha', 'remove', '-alpha', 'off', file]);
}

async function stills() {
  const dirs = { iphone: 'iphone-69', ipad: 'ipad-13' };
  for (const [device_, dir] of Object.entries(dirs)) {
    const slides = manifest.stills[device_];
    const [W, H] = manifest.panorama[device_].size;
    const target = join(out, 'appstore/en-US', dir);
    await rm(target, { recursive: true, force: true });
    await mkdir(target, { recursive: true });
    await mkdir(work, { recursive: true });
    const master = join(work, `panorama-${device_}.png`);
    await png(page(panorama(device_, slides)), W * slides.length, H, master);
    for (const [i, slide] of slides.entries()) {
      const name = `${String(i + 1).padStart(2, '0')}-${slide.id}`;
      await run('magick', [master, '-crop', `${W}x${H}+${i * W}+0`, '+repage', '-alpha', 'off', join(target, `${name}.png`)]);
      console.log(`still ${dir}/${name}`);
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

  // Link cards: name, headline, a real conversation and its question on a raised card.
  const { main, callout, crop } = manifest.social.captures;
  const phone = [1320, 2868];
  const cards = [
    ['og-1200x630.png', 1200, 630, { text: [64, 120, 540], head: 64, sub: 24, mark: 56, screen: { x: 730, y: 54, w: 300 }, ask: { x: 630, y: 380, w: 530 } }],
    ['x-card-1600x900.png', 1600, 900, { text: [88, 180, 680], head: 88, sub: 30, mark: 72, screen: { x: 1020, y: 80, w: 430 }, ask: { x: 800, y: 560, w: 700 } }],
  ];
  for (const [name, W, H, g] of cards) {
    const [tx, ty, tw] = g.text;
    const body = `<main class="canvas" style="${backdrop(W, H)}">
      ${thread(W, H, ty - 36)}
      ${device(capture('iphone', main), { ...g.screen, r: Math.round(g.screen.w * 0.09), size: phone })}
      ${card(capture('iphone', callout), crop, { ...g.ask, size: phone, edge: palette.gold })}
      <header style="position:absolute;left:${tx}px;top:${ty}px;width:${tw}px">
        <div style="display:flex;align-items:center;gap:${g.mark * 0.3}px;margin-bottom:${g.mark * 0.6}px">
          <img src="${url(icon)}" style="width:${g.mark}px;height:${g.mark}px;border-radius:${g.mark * 0.225}px">
          <span style="font-family:Head;font-size:${g.mark * 0.6}px;color:${palette.bright}">Herdwick</span>
        </div>
        <h1 style="font-size:${g.head}px;color:${palette.bright}">${lines(headline)}</h1>
        <p style="font-size:${g.sub}px;color:${palette.text};opacity:0.78;margin-top:${g.head * 0.3}px">${esc(tagline)}</p>
      </header>
    </main>`;
    await png(page(body), W, H, join(dir, name));
    console.log(`social ${name}`);
  }
}

/// The panorama's ground at any size: canvas, the 120 px grid and the two colour pools.
function backdrop(W, H) {
  const grid = `linear-gradient(to right, rgba(220,215,205,0.04) 1px, transparent 1px), linear-gradient(to bottom, rgba(220,215,205,0.04) 1px, transparent 1px)`;
  const pools = `radial-gradient(circle ${W * 0.45}px at ${W * 0.3}px ${H * 0.6}px, rgba(232,194,122,0.10), transparent), radial-gradient(circle ${W * 0.4}px at ${W * 0.85}px ${H * 0.5}px, rgba(156,196,138,0.08), transparent)`;
  return `background-color:${palette.canvas};background-image:${grid},${pools};background-size:120px 120px,120px 120px,100% 100%,100% 100%`;
}

/// The gold thread across a single canvas at `y`.
function thread(W, H, y) {
  return `<svg width="${W}" height="${H}" style="position:absolute;left:0;top:0"><line x1="0" y1="${y}" x2="${W}" y2="${y}" stroke="${palette.gold}" stroke-width="${Math.max(2, Math.round(W / 960))}"/></svg>`;
}

async function press() {
  const dir = join(out, 'press');
  await mkdir(dir, { recursive: true });
  const W = 3840, H = 2160, phone = [1320, 2868];
  const spots = [{ x: 1450, y: 380 }, { x: 2230, y: 250 }, { x: 3010, y: 380 }];
  const phones = manifest.social.press.map((name, i) => device(capture('iphone', name), { ...spots[i], w: 700, r: 62, size: phone }));
  const hero = `<main class="canvas" style="${backdrop(W, H)}">
    ${thread(W, H, 1080)}
    ${phones.join('')}
    <header style="position:absolute;left:200px;top:0;height:${H}px;width:1100px;display:flex;flex-direction:column;justify-content:center">
      <img src="${url(icon)}" style="width:200px;height:200px;border-radius:45px;margin-bottom:80px">
      <h1 style="font-size:200px;color:${palette.bright}">Herdwick</h1>
      <p style="font-size:64px;color:${palette.gold};margin-top:50px">${lines(manifest.social.brand)}</p>
    </header>
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
