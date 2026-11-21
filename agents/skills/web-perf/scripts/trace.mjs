#!/usr/bin/env node
import {spawn} from 'node:child_process';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const [url, selector, durationArg] = process.argv.slice(2);
const durationMs = Number(durationArg ?? 1500);

if (!url || !selector || !Number.isFinite(durationMs) || durationMs <= 0) {
  console.error('Usage: trace.mjs <url> <css-selector> [duration-ms]');
  process.exit(2);
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const profileDir = await mkdtemp(join(tmpdir(), 'web-perf-'));
const chromium = spawn('chromium', [
  '--headless', '--disable-gpu', '--disable-dev-shm-usage', '--no-first-run',
  '--no-default-browser-check', '--disable-background-networking', '--disable-component-update',
  '--disable-sync', '--disable-extensions', '--password-store=basic', '--metrics-recording-only',
  '--window-size=390,780', `--user-data-dir=${profileDir}`,
  '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0', 'about:blank',
], {stdio: 'ignore'});

let socket;
async function cleanup() {
  try { socket?.close(); } catch {}
  if (chromium.exitCode === null) {
    chromium.kill('SIGTERM');
    for (let i = 0; i < 30 && chromium.exitCode === null; i++) await sleep(100);
    if (chromium.exitCode === null) chromium.kill('SIGKILL');
  }
  await rm(profileDir, {recursive: true, force: true});
}

try {
  let wsUrl;
  for (let i = 0; i < 150; i++) {
    if (chromium.exitCode !== null) throw new Error('chromium exited before CDP was ready');
    try {
      const port = (await readFile(join(profileDir, 'DevToolsActivePort'), 'utf8')).split('\n')[0].trim();
      const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const page = pages.find(p => p.type === 'page' && p.webSocketDebuggerUrl);
      if (page) { wsUrl = page.webSocketDebuggerUrl; break; }
    } catch {}
    await sleep(100);
  }
  if (!wsUrl) throw new Error('Timed out waiting for Chromium CDP');

  socket = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, {once: true});
    socket.addEventListener('error', reject, {once: true});
  });

  let seq = 0;
  const pending = new Map();
  const listeners = new Map();
  socket.addEventListener('message', event => {
    const msg = JSON.parse(event.data);
    if (msg.id) {
      const req = pending.get(msg.id);
      if (!req) return;
      pending.delete(msg.id);
      clearTimeout(req.timer);
      if (msg.error) req.reject(new Error(JSON.stringify(msg.error)));
      else req.resolve(msg.result);
    } else if (msg.method && listeners.has(msg.method)) {
      for (const fn of listeners.get(msg.method)) fn(msg.params);
    }
  });

  const on = (method, fn) => {
    if (!listeners.has(method)) listeners.set(method, []);
    listeners.get(method).push(fn);
  };
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++seq;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`${method} timed out`)); }, 20000);
    pending.set(id, {resolve, reject, timer});
    socket.send(JSON.stringify({id, method, params}));
  });
  const evaluate = async expression => {
    const res = await send('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true});
    if (res.exceptionDetails) throw new Error(JSON.stringify(res.exceptionDetails));
    return res.result.value;
  };

  await send('Page.enable');
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390, height: 780, deviceScaleFactor: 3, mobile: true,
  });
  await send('Emulation.setTouchEmulationEnabled', {enabled: true});
  await send('Emulation.setCPUThrottlingRate', {rate: 4});

  const loaded = new Promise(resolve => on('Page.loadEventFired', resolve));
  await send('Page.navigate', {url});
  await loaded;

  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (await evaluate(`Boolean(document.querySelector(${JSON.stringify(selector)}))`)) break;
    await sleep(100);
  }
  if (!(await evaluate(`Boolean(document.querySelector(${JSON.stringify(selector)}))`))) {
    throw new Error(`Selector not found: ${selector}`);
  }

  const traceEvents = [];
  on('Tracing.dataCollected', params => { if (params.value) traceEvents.push(...params.value); });
  const tracingComplete = new Promise(resolve => on('Tracing.tracingComplete', resolve));
  await send('Tracing.start', {categories: 'devtools.timeline'});

  const metrics = await evaluate(`(async () => {
    const el = document.querySelector(${JSON.stringify(selector)});
    const longTasks = [];
    const po = new PerformanceObserver(list => {
      for (const entry of list.getEntries()) longTasks.push(+entry.duration.toFixed(1));
    });
    po.observe({type: 'longtask', buffered: true});

    const t = [];
    const end = performance.now() + ${durationMs};
    const done = new Promise(resolve => {
      const tick = now => {
        t.push(now);
        if (now < end) requestAnimationFrame(tick);
        else resolve();
      };
      requestAnimationFrame(tick);
    });
    el.click();
    await done;
    po.disconnect();

    const d = t.slice(1).map((x, i) => x - t[i]).sort((a, b) => a - b);
    const p95 = d.length ? +d[Math.min(d.length - 1, Math.floor(d.length * 0.95))].toFixed(1) : null;
    return {
      frames: d.length,
      p95_ms: p95,
      over_20ms: d.filter(x => x > 20).length,
      longTasks,
    };
  })()`);

  await send('Tracing.end');
  await tracingComplete;

  const complete = traceEvents.filter(e => e.ph === 'X');
  for (const name of ['Layout', 'Paint', 'UpdateLayoutTree', 'RasterTask']) {
    const hits = complete.filter(e => e.name === name);
    const totalMs = hits.reduce((sum, e) => sum + (e.dur || 0), 0) / 1000;
    console.log(`${name}: ${hits.length} events, ${totalMs.toFixed(1)} ms`);
  }
  console.log('metrics:', JSON.stringify(metrics));
} finally {
  await cleanup();
}
