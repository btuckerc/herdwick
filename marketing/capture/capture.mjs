// Captures every scene in marketing/scenes.json from the real app in the simulator.
// Runs on the Mini after scripts/mini/sync-and-build.sh; see marketing/README.md.
//   bun marketing/capture/capture.mjs [--device iphone|ipad] [--scene <id>|preview] [--no-preview]
import { readFile, mkdir, rm, access, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn, execFileSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const config = JSON.parse(await readFile(join(root, 'marketing/scenes.json'), 'utf8'));
const out = join(root, 'marketing/build/captures');
const argv = process.argv.slice(2);
const flag = name => { const i = argv.indexOf(name); return i < 0 ? null : argv[i + 1]; };
const onlyDevice = flag('--device');
const onlyScene = flag('--scene');
const withPreview = !argv.includes('--no-preview') && (!onlyScene || onlyScene === 'preview');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const exists = async p => { try { await access(p); return true; } catch { return false; } };
const simctl = (...args) => execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8' }).trim();

function udidFor(name) {
  const { devices } = JSON.parse(simctl('list', 'devices', 'available', '-j'));
  const matches = Object.entries(devices)
    .filter(([runtime]) => runtime.includes('iOS'))
    .sort(([a], [b]) => b.localeCompare(a, undefined, { numeric: true }))
    .flatMap(([, list]) => list.filter(d => d.name === name));
  if (!matches.length) throw new Error(`No available simulator named "${name}"`);
  return matches[0].udid;
}

/// Launch arguments: defaults, then the scene's, with later `-key value` pairs replacing earlier ones.
function launchArgs(...lists) {
  const pairs = new Map();
  for (const list of lists) for (let i = 0; i < list.length; i += 2) pairs.set(list[i], list[i + 1]);
  return [...pairs].flat();
}

function pngSize(buffer) {
  return [buffer.readUInt32BE(16), buffer.readUInt32BE(20)];
}

async function prepare(udid) {
  execFileSync('xcrun', ['simctl', 'bootstatus', udid, '-b'], { stdio: 'ignore' });
  simctl('ui', udid, 'appearance', 'dark');
  simctl('status_bar', udid, 'override', '--time', '9:41', '--dataNetwork', 'wifi', '--wifiMode', 'active',
    '--wifiBars', '3', '--cellularMode', 'active', '--cellularBars', '4', '--operatorName', '',
    '--batteryState', 'discharging', '--batteryLevel', '100');
  // A fresh install each run, so state left by an earlier run cannot change what is captured.
  try { simctl('uninstall', udid, config.bundleID); } catch {}
  simctl('install', udid, join(root, config.app));
  return join(simctl('get_app_container', udid, config.bundleID, 'data'), 'Documents');
}

async function launch(udid, docs, args) {
  try { simctl('terminate', udid, config.bundleID); } catch {}
  await mkdir(docs, { recursive: true });
  await rm(join(docs, 'demo-ready'), { force: true });
  await rm(join(docs, 'demo-go'), { force: true });
  simctl('launch', udid, config.bundleID, ...args);
}

async function waitReady(docs, label, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  while (!(await exists(join(docs, 'demo-ready')))) {
    if (Date.now() > deadline) throw new Error(`${label}: no demo-ready after ${timeout / 1000}s`);
    await sleep(100);
  }
}

async function captureScene(device, udid, docs, scene) {
  const args = launchArgs(config.defaults, config.devices[device].args ?? [], ['-HerdwickDemo', scene.scenario ?? 'studio'], scene.args);
  await launch(udid, docs, args);
  await waitReady(docs, `${device}/${scene.id}`);
  const file = join(out, device, `${scene.id}.png`);
  simctl('io', udid, 'screenshot', '--type=png', file);
  const [w, h] = pngSize(await readFile(file));
  const [ew, eh] = config.devices[device].size;
  if (w !== ew || h !== eh) throw new Error(`${device}/${scene.id}: ${w}x${h}, expected ${ew}x${eh}`);
  console.log(`captured ${device}/${scene.id}`);
}

/// Records the scripted timeline. The app holds its clock until `demo-go` exists, so the
/// recording starts on a settled first frame and `goAt` marks where the timeline begins.
async function capturePreview(device, udid, docs) {
  const preview = config.preview;
  await launch(udid, docs, launchArgs(config.defaults, config.devices[device].args ?? [], ['-HerdwickDemo', preview.scenario, '-HerdwickHold', 'YES'], preview.args));
  await waitReady(docs, `${device}/preview`);
  const file = join(out, device, 'preview.mov');
  await rm(file, { force: true });
  const recorder = spawn('xcrun', ['simctl', 'io', udid, 'recordVideo', '--codec=h264', '--force', file], { stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  let timer;
  const started = new Promise((res, rej) => {
    const onData = d => { log += d; if (/Recording started/i.test(log)) res(); };
    recorder.stdout.on('data', onData);
    recorder.stderr.on('data', onData);
    recorder.on('exit', code => rej(new Error(`recordVideo exited ${code}: ${log}`)));
    timer = setTimeout(() => { recorder.kill('SIGKILL'); rej(new Error(`recordVideo did not start in 15 s: ${log}`)); }, 15_000);
  });
  await started.finally(() => clearTimeout(timer));
  const t0 = Date.now();
  await sleep(1000);
  const goAt = (Date.now() - t0) / 1000;
  await writeFile(join(docs, 'demo-go'), '');
  // Same rule as DemoScenario.duration: the last timed step, counting a drop's length.
  const scenario = JSON.parse(await readFile(join(root, `Packages/HerdwickCore/Sources/HerdrDemo/Scenarios/${preview.scenario}/scenario.json`), 'utf8'));
  const duration = Math.max(0, ...scenario.timeline.filter(s => 't' in s).map(s => s.t + (s.do === 'drop' ? s.for ?? 0 : 0)));
  await sleep((duration + 1.5) * 1000);
  recorder.kill('SIGINT');
  await new Promise(res => recorder.on('exit', res));
  await writeFile(join(out, device, 'preview.json'), JSON.stringify({ goAt, duration }, null, 2) + '\n');
  console.log(`recorded ${device}/preview (${duration}s from ${goAt.toFixed(2)}s)`);
}

for (const [device, spec] of Object.entries(config.devices)) {
  if (onlyDevice && device !== onlyDevice) continue;
  await mkdir(join(out, device), { recursive: true });
  const udid = udidFor(spec.simulator);
  const docs = await prepare(udid);
  for (const scene of config.scenes) {
    if (!scene.devices.includes(device) || (onlyScene && scene.id !== onlyScene)) continue;
    await captureScene(device, udid, docs, scene);
  }
  if (withPreview && config.preview.devices.includes(device)) await capturePreview(device, udid, docs);
  try { simctl('terminate', udid, config.bundleID); } catch {}
}
