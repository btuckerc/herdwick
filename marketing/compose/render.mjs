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
const { grounds, devices } = manifest;
// Exported from App/AppIcon.icon: ictool --export-image --rendition Default --design-generation 27.
const icon = resolve(marketing, 'icon.png');
const only = process.argv.slice(2); // e.g. `stills`, `previews`, `social`, `press`
const wants = part => only.length === 0 || only.includes(part);

const url = path => 'file://' + path;
const esc = s => String(s).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
const lines = s => esc(s).replaceAll('\n', '<br>');
const capture = (device, name) => join(captures, device, `${name}.png`);
const exists = async p => { try { await access(p); return true; } catch { return false; } };
const px = n => `${Math.round(n * 10) / 10}px`;

function run(cmd, args) {
  return new Promise((res, rej) => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'inherit', 'inherit'] });
    p.on('exit', code => (code ? rej(new Error(`${cmd} exited ${code}`)) : res()));
  });
}

// MARK: HTML

const baseCSS = `
@font-face { font-family: Inter; src: url('${url(join(here, 'fonts/InterTight.ttf'))}'); font-weight: 100 900; }
@font-face { font-family: Mono; src: url('${url(join(here, 'fonts/JetBrainsMono.ttf'))}'); font-weight: 100 800; }
* { box-sizing: border-box; margin: 0; }
html, body { width: 100%; height: 100%; overflow: hidden; background: transparent; }
.canvas { position: absolute; inset: 0; overflow: hidden; }
h1 { font-family: Inter; font-weight: 660; letter-spacing: -0.022em; line-height: 1.02; }
.sub { font-family: Inter; font-weight: 420; letter-spacing: -0.012em; line-height: 1.3; }
`;

