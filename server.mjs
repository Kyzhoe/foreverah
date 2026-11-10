#!/usr/bin/env node
// ForeverAH dashboard: a small local web server that downloads prices on a schedule
// (replacing "fetch-prices.mjs watch") and serves a dashboard at http://localhost:8787.
//
//   node server.mjs             start, and open the dashboard in your browser
//   node server.mjs --no-open   start without opening the browser
//
// It only listens on this PC (127.0.0.1); nothing is reachable from other machines.

import http from 'node:http';
import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { exec } from 'node:child_process';
import { loadConfig, loadState, update, getArchive, HERE } from './fetch-prices.mjs';
import { localDay, RemoteArchive } from './archive.mjs';
import { writeFile, rename } from 'node:fs/promises';

const ctx = { cfg: await loadConfig(), state: await loadState() };
const PORT = Number(ctx.cfg.port || 8787);
const URL_BASE = `http://localhost:${PORT}`;
const AVG_DAYS = 14;

let latest = null; // { items: Map, updated, history }

// "github": "Owner/repo" in config.json switches to GitHub mode: prices come from the repository
// that the GitHub Actions workflow fills, instead of being downloaded from Blizzard on this PC.
const REMOTE = ctx.cfg.github || null;
const remoteArchive = REMOTE ? new RemoteArchive(REMOTE, ctx.cfg.githubBranch || 'main') : null;
const archiveFor = () => remoteArchive ?? getArchive(ctx.cfg);

async function pullFromGitHub() {
  const get = async (file) => {
    const res = await fetch(remoteArchive.raw(file), { headers: { 'Cache-Control': 'no-cache' } });
    if (!res.ok) throw new Error(`GitHub answered ${res.status} for ${file}. Has the workflow run yet?`);
    return res;
  };
  const data = await (await get('data/latest.json')).json();
  const items = new Map();
  for (const [id, r] of Object.entries(data.items)) {
    items.set(Number(id), { min: r[0], market: r[1], qty: r[2], auctions: r[3], avg: r[4], days: r[5], commodity: r[6] === 1 });
  }
  const changed = data.updated !== latest?.updated;
  latest = { items, updated: data.updated, history: null };
  if (changed && ctx.cfg.addonDataFile) {
    // keep the addon's prices current too
    const lua = await (await get('data/Data.lua')).text();
    const tmp = ctx.cfg.addonDataFile + '.tmp';
    await writeFile(tmp, lua);
    await rename(tmp, ctx.cfg.addonDataFile);
    log(`Pulled ${items.size} items from GitHub (${REMOTE}) and updated the addon's Data.lua. /reload in game to load them.`);
  } else {
    log(changed ? `Pulled ${items.size} items from GitHub.` : 'No new data on GitHub yet.');
  }
}
let lastRun = null, nextRun = null, lastError = null, running = false;

const log = (msg) => console.log(`[${new Date().toLocaleTimeString()}] ${msg}`);

// ---------- scheduled downloads ----------

async function runUpdate() {
  if (running) return;
  running = true;
  try {
    if (REMOTE) await pullFromGitHub();
    else latest = await update(ctx, (m) => log(String(m).trim()));
    await loadBlizzardNames();
    lastError = null;
  } catch (e) {
    lastError = e.message;
    log(`Update failed: ${e.message}`);
  } finally {
    running = false;
    lastRun = Date.now();
  }
}

function schedule() {
  const ms = ctx.cfg.intervalMinutes * 60_000;
  nextRun = Date.now() + ms;
  setTimeout(async () => {
    await runUpdate();
    schedule();
  }, ms);
}

// ---------- item names from the addon's saved variables ----------
// The addon saves ForeverAHDB.itemNames[itemID] = { name, vendorPrice, quality } on logout.

