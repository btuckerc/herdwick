// Checks marketing/build/out against App Store Connect's rules: every still in slides.json
// exists at the exact size with no alpha, and previews are 15–30 s, 30 fps H.264 High
// (level ≤ 4.0) at the device's preview size with stereo AAC.
import { readFile, access } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const marketing = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = join(marketing, 'build/out');
const manifest = JSON.parse(await readFile(join(marketing, 'slides.json'), 'utf8'));
const failures = [];
const exists = async p => { try { await access(p); return true; } catch { return false; } };

async function checkPNG(file, width, height) {
  if (!(await exists(file))) return failures.push(`${file}: missing`);
  const [w, h, channels] = execFileSync('magick', ['identify', '-format', '%w %h %[channels]', file], { encoding: 'utf8' }).trim().split(' ');
  if (+w !== width || +h !== height) failures.push(`${file}: ${w}×${h}, expected ${width}×${height}`);
  if (channels.includes('a')) failures.push(`${file}: has an alpha channel`);
}

async function checkVideo(file, width, height) {
  if (!(await exists(file))) return failures.push(`${file}: missing`);
  const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', file], { encoding: 'utf8' }));
  const video = probe.streams.find(s => s.codec_type === 'video');
  const audio = probe.streams.find(s => s.codec_type === 'audio');
  const duration = +probe.format.duration;
  const [num, den] = video.r_frame_rate.split('/').map(Number);
  const problems = [];
  if (video.width !== width || video.height !== height) problems.push(`${video.width}×${video.height}`);
  if (video.codec_name !== 'h264' || video.profile !== 'High' || video.level > 40) problems.push(`${video.codec_name} ${video.profile} level ${video.level}`);
  if (num / den !== 30) problems.push(`${video.r_frame_rate} fps`);
  if (duration < 15 || duration > 30) problems.push(`${duration.toFixed(2)} s`);
  if (!audio || audio.codec_name !== 'aac' || audio.channels !== 2) problems.push('audio must be stereo AAC');
  if (problems.length) failures.push(`${file}: ${problems.join(', ')}`);
}

const stillSizes = { iphone: ['iphone-69', 1320, 2868], ipad: ['ipad-13', 2064, 2752] };
for (const [device, [dir, w, h]] of Object.entries(stillSizes)) {
  for (const [i, slide] of manifest.stills[device].entries()) {
    await checkPNG(join(out, 'appstore/en-US', dir, `${String(i + 1).padStart(2, '0')}-${slide.id}.png`), w, h);
  }
}
await checkVideo(join(out, 'appstore/en-US/iphone-69/preview.mp4'), 886, 1920);
await checkVideo(join(out, 'appstore/en-US/ipad-13/preview.mp4'), 1200, 1600);
for (const [file, w, h] of [['social/og-1200x630.png', 1200, 630], ['social/x-card-1600x900.png', 1600, 900],
  ['press/hero-3840x2160.png', 3840, 2160], ['press/icon-2048.png', 2048, 2048]]) {
  await checkPNG(join(out, file), w, h);
}
for (const file of ['social/launch-1080x1920.mp4', 'social/launch-1920x1080.mp4']) {
  if (!(await exists(join(out, file)))) failures.push(`${file}: missing`);
}

if (failures.length) {
  console.error(failures.join('\n'));
  process.exit(1);
}
console.log('marketing/build/out passes App Store checks');