function page(body, css = '') {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${baseCSS}${css}</style></head><body>${body}</body></html>`;
}

// MARK: Ground
//
// Every canvas sits on a "ground" (`slides.json` › `grounds`): a vertical gradient with a
// soft light from the top left, the contour lines of a generated fell landscape, one of
// them picked out in gold, and a paper grain. A device's stills share one landscape laid
// across the whole strip, so the contours run on from slide to slide.

/// Deterministic PRNG (mulberry32), so every render draws the same hills.
function random(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// A height field over W×H: a few broad hills and a gentle ridge swell, sampled on a grid.
function terrain(W, H, seed) {
  const rnd = random(seed);
  const cell = Math.max(6, Math.round(Math.min(W, H) / 150));
  const nx = Math.ceil(W / cell) + 1, ny = Math.ceil(H / cell) + 1;
  const hills = Array.from({ length: Math.max(3, Math.round(W / H * 2.2)) }, () => ({
    x: rnd() * W, y: (0.15 + rnd() * 0.8) * H, s: (0.28 + rnd() * 0.3) * H, a: 0.6 + rnd() * 0.8,
  }));
  const waves = Array.from({ length: 3 }, () => ({ k: (1.5 + rnd() * 2.5) * Math.PI / H, t: rnd() * Math.PI, p: rnd() * 6.28, a: 0.08 + rnd() * 0.1 }));
  const v = new Float32Array(nx * ny);
  let lo = Infinity, hi = -Infinity;
  for (let j = 0; j < ny; j++) {
    for (let i = 0; i < nx; i++) {
      const x = i * cell, y = j * cell;
      let f = 0;
      for (const h of hills) f += h.a * Math.exp(-((x - h.x) ** 2 + (y - h.y) ** 2) / (2 * h.s * h.s));
      for (const w of waves) f += w.a * Math.sin(w.k * (x * Math.cos(w.t) + y * Math.sin(w.t)) + w.p);
      v[j * nx + i] = f;
      lo = Math.min(lo, f); hi = Math.max(hi, f);
    }
  }
  return { cell, nx, ny, v, lo, hi };
}

/// Marching squares: the line segments where the field crosses `level`, as an SVG path.
function isoline(t, level, x0, x1) {
  const { cell, nx, ny, v } = t;
  const i0 = Math.max(0, Math.floor(x0 / cell) - 1), i1 = Math.min(nx - 1, Math.ceil(x1 / cell) + 1);
  let d = '';
  const lerp = (a, b) => (level - a) / (b - a);
  for (let j = 0; j < ny - 1; j++) {
    for (let i = i0; i < i1; i++) {
      const tl = v[j * nx + i], tr = v[j * nx + i + 1], br = v[(j + 1) * nx + i + 1], bl = v[(j + 1) * nx + i];
      const c = (tl > level ? 8 : 0) | (tr > level ? 4 : 0) | (br > level ? 2 : 0) | (bl > level ? 1 : 0);
      if (c === 0 || c === 15) continue;
      const x = i * cell, y = j * cell;
      const top = [x + cell * lerp(tl, tr), y], bottom = [x + cell * lerp(bl, br), y + cell];
      const left = [x, y + cell * lerp(tl, bl)], right = [x + cell, y + cell * lerp(tr, br)];
      const seg = (a, b) => { d += `M${a[0].toFixed(1)} ${a[1].toFixed(1)}L${b[0].toFixed(1)} ${b[1].toFixed(1)}`; };
      switch (c) {
        case 1: case 14: seg(left, bottom); break;
        case 2: case 13: seg(bottom, right); break;
        case 3: case 12: seg(left, right); break;
        case 4: case 11: seg(top, right); break;
        case 6: case 9: seg(top, bottom); break;
        case 7: case 8: seg(left, top); break;
        case 5: seg(left, top); seg(bottom, right); break;
        case 10: seg(top, right); seg(left, bottom); break;
      }
    }
  }
  return d;
}

/// The ground for the part of `t` from x0 to x0 + W, drawn at 0…W.
function ground(name, W, H, t, x0 = 0) {
  const g = grounds[name];
  const levels = 20, stroke = Math.max(1.2, H / 1300);
  let contours = '';
  for (let k = 1; k < levels; k++) {
    if (k === g.goldLevel) continue;
    contours += isoline(t, t.lo + (t.hi - t.lo) * k / levels, x0, x0 + W);
  }
  const gold = isoline(t, t.lo + (t.hi - t.lo) * g.goldLevel / levels, x0, x0 + W);
  const light = `radial-gradient(ellipse ${px(W * 1.1)} ${px(H * 0.55)} at ${px(W * 0.15)} 0, ${g.light}, transparent)`;
  return `<div class="canvas" style="background:${light},linear-gradient(to bottom, ${g.stops.join(', ')})"></div>
    <svg class="canvas" width="${W}" height="${H}" viewBox="${x0} 0 ${W} ${H}" fill="none" stroke-linecap="round">
      <path d="${contours}" stroke="${g.line}" stroke-width="${stroke}"/>
      <path d="${gold}" stroke="${manifest.palette.gold}" stroke-opacity="${g.goldOpacity}" stroke-width="${stroke * 1.6}"/>
    </svg>
    <svg class="canvas" width="${W}" height="${H}" style="mix-blend-mode:overlay;opacity:${g.grain}">
      <filter id="grain"><feTurbulence type="fractalNoise" baseFrequency="${(0.9 * 1320 / Math.max(W, 1320)).toFixed(3)}" numOctaves="2" stitchTiles="stitch"/><feColorMatrix type="saturate" values="0"/></filter>
      <rect width="100%" height="100%" filter="url(#grain)"/>
    </svg>`;
}

// MARK: Devices and close-ups

/// A drop shadow for an object `w` wide, tinted by the ground.
function shadow(g, w) {
  const [c, a] = [g.shadow, g.shadowAlpha];
  return `0 ${px(w * 0.07)} ${px(w * 0.14)} ${px(-w * 0.03)} rgba(${c},${a}), 0 ${px(w * 0.018)} ${px(w * 0.04)} rgba(${c},${a * 0.55})`;
}

/// A capture in a generic device: a thin dark bezel with a hairline highlight, the screen's
/// corner radius and, on iPhone, the Dynamic Island (some captures include it, most don't).
function device(dev, name, { x, y, w, rotate = 0 }, g) {
  const d = devices[dev], [cw, ch] = d.size, h = w * ch / cw, s = w / cw;
  const r = w * d.radius, b = Math.max(4, w * d.bezel);
  const island = d.island
    ? `<div style="position:absolute;left:${px(d.island[0] * s)};top:${px(d.island[1] * s)};width:${px(d.island[2] * s)};height:${px(d.island[3] * s)};border-radius:${px(d.island[3] * s)};background:#000"></div>`
    : '';
  return `<div style="position:absolute;left:${px(x - b)};top:${px(y - b)};width:${px(w + 2 * b)};height:${px(h + 2 * b)};border-radius:${px(r + b)};background:linear-gradient(155deg,#4b4b4e,#1a1a1c 28%,#0d0d0e 72%,#3c3c3f);box-shadow:${shadow(g, w)};transform:rotate(${rotate}deg)">
    <div style="position:absolute;left:${px(b)};top:${px(b)};width:${px(w)};height:${px(h)};border-radius:${px(r)};overflow:hidden;background:#000">
      <img src="${url(capture(dev, name))}" style="display:block;width:100%;height:100%">${island}
    </div>
    <div style="position:absolute;inset:0;border-radius:${px(r + b)};box-shadow:inset 0 0 0 ${px(Math.max(1, b * 0.14))} rgba(255,255,255,.2)"></div>
  </div>`;
}

/// A region of a capture (`crop`: x, y, width, height as fractions) raised on a card `w`
/// wide. Throws past 1.5× the capture's pixels, where retina text starts to soften.
function zoom(dev, name, crop, { x, y, w, radius }, g) {
  const [cw, ch] = devices[dev].size, [cx, cy, cwf, chf] = crop;
  const s = w / (cwf * cw), h = chf * ch * s;
  if (s > 1.5) throw new Error(`${dev}/${name} zoom at ${s.toFixed(2)}×`);
  const r = radius ?? w * 0.03;
  return `<div style="position:absolute;left:${px(x)};top:${px(y)};width:${px(w)};height:${px(h)};border-radius:${px(r)};overflow:hidden;box-shadow:${shadow(g, w * 0.8)}">
    <img src="${url(capture(dev, name))}" style="position:absolute;left:${px(-cx * cw * s)};top:${px(-cy * ch * s)};width:${px(cw * s)};max-width:none">
    <div style="position:absolute;inset:0;border-radius:${px(r)};box-shadow:inset 0 0 0 ${px(Math.max(1, w / 900))} ${g.ring}"></div>
  </div>`;
}

function layer(dev, l, g) {
  if (l.device) return device(dev, l.device, l, g);
  if (l.zoom) return zoom(dev, l.zoom, l.crop, l, g);
  throw new Error(`unknown layer ${JSON.stringify(l)}`);
}

/// The icon and name, `size` px tall.
function wordmark(size, color) {
  return `<div style="display:flex;align-items:center;gap:${px(size * 0.32)}">
    <img src="${url(icon)}" style="width:${px(size)};height:${px(size)};border-radius:${px(size * 0.225)};box-shadow:0 ${px(size * 0.08)} ${px(size * 0.25)} rgba(0,0,0,.18)">
    <span style="font-family:Inter;font-weight:620;letter-spacing:-0.02em;font-size:${px(size * 0.5)};color:${color}">Herdwick</span>
  </div>`;
}

// MARK: Stills
//
// One slide per entry in `slides.json` › `stills`, each a complete composition: a ground,
// the headline block, then `layers` in order (a `device` with a capture, or a `zoom` on a
// region of one). Geometry is in slide pixels.

function header(slide, h, g) {
  const cta = slide.cta
    ? `<p class="sub" style="display:inline-flex;align-items:center;gap:${px(h.sub * 0.5)};margin-top:${px(h.sub * 1.1)};font-size:${px(h.sub * 0.78)};color:${g.ink};padding:${px(h.sub * 0.45)} ${px(h.sub * 0.8)};border-radius:${px(h.sub)};background:${g.pill}"><span style="width:${px(h.sub * 0.32)};height:${px(h.sub * 0.32)};border-radius:50%;background:${manifest.palette.gold}"></span>${esc(slide.cta)}</p>`
    : '';
  return `<header style="position:absolute;left:${h.x}px;top:${slide.headerY ?? h.y}px;width:${h.width}px">
    ${slide.brand ? `<div style="margin-bottom:${px(h.head * 0.62)}">${wordmark(h.head * 0.66, g.ink)}</div>` : ''}
    <h1 style="font-size:${h.head}px;color:${g.ink}">${lines(slide.headline)}</h1>
    <p class="sub" style="font-size:${h.sub}px;color:${g.sub};margin-top:${px(h.head * 0.26)}">${lines(slide.subline)}</p>
    ${cta}
  </header>`;
}

async function stills() {
  const dirs = { iphone: 'iphone-69', ipad: 'ipad-13' };
  for (const [dev, dir] of Object.entries(dirs)) {
    const slides = manifest.stills[dev];
    const [W, H] = devices[dev].size;
    const land = terrain(W * slides.length, H, devices[dev].seed);
    const target = join(out, 'appstore/en-US', dir);
    await rm(target, { recursive: true, force: true });
    await mkdir(target, { recursive: true });
    for (const [i, slide] of slides.entries()) {
      const g = grounds[slide.ground];
      const body = `<main class="canvas">${ground(slide.ground, W, H, land, i * W)}
        ${slide.layers.map(l => layer(dev, l, g)).join('')}
        ${header(slide, devices[dev].header, g)}</main>`;
      const name = `${String(i + 1).padStart(2, '0')}-${slide.id}`;
      await png(page(body), W, H, join(target, `${name}.png`));
      console.log(`still ${dir}/${name}`);
    }
  }
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
  if (!transparent) await run('magick', [file, '-background', manifest.palette.cream, '-alpha', 'remove', '-alpha', 'off', file]);
}

// MARK: Video

/// Encoder settings App Store Connect accepts for previews; social cuts reuse them.
const h264 = ['-c:v', 'libx264', '-profile:v', 'high', '-level:v', '4.0', '-pix_fmt', 'yuv420p', '-r', '30',
  '-b:v', '11M', '-maxrate', '12M', '-bufsize', '24M', '-c:a', 'aac', '-b:a', '256k', '-ar', '48000', '-ac', '2',
  '-movflags', '+faststart'];

/// The ground with an empty bezel where the screen goes, for grounded videos.
function videoStage(W, H, screen, groundName) {
  const g = grounds[groundName], b = Math.max(6, screen.w * 0.017);
  return `${ground(groundName, W, H, terrain(W, H, 7))}
    <div style="position:absolute;left:${px(screen.x - b)};top:${px(screen.y - b)};width:${px(screen.w + 2 * b)};height:${px(screen.h + 2 * b)};border-radius:${px(screen.r + b)};background:#111113;box-shadow:${shadow(g, screen.w)}, inset 0 0 0 ${px(b * 0.14)} rgba(255,255,255,.2)"></div>`;
}

/**
 * Puts the recorded screen into `screen` on a W×H canvas, with a caption layer per caption.
 * `captionHTML(text)` returns the caption markup for this format. `ground` draws that
 * ground around a bezelled screen; App Store previews pass none and fill the frame with
 * the capture itself (guideline 2.3.4: captures of the app plus text overlays).
 * `endCard` (HTML) fades in over a held last frame for `endHold` seconds.
 */
async function composeVideo({ device, W, H, screen = { x: 0, y: 0, w: W, h: H }, ground: groundName = null, captionHTML, file, endCard = null, endHold = 0 }) {
  const meta = JSON.parse(await readFile(join(captures, device, 'preview.json'), 'utf8'));
  const { lead, tail, captions } = manifest.preview;
  const length = lead + meta.duration + tail;
  const total = length + endHold;
  const dir = join(work, `${device}-${W}x${H}`);
  await rm(dir, { recursive: true, force: true });
  await mkdir(dir, { recursive: true });

  // A grounded video sits on a stage (the ground and a bezel), with its screen's corners
  // rounded by a luma mask. Overlays on top in order: captions, then the end card.
  const stage = join(dir, 'stage.png'), mask = join(dir, 'mask.png');
  if (groundName) {
    await png(page(`<main class="canvas">${videoStage(W, H, screen, groundName)}</main>`), W, H, stage);
    await png(page(`<main class="canvas" style="background:#000"><div class="canvas" style="border-radius:${screen.r}px;background:#fff"></div></main>`), screen.w, screen.h, mask);
  }
  const layers = [];
  for (const [i, caption] of captions.entries()) {
    const png_ = join(dir, `caption-${i}.png`);
    await png(page(`<main class="canvas">${captionHTML(caption.text)}</main>`), W, H, png_, { transparent: true });
    layers.push({ file: png_, start: caption.start + lead, end: Math.min(caption.end + lead, length) });
  }
  if (endCard) {
    const png_ = join(dir, 'end.png');
    await png(page(`<main class="canvas">${endCard}</main>`), W, H, png_);
    layers.push({ file: png_, start: length, end: total });
  }

  const inputs = [...(groundName ? ['-loop', '1', '-framerate', '30', '-t', String(total), '-i', stage] : ['-f', 'lavfi', '-i', `color=c=black:s=${W}x${H}:r=30:d=${total}`]),
    '-ss', String(Math.max(0, meta.goAt - lead)), '-t', String(length), '-i', join(captures, device, 'preview.mov')];
  if (groundName) inputs.push('-loop', '1', '-framerate', '30', '-t', String(total), '-i', mask);
  const first = groundName ? 3 : 2;
  for (const layer of layers) inputs.push('-loop', '1', '-t', String(total), '-i', layer.file);
  inputs.push('-f', 'lavfi', '-t', String(total), '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000');

  const fade = 0.25;
  const graph = [
    `[1:v]fps=30,scale=${screen.w}:${screen.h}:flags=lanczos,setsar=1,tpad=stop_mode=clone:stop_duration=${endHold + 1}${groundName ? '[raw]' : '[screen]'}`,
    ...(groundName ? ['[2:v]format=gray[mask]', '[raw]format=rgba[rgba]', '[rgba][mask]alphamerge[screen]'] : []),
    `[0:v][screen]overlay=${screen.x}:${screen.y}:shortest=0[b0]`,
  ];
  let last = 'b0';
  layers.forEach((layer, i) => {
    const input = first + i;
    const fadeOut = layer.end >= total ? '' : `,fade=t=out:st=${(layer.end - fade).toFixed(2)}:d=${fade}:alpha=1`;
    graph.push(`[${input}:v]format=rgba,fade=t=in:st=${layer.start.toFixed(2)}:d=${fade}:alpha=1${fadeOut}[l${i}]`);
    graph.push(`[${last}][l${i}]overlay=0:0:enable='between(t,${layer.start.toFixed(2)},${layer.end.toFixed(2)})'[c${i}]`);
    last = `c${i}`;
  });
  graph.push(`[${last}]trim=duration=${total},setpts=PTS-STARTPTS,format=yuv420p[v]`);
  const audio = first + layers.length;

  await run('ffmpeg', ['-v', 'error', '-y', ...inputs, '-filter_complex', graph.join(';'),
    '-map', '[v]', '-map', `${audio}:a`, '-t', String(total), ...h264, file]);
  console.log(`video ${file.slice(out.length + 1)} (${total.toFixed(1)} s)`);
}

/// A caption on a cream band across the top, over the status bar.
function bandCaption(W, band, size) {
  const g = grounds.cream;
  return text => `<div style="position:absolute;left:0;top:0;width:${W}px;height:${band}px;background:${g.stops[0]};display:flex;align-items:center;justify-content:center;box-shadow:0 ${px(size * 0.1)} ${px(size * 0.5)} rgba(0,0,0,.25)">
    <h1 style="font-size:${size}px;color:${g.ink}">${esc(text)}</h1></div>`;
}

/// A caption on a cream pill centred at `y`, over the empty middle of the screen.
function pillCaption(W, y, size) {
  const g = grounds.cream;
  return text => `<div style="position:absolute;left:0;top:${y}px;width:${W}px;display:flex;justify-content:center;transform:translateY(-50%)">
    <h1 style="font-size:${size}px;color:${g.ink};background:${g.stops[0]};padding:${size * 0.45}px ${size * 0.8}px;border-radius:${size}px;box-shadow:0 ${px(size * 0.2)} ${px(size * 0.8)} rgba(0,0,0,.35)">${esc(text)}</h1></div>`;
}

async function previews() {
  // Full-bleed captures (886×1920 and 1200×1600 match the captures' aspect) with captions.
  if (await exists(join(captures, 'iphone/preview.mov'))) {
    const dir = join(out, 'appstore/en-US/iphone-69');
    await mkdir(dir, { recursive: true });
    await composeVideo({ device: 'iphone', W: 886, H: 1920,
      captionHTML: bandCaption(886, 124, 50), file: join(dir, 'preview.mp4') });
    await run('ffmpeg', ['-v', 'error', '-y', '-ss', '5', '-i', join(dir, 'preview.mp4'), '-frames:v', '1', join(dir, 'preview-poster.png')]);
  }
  if (await exists(join(captures, 'ipad/preview.mov'))) {
    const dir = join(out, 'appstore/en-US/ipad-13');
    await mkdir(dir, { recursive: true });
    await composeVideo({ device: 'ipad', W: 1200, H: 1600,
      captionHTML: pillCaption(1200, 880, 60), file: join(dir, 'preview.mp4') });
  }
}

// MARK: Social and press

function endCard(W, H, scale) {
  const { title, line } = manifest.social.endCard;
  const g = grounds.cream, size = Math.round(260 * scale);
  return `${ground('cream', W, H, terrain(W, H, 7))}
    <div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:${Math.round(44 * scale)}px">
    <img src="${url(icon)}" style="width:${size}px;height:${size}px;border-radius:${Math.round(size * 0.225)}px;box-shadow:${shadow(g, size * 2)}">
    <h1 style="font-size:${Math.round(128 * scale)}px;color:${g.ink}">${esc(title)}</h1>
    <p class="sub" style="font-size:${Math.round(44 * scale)}px;color:${g.sub}">${esc(line)}</p>
  </div>`;
}

async function social() {
  const dir = join(out, 'social');
  await mkdir(dir, { recursive: true });
  const { headline, tagline } = manifest.social;
  const g = grounds.cream;

  if (await exists(join(captures, 'iphone/preview.mov'))) {
    const caption = (W, size, y) => text => `<h1 style="position:absolute;left:0;top:${y}px;width:${W}px;text-align:center;font-size:${size}px;color:${g.ink}">${esc(text)}</h1>`;
    const h = 1480, w = Math.round(h * 1320 / 2868);
    await composeVideo({ device: 'iphone', W: 1080, H: 1920, screen: { x: Math.round((1080 - w) / 2), y: 340, w, h, r: Math.round(w * 0.125) },
      ground: 'cream', captionHTML: caption(1080, 76, 140), file: join(dir, 'launch-1080x1920.mp4'),
      endCard: endCard(1080, 1920, 1), endHold: 2.5 });
    const lh = 940, lw = Math.round(lh * 1320 / 2868);
    await composeVideo({ device: 'iphone', W: 1920, H: 1080, screen: { x: 1920 - lw - 260, y: 70, w: lw, h: lh, r: Math.round(lw * 0.125) },
      ground: 'cream', captionHTML: text => `<h1 style="position:absolute;left:150px;top:0;height:1080px;width:960px;display:flex;align-items:center;font-size:104px;color:${g.ink}">${lines(text.replaceAll('. ', '.\n'))}</h1>`,
      file: join(dir, 'launch-1920x1080.mp4'), endCard: endCard(1920, 1080, 0.8), endHold: 2.5 });
  }

  // Link cards: name, headline, the inbox and its question raised beside it.
  const { main, callout, crop } = manifest.social.captures;
  const cards = [
    ['og-1200x630.png', 1200, 630, { text: [72, 96, 560], head: 70, sub: 25, mark: 50, screen: { x: 700, y: 64, w: 330, rotate: -2 }, ask: { x: 800, y: 300, w: 360 } }],
    ['x-card-1600x900.png', 1600, 900, { text: [100, 150, 740], head: 96, sub: 33, mark: 66, screen: { x: 930, y: 90, w: 460, rotate: -2 }, ask: { x: 1070, y: 420, w: 490 } }],
  ];
  for (const [name, W, H, s] of cards) {
    const [tx, ty, tw] = s.text;
    const body = `<main class="canvas">${ground('cream', W, H, terrain(W, H, 11))}
      ${device('iphone', main, s.screen, g)}
      ${zoom('iphone', callout, crop, s.ask, g)}
      <header style="position:absolute;left:${tx}px;top:${ty}px;width:${tw}px">
        <div style="margin-bottom:${px(s.mark * 0.9)}">${wordmark(s.mark, g.ink)}</div>
        <h1 style="font-size:${s.head}px;color:${g.ink}">${lines(headline)}</h1>
        <p class="sub" style="font-size:${s.sub}px;color:${g.sub};margin-top:${px(s.head * 0.3)}">${esc(tagline)}</p>
      </header>
    </main>`;
    await png(page(body), W, H, join(dir, name));
    console.log(`social ${name}`);
  }

  // Instagram story: a note from the maker and the name, the inbox rising from the bottom edge.
  // Text stays clear of the top and bottom 250 px its controls cover.
  const sw = 640;
  await png(page(`<main class="canvas">${ground('cream', 1080, 1920, terrain(1080, 1920, 11))}
    ${device('iphone', main, { x: (1080 - sw) / 2, y: 900, w: sw }, g)}
    <header style="position:absolute;left:0;top:290px;width:1080px;display:flex;flex-direction:column;align-items:center">
      <p class="sub" style="font-size:52px;color:${g.sub}">${esc(manifest.social.story)}</p>
      <img src="${url(icon)}" style="margin-top:72px;width:200px;height:200px;border-radius:45px;box-shadow:${shadow(g, 400)}">
      <h1 style="font-size:150px;color:${g.ink};margin-top:44px">Herdwick</h1>
    </header>
  </main>`), 1080, 1920, join(dir, 'story-1080x1920.png'));
  console.log('social story-1080x1920.png');
}

async function press() {
  const dir = join(out, 'press');
  await mkdir(dir, { recursive: true });
  const W = 3840, H = 2160, g = grounds.cream;
  const [back, front, side] = manifest.social.press;
  const hero = `<main class="canvas">${ground('cream', W, H, terrain(W, H, 5))}
    ${device('iphone', back, { x: 1560, y: 330, w: 760, rotate: -3 }, g)}
    ${device('iphone', side, { x: 2980, y: 420, w: 760, rotate: 3 }, g)}
    ${device('iphone', front, { x: 2240, y: 200, w: 820 }, g)}
    <header style="position:absolute;left:220px;top:0;height:${H}px;width:1250px;display:flex;flex-direction:column;justify-content:center">
      ${wordmark(170, g.ink)}
      <h1 style="font-size:190px;color:${g.ink};margin-top:120px">${lines(manifest.social.brand)}</h1>
      <p class="sub" style="font-size:62px;color:${g.sub};margin-top:60px">${esc(manifest.social.tagline)}</p>
    </header>
  </main>`;
  await png(page(hero), W, H, join(dir, 'hero-3840x2160.png'));
  await png(page(`<main class="canvas">${ground('cream', 2048, 2048, terrain(2048, 2048, 3))}
      <img src="${url(icon)}" style="position:absolute;left:324px;top:324px;width:1400px;height:1400px;border-radius:315px;box-shadow:${shadow(g, 2000)}">
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