function parseLua(text) {
  let i = 0;
  const ws = () => {
    for (;;) {
      while (i < text.length && /\s/.test(text[i])) i++;
      if (text.startsWith('--', i)) {
        const j = text.indexOf('\n', i);
        i = j < 0 ? text.length : j;
      } else return;
    }
  };
  const fail = () => { throw new Error(`can't read saved variables near: ${text.slice(i, i + 30)}`); };
  function str() {
    const q = text[i++];
    let s = '';
    while (i < text.length && text[i] !== q) {
      if (text[i] === '\\') {
        i++;
        const e = text[i];
        if (e === 'n') { s += '\n'; i++; }
        else if (e === 't') { s += '\t'; i++; }
        else if (/\d/.test(e)) {
          const m = /^\d{1,3}/.exec(text.slice(i, i + 3));
          s += String.fromCharCode(Number(m[0]));
          i += m[0].length;
        } else { s += e; i++; }
      } else s += text[i++];
    }
    i++;
    return s;
  }
  function value() {
    ws();
    const c = text[i];
    if (c === '{') return table();
    if (c === '"' || c === "'") return str();
    for (const [word, v] of [['true', true], ['false', false], ['nil', null]]) {
      if (text.startsWith(word, i) && !/\w/.test(text[i + word.length] || '')) { i += word.length; return v; }
    }
    const m = /^-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|inf|nan)/.exec(text.slice(i, i + 40));
    if (!m) fail();
    i += m[0].length;
    return Number(m[0]);
  }
  function table() {
    i++; // {
    const t = {};
    let n = 1;
    for (;;) {
      ws();
      if (text[i] === '}') { i++; return t; }
      let key;
      if (text[i] === '[') {
        i++;
        key = value();
        ws(); if (text[i] !== ']') fail(); i++;
        ws(); if (text[i] !== '=') fail(); i++;
      } else {
        const m = /^([A-Za-z_]\w*)\s*=(?!=)/.exec(text.slice(i, i + 200));
        if (m) { key = m[1]; i += m[0].length; }
      }
      const v = value();
      if (key === undefined) key = n++;
      t[key] = v;
      ws();
      if (text[i] === ',' || text[i] === ';') i++;
    }
  }
  const out = {};
  for (;;) {
    ws();
    if (i >= text.length) return out;
    const m = /^([A-Za-z_]\w*)\s*=/.exec(text.slice(i, i + 200));
    if (!m) fail();
    i += m[0].length;
    out[m[1]] = value();
  }
}

let names = {}, namesFile = null, namesMtime = 0, namesError = null;
let gameNames = {};      // from the addon's saved variables (most accurate for Forever)
let blizzardNames = {};  // from data/items.json, looked up on Blizzard's web API

// Names from the game win; Blizzard's item data fills in the rest.
function mergeNames() {
  names = { ...blizzardNames, ...gameNames };
}

async function loadBlizzardNames() {
  try {
    let raw;
    if (REMOTE) {
      const res = await fetch(remoteArchive.raw('data/items.json'), { headers: { 'Cache-Control': 'no-cache' } });
      if (!res.ok) return;
      raw = await res.json();
    } else {
      raw = JSON.parse(await readFile(path.join(HERE, 'data', 'items.json'), 'utf8'));
    }
    const next = {};
    for (const [id, v] of Object.entries(raw)) next[id] = { name: v[0], quality: v[1], vendor: v[2], source: v[3] };
    const added = Object.keys(next).length - Object.keys(blizzardNames).length;
    blizzardNames = next;
    mergeNames();
    if (added) log(`Loaded ${Object.keys(next).length} item names from Blizzard's item data.`);
  } catch {
    // no items.json yet
  }
}
let scan = null; // last in-game scan saved by the addon: { time, items: { id: {1: min, 2: market, 3: qty, 4: auctions} } }

async function findSavedVariables() {
  if (ctx.cfg.savedVariablesFile) return ctx.cfg.savedVariablesFile;
  // <game>/Interface/AddOns/ForeverAH/Data.lua  ->  <game>/WTF/Account/*/SavedVariables/ForeverAH.lua
  const game = path.resolve(path.dirname(ctx.cfg.addonDataFile), '..', '..', '..');
  const accounts = path.join(game, 'WTF', 'Account');
  let best = null, bestTime = 0;
  for (const acc of await readdir(accounts).catch(() => [])) {
    const f = path.join(accounts, acc, 'SavedVariables', 'ForeverAH.lua');
    const st = await stat(f).catch(() => null);
    if (st && st.mtimeMs > bestTime) { best = f; bestTime = st.mtimeMs; }
  }
  return best;
}

async function loadNames() {
  const f = await findSavedVariables();
  if (!f) return;
  const st = await stat(f).catch(() => null);
  if (!st || (f === namesFile && st.mtimeMs === namesMtime)) return;
  try {
    const vars = parseLua(await readFile(f, 'utf8'));
    const raw = vars.ForeverAHDB?.itemNames || {};
    const next = {};
    for (const [id, v] of Object.entries(raw)) {
      if (v && v[1]) next[id] = { name: v[1], vendor: v[2] || 0, quality: v[3] ?? 1 };
    }
    gameNames = next;
    mergeNames();
    namesError = null;
    const s = vars.ForeverAHDB?.scan;
    scan = s && s.time && s.items ? s : null;
    if (scan) {
      log(`Found an in-game scan from ${new Date(scan.time * 1000).toLocaleString()}.`);
      const arch = REMOTE ? null : archiveFor(); // in GitHub mode the workflow owns the archive
      if (arch) {
        const entries = Object.entries(scan.items).map(([id, r]) =>
          [id, { min: r[1], market: r[2], qty: r[3], auctions: r[4] }]);
        const saved = await arch.add(scan.time, entries);
        if (saved) log(`Archived ${saved} price changes from the scan.`);
      }
    }
    log(`Loaded ${Object.keys(gameNames).length} item names from the addon's saved variables.`);
  } catch (e) {
    namesError = e.message;
    log(`Couldn't read item names: ${e.message}`);
  }
  namesFile = f;
  namesMtime = st.mtimeMs;
}

// ---------- API ----------

// The in-game scan is used when it's newer than the last download.
const useScan = () => Boolean(scan && scan.time > (latest?.updated ?? 0));

let archiveInfo = null;
async function refreshArchiveInfo() {
  const arch = archiveFor();
  archiveInfo = arch ? await arch.info() : null;
}

function status() {
  const fromScan = useScan();
  return {
    archive: archiveInfo,
    updated: fromScan ? scan.time : latest?.updated ?? null,
    source: fromScan ? 'scan' : 'download',
    downloaded: latest?.updated ?? null,
    scanned: scan?.time ?? null,
    lastRun, nextRun, running, error: lastError,
    region: ctx.cfg.region, ruleset: ctx.cfg.rulesetId, houses: ctx.cfg.houseIds,
    remote: REMOTE,
    itemCount: fromScan ? Object.keys(scan.items).length : latest?.items.size ?? 0,
    nameCount: Object.keys(names).length,
    namesFile, namesError,
    avgDays: AVG_DAYS,
    intervalMinutes: ctx.cfg.intervalMinutes,
  };
}

function itemList() {
  const out = [];
  const entry = (id, s, live) => {
    const n = names[id];
    out.push({
      id, name: n?.name ?? null, quality: n?.quality ?? null, vendor: n?.vendor ?? null,
      min: live.min, market: live.market, avg: s?.avg ?? live.market, days: s?.days ?? 1,
      qty: live.qty, auctions: live.auctions, commodity: Boolean(s?.commodity),
    });
  };
  if (useScan()) {
    for (const [key, r] of Object.entries(scan.items)) {
      const id = Number(key);
      entry(id, latest?.items.get(id), { min: r[1], market: r[2], qty: r[3], auctions: r[4] });
    }
  } else if (latest) {
    for (const [id, s] of latest.items) entry(id, s, s);
  }
  return out;
}

function itemHistory(id) {
  const h = latest?.history?.items?.[id] || [];
  return h.map(([day, sum, n, min, qty]) => ({
    date: new Date(day * 86400000).toISOString().slice(0, 10),
    market: Math.round(sum / n),
    min: min ?? null,
    qty: qty != null ? Math.round(qty / n) : null,
  }));
}

// ---------- archive queries ----------

const MAX_ROWS = 5000;

function archiveFilters(params) {
  const today = localDay(Date.now() / 1000);
  const weekAgo = localDay(Date.now() / 1000 - 6 * 86400);
  const num = (k) => (params.get(k) === null || params.get(k) === '' ? null : Number(params.get(k)));
  let ids = params.get('ids') ? params.get('ids').split(',').map(Number).filter(Number.isFinite) : null;
  const q = (params.get('q') || '').trim().toLowerCase();
  if (q) {
    // match names (or an exact item ID) to a set of IDs
    const matched = Object.entries(names)
      .filter(([id, n]) => n.name.toLowerCase().includes(q) || id === q)
      .map(([id]) => Number(id));
    if (/^\d+$/.test(q)) matched.push(Number(q));
    ids = ids ? ids.filter((id) => matched.includes(id)) : matched;
  }
  return {
    from: params.get('from') || weekAgo,
    to: params.get('to') || today,
    ids,
    minPrice: num('minPrice'),
    maxPrice: num('maxPrice'),
  };
}

async function archiveQuery(params) {
  const arch = archiveFor();
  if (!arch) return { rows: [], total: 0, truncated: false, disabled: true };
  const filters = archiveFilters(params);
  if (filters.ids && !filters.ids.length) return { rows: [], total: 0, truncated: false, filters };
  const limit = Math.min(Number(params.get('limit')) || MAX_ROWS, 200000);
  // keep the newest `limit` rows
  const rows = [];
  let total = 0;
  await arch.scan(filters, (r) => {
    total++;
    rows.push(r);
    if (rows.length > limit * 2) rows.splice(0, rows.length - limit);
  });
  const kept = rows.slice(-limit);
  for (const r of kept) {
    r.name = names[r.id]?.name ?? null;
    r.quality = names[r.id]?.quality ?? null;
  }
  return { rows: kept, total, truncated: total > kept.length, filters };
}

async function archiveCSV(res, params) {
  const arch = archiveFor();
  const filters = archiveFilters(params);
  res.writeHead(200, {
    'Content-Type': 'text/csv; charset=utf-8',
    'Content-Disposition': `attachment; filename="foreverah-${filters.from}-to-${filters.to}.csv"`,
  });
  res.write('time,item_id,item_name,cheapest_copper,market_copper,listed,auctions\n');
  if (arch && !(filters.ids && !filters.ids.length)) {
    let buf = '';
    await arch.scan(filters, (r) => {
      const time = new Date(r.t * 1000).toLocaleString('sv-SE'); // 2026-11-09 23:15:00, local
      const name = (names[r.id]?.name ?? '').replace(/"/g, '""');
      buf += `${time},${r.id},"${name}",${r.min ?? ''},${r.market ?? ''},${r.qty},${r.auctions}\n`;
      if (buf.length > 65536) { res.write(buf); buf = ''; }
    });
    res.write(buf);
  }
  res.end();
}

function send(res, code, body, type = 'application/json') {
  const data = type === 'application/json' ? JSON.stringify(body) : body;
  res.writeHead(code, { 'Content-Type': `${type}; charset=utf-8`, 'Cache-Control': 'no-store' });
  res.end(data);
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, URL_BASE);
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) {
      return send(res, 200, await readFile(path.join(HERE, 'dashboard.html'), 'utf8'), 'text/html');
    }
    if (url.pathname === '/api/status') {
      await loadNames();
      await refreshArchiveInfo();
      return send(res, 200, status());
    }
    if (url.pathname === '/api/items') {
      await loadNames();
      return send(res, 200, itemList());
    }
    if (url.pathname === '/api/archive') {
      await loadNames();
      return send(res, 200, await archiveQuery(url.searchParams));
    }
    if (url.pathname === '/api/archive.csv') {
      await loadNames();
      return archiveCSV(res, url.searchParams);
    }
    if (url.pathname === '/api/history') {
      return send(res, 200, itemHistory(Number(url.searchParams.get('id'))));
    }
    if (url.pathname === '/api/update' && req.method === 'POST') {
      await runUpdate();
      return send(res, 200, status());
    }
    send(res, 404, { error: 'not found' });
  } catch (e) {
    send(res, 500, { error: e.message });
  }
});

function openBrowser(url) {
  const cmd = process.platform === 'win32' ? `start "" "${url}"`
    : process.platform === 'darwin' ? `open "${url}"` : `xdg-open "${url}"`;
  exec(cmd, () => {});
}

server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use. Is the dashboard already running? Otherwise set "port" in config.json.`);
  } else {
    console.error(e.message);
  }
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', async () => {
  log(`ForeverAH dashboard running at ${URL_BASE}  (Ctrl+C to stop)`);
  if (REMOTE) log(`GitHub mode: reading prices from https://github.com/${REMOTE}`);
  await loadNames();
  if (!process.argv.includes('--no-open')) openBrowser(URL_BASE);
  await runUpdate();
  schedule();
});
