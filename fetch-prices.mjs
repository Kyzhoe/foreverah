#!/usr/bin/env node
// ForeverAH price fetcher for WoW: Forever.
// Downloads auction house data from Blizzard's (undocumented) Forever API and
// writes it as a Lua file that the ForeverAH addon loads on login or /reload.
//
// Needs Node 18 or newer. No npm packages.
//
//   node fetch-prices.mjs list            list the auction houses and their sizes
//   node fetch-prices.mjs find 55s55c --item 247786   search listings by price, item, qty...
//                                         (run "find --help" for every filter)
//   node fetch-prices.mjs item 2589 113 114   cheapest listings of an item in each house
//   node fetch-prices.mjs                 download your houses and write Data.lua
//   node fetch-prices.mjs watch           do that every intervalMinutes, forever

import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Archive } from './archive.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.join(HERE, 'config.json');
const STATE_PATH = path.join(HERE, 'state.json'); // access token + Last-Modified per house
const CACHE_DIR = path.join(HERE, 'cache');       // last downloaded copy of each house
const REGIONS = ['us', 'eu', 'kr', 'tw'];

// ---------- small helpers ----------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function readJson(file, fallback) {
  let text;
  try {
    text = await readFile(file, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT' && fallback !== undefined) return fallback;
    throw e;
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${path.basename(file)} is not valid JSON. Check for a missing comma or quote.`);
  }
}

async function writeAtomic(file, text) {
  await mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
  await writeFile(tmp, text, 'utf8');
  await rename(tmp, file);
}

// Accepts "12345" (copper) or "1g23s45c" / "1g 23s" / "45c".
function parsePrice(text) {
  if (!text) return NaN;
  const t = String(text).toLowerCase().replace(/\s+/g, '');
  if (/^\d+$/.test(t)) return Number(t);
  const m = t.match(/^(?:(\d+)g)?(?:(\d+)s)?(?:(\d+)c)?$/);
  if (!m || t === '') return NaN;
  return Number(m[1] || 0) * 10000 + Number(m[2] || 0) * 100 + Number(m[3] || 0);
}

function money(copper) {
  const c = Math.round(copper);
  const g = Math.floor(c / 10000), s = Math.floor((c % 10000) / 100), cp = c % 100;
  return `${g}g ${s}s ${cp}c`;
}

const houseName = (h) =>
  typeof h.name === 'string' ? h.name : (h.name?.en_US ?? `House ${h.id}`);

// ---------- config & state ----------

// Settings come from config.json. On GitHub Actions there's no config.json; settings come
// from environment variables instead (the workflow fills these from the repository's secrets).
function configFromEnv() {
  const e = process.env;
  if (!e.BLIZZARD_CLIENT_ID) return null;
  return {
    clientId: e.BLIZZARD_CLIENT_ID,
    clientSecret: e.BLIZZARD_CLIENT_SECRET,
    region: e.FAH_REGION || 'us',
    rulesetId: e.FAH_RULESET || 1,
    houseIds: String(e.FAH_HOUSES || '').split(',').map((s) => s.trim()).filter(Boolean),
    addonDataFile: path.join(HERE, 'data', 'Data.lua'),
    latestFile: path.join(HERE, 'data', 'latest.json'),
  };
}

async function loadConfig() {
  let cfg;
  if (existsSync(CONFIG_PATH)) cfg = await readJson(CONFIG_PATH);
  else cfg = configFromEnv();
  if (!cfg) throw new Error('config.json not found. Copy config.example.json to config.json and fill it in.');
  cfg.region = String(cfg.region || 'us').toLowerCase();
  if (!REGIONS.includes(cfg.region)) throw new Error(`region must be one of ${REGIONS.join(', ')}`);
  cfg.rulesetId = Number(cfg.rulesetId ?? 1);
  cfg.houseIds = (cfg.houseIds || []).map(Number).filter(Number.isFinite);
  cfg.intervalMinutes = Math.max(15, Number(cfg.intervalMinutes || 60));
  cfg.marketPercent = Math.min(100, Math.max(1, Number(cfg.marketPercent || 20)));
  return cfg;
}

const loadState = () => readJson(STATE_PATH, {});
const saveState = (state) => writeAtomic(STATE_PATH, JSON.stringify(state, null, 2));

// ---------- Blizzard API ----------

// Several requests can need a token at once; they share one token request.
function getToken(ctx, force = false) {
  if (!force && ctx.tokenPromise) return ctx.tokenPromise;
  ctx.tokenPromise = fetchToken(ctx, force).finally(() => { ctx.tokenPromise = null; });
  return ctx.tokenPromise;
}

async function fetchToken(ctx, force) {
  const { clientId, clientSecret } = ctx.cfg;
  if (!clientId || !clientSecret || clientId.startsWith('PASTE') || clientSecret.startsWith('PASTE')) {
    throw new Error('Put your Client ID and Client Secret from develop.battle.net into config.json.');
  }
  const now = Date.now();
  if (!force && ctx.state.token && ctx.state.tokenExpires > now + 5 * 60_000) return ctx.state.token;
  const basic = Buffer.from(`${ctx.cfg.clientId}:${ctx.cfg.clientSecret}`).toString('base64');
  const res = await fetch('https://oauth.battle.net/token', {
    method: 'POST',
    headers: { Authorization: `Basic ${basic}`, 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
  });
  if (!res.ok) {
    throw new Error(`Token request failed (HTTP ${res.status}). Check your Client ID and Secret. ${await res.text()}`);
  }
  const j = await res.json();
  ctx.state.token = j.access_token;
  ctx.state.tokenExpires = now + (j.expires_in || 3600) * 1000;
  await saveState(ctx.state);
  return ctx.state.token;
}

// GET a Game Data route in the Forever namespace. Node's fetch asks for gzip and
// unpacks it automatically. Retries on 429/5xx and refreshes an expired token once.
async function api(ctx, route, { ifModifiedSince, namespace } = {}) {
  const { region } = ctx.cfg;
  const ns = namespace || `dynamic-forever-${region}`;
  const url = `https://${region}.api.blizzard.com${route}?namespace=${ns}&locale=en_US`;
  let refreshed = false;
  for (let attempt = 1; ; attempt++) {
    const headers = { Authorization: `Bearer ${await getToken(ctx)}` };
    if (ifModifiedSince) headers['If-Modified-Since'] = ifModifiedSince;
    const res = await fetch(url, { headers });
    if (res.status === 304) return { notModified: true };
    if (res.status === 401 && !refreshed) {
      refreshed = true;
      await getToken(ctx, true);
      continue;
    }
    if ((res.status === 429 || res.status >= 500) && attempt < 4) {
      await sleep(2000 * attempt);
      continue;
    }
    if (!res.ok) {
      const err = new Error(`HTTP ${res.status} for ${route}`);
      err.status = res.status;
      throw err;
    }
    return { data: await res.json(), lastModified: res.headers.get('last-modified') || undefined };
  }
}

// Like api(), but sends If-Modified-Since and reuses the cached copy on 304.
async function apiCached(ctx, route, key) {
  const cacheFile = path.join(CACHE_DIR, `${key}.json`);
  ctx.state.lastModified ??= {};
  const lm = ctx.state.lastModified[key];
  const haveCache = Boolean(lm) && existsSync(cacheFile);
  const res = await api(ctx, route, { ifModifiedSince: haveCache ? lm : undefined });
  if (res.notModified) return { data: await readJson(cacheFile), changed: false, lastModified: lm };
  await writeAtomic(cacheFile, JSON.stringify(res.data));
  if (res.lastModified) ctx.state.lastModified[key] = res.lastModified;
  return { data: res.data, changed: true, lastModified: res.lastModified };
}

async function getHouses(ctx) {
  const r = ctx.cfg.rulesetId;
  let res;
  try {
    res = await api(ctx, `/data/wow/ruleset/${r}/auctions/index`);
  } catch (e) {
    if (e.status !== 404) throw e;
    res = await api(ctx, `/data/wow/ruleset/${r}/auctions/`); // some reports say only the trailing-slash form works
  }
  return (res.data.auctions || []).map((h) => ({ id: h.id, name: houseName(h) }));
}

async function fetchHouse(ctx, houseId) {
  const r = ctx.cfg.rulesetId;
  const main = await apiCached(ctx, `/data/wow/ruleset/${r}/auctions/${houseId}`, `r${r}-h${houseId}`);
  const house = {
    id: houseId,
    name: main.data.name ? houseName(main.data) : `House ${houseId}`,
    auctions: main.data.auctions || [], // missing = empty house, not an error
    commodities: [],
    lastModified: main.lastModified,
    changed: main.changed,
  };
  if (main.data.commodities) {
    const c = await apiCached(ctx, `/data/wow/ruleset/${r}/auctions/${houseId}/commodities`, `r${r}-h${houseId}-c`);
    house.commodities = c.data.auctions || [];
    house.changed ||= c.changed;
  }
  return house;
}

// ---------- prices ----------

// One row per listing with a per-unit price. Regular auctions are assumed to have
// `buyout` for the whole stack (as in the Classic API); bid-only auctions are skipped.
function listingRows(house) {
  const rows = [];
  for (const a of house.auctions) {
    if (a.buyout == null || !a.item) continue;
    const qty = a.quantity || 1;
    rows.push({ itemId: a.item.id, qty, unit: a.buyout / qty, total: a.buyout, house: house.id, commodity: false });
  }
  for (const c of house.commodities) {
    if (c.unit_price == null || !c.item) continue;
    const qty = c.quantity || 1;
    rows.push({ itemId: c.item.id, qty, unit: c.unit_price, total: c.unit_price * qty, house: house.id, commodity: true });
  }
  return rows;
}

// min    = cheapest per-unit price
// market = average per-unit price of the cheapest `marketPercent`% of units listed
function computeStats(rows, marketPercent) {
  const byItem = new Map();
  for (const r of rows) {
    if (!byItem.has(r.itemId)) byItem.set(r.itemId, []);
    byItem.get(r.itemId).push(r);
  }
  const items = new Map();
  for (const [id, list] of byItem) {
    list.sort((a, b) => a.unit - b.unit);
    const totalQty = list.reduce((s, r) => s + r.qty, 0);
    const target = Math.max(1, Math.ceil((totalQty * marketPercent) / 100));
    let taken = 0, sum = 0;
    for (const r of list) {
      if (taken >= target) break;
      const take = Math.min(r.qty, target - taken);
      sum += take * r.unit;
      taken += take;
    }
    items.set(id, {
      min: Math.round(list[0].unit),
      market: Math.round(sum / taken),
      qty: totalQty,
      auctions: list.length,
      commodity: list.some((r) => r.commodity),
    });
  }
  return items;
}

// ---------- price history ----------
// history.json: { lastSnapshot, items: { [itemId]: [[day, sumMarket, snapshots, dayMin, sumQty], ...] } }
// One entry per day (day = days since 1970, UTC). Kept for KEEP_DAYS; the "average"
// used for deals is over the last AVG_DAYS.

const HISTORY_PATH = path.join(HERE, 'history.json');
const KEEP_DAYS = 90;
const AVG_DAYS = 14;

function addToHistory(history, items, snapshotSec) {
  history.items ??= {};
  if (history.lastSnapshot === snapshotSec) return; // same Blizzard snapshot: don't count it twice
  history.lastSnapshot = snapshotSec;
  const day = Math.floor(snapshotSec / 86400);
  for (const [id, s] of items) {
    const h = (history.items[id] ??= []);
    const last = h[h.length - 1];
    if (last && last[0] === day) {
      last[1] += s.market;
      last[2] += 1;
      last[3] = last[3] == null ? s.min : Math.min(last[3], s.min);
      last[4] = (last[4] ?? 0) + s.qty;
    } else {
      h.push([day, s.market, 1, s.min, s.qty]);
    }
  }
  for (const id of Object.keys(history.items)) {
    const kept = history.items[id].filter((d) => d[0] > day - KEEP_DAYS);
    if (kept.length) history.items[id] = kept;
    else delete history.items[id];
  }
}

function historyAverage(history, id) {
  const all = history.items?.[id];
  if (!all?.length) return null;
  const lastDay = all[all.length - 1][0];
  const h = all.filter((d) => d[0] > lastDay - AVG_DAYS);
  const daily = h.map((d) => d[1] / d[2]);
  return { avg: Math.round(daily.reduce((a, b) => a + b, 0) / daily.length), days: h.length };
}

function toLua(meta, items) {
  const out = [
    '-- Generated by fetch-prices.mjs. Overwritten on every update, so don\'t edit it.',
    '-- items[itemID] = { minBuyout, marketValue, quantityListed, auctionCount, avg14Days, daysOfHistory, isCommodity }',
    '-- prices in copper; isCommodity is 1 or 0',
    'ForeverAH_Data = {',
    `  updated = ${meta.updated},`,
    `  region = "${meta.region}",`,
    `  ruleset = ${meta.ruleset},`,
    `  houses = { ${meta.houses.join(', ')} },`,
    '  items = {',
  ];
  for (const id of [...items.keys()].sort((a, b) => a - b)) {
    const s = items.get(id);
    const avg = s.avg ?? s.market;
    const days = s.days ?? 1;
    out.push(`    [${id}] = {${s.min},${s.market},${s.qty},${s.auctions},${avg},${days},${s.commodity ? 1 : 0}},`);
  }
  out.push('  },', '}', '');
  return out.join('\n');
}

// ---------- commands ----------

async function cmdList(ctx) {
  const houses = await getHouses(ctx);
  console.log(`Ruleset ${ctx.cfg.rulesetId}, ${ctx.cfg.region.toUpperCase()}: ${houses.length} auction houses\n`);
  for (const h of houses) {
    const house = await fetchHouse(ctx, h.id);
    console.log(
      `  ${String(h.id).padEnd(5)} ${h.name.padEnd(28)} ` +
      `${String(house.auctions.length).padStart(7)} auctions  ${String(house.commodities.length).padStart(7)} commodities` +
      (house.lastModified ? `   updated ${house.lastModified}` : '')
    );
  }
}

const FIND_USAGE = `Usage: node fetch-prices.mjs find [price] [filters]

Filters (combine any of them; a listing must match all):
  --item <id>          only this item ID
  --price <price>      exact price, per unit or stack total   (same as giving a bare price)
  --min <price>        per-unit price at least this
  --max <price>        per-unit price at most this
  --qty <n>            stack size exactly n
  --house <ids>        only these houses, e.g. --house 113,114   (default: all)
  --limit <n>          show at most n matches per house (default 25)

Prices can be copper (5555) or like 55s55c, 1g, 2g50s.

Examples:
  node fetch-prices.mjs find 55s55c --item 247786
  node fetch-prices.mjs find --item 247786 --max 10c --house 113,114
  node fetch-prices.mjs find --item 2589 --qty 20`;

function parseFindArgs(args) {
  const f = { limit: 25 };
  const price = (flag, v) => {
    const p = parsePrice(v);
    if (!Number.isFinite(p) || p < 0) throw new Error(`Bad price for ${flag}: "${v}"\n\n${FIND_USAGE}`);
    return p;
  };
  const int = (flag, v) => {
    const n = Number(v);
    if (!Number.isInteger(n) || n <= 0) throw new Error(`Bad number for ${flag}: "${v}"\n\n${FIND_USAGE}`);
    return n;
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    const next = () => {
      if (i + 1 >= args.length) throw new Error(`${a} needs a value\n\n${FIND_USAGE}`);
      return args[++i];
    };
    switch (a) {
      case '--item': f.item = int(a, next()); break;
      case '--price': f.price = price(a, next()); break;
      case '--min': f.min = price(a, next()); break;
      case '--max': f.max = price(a, next()); break;
      case '--qty': f.qty = int(a, next()); break;
      case '--limit': f.limit = int(a, next()); break;
      case '--house': f.houses = next().split(',').map((s) => int(a, s.trim())); break;
      case '--help': case '-h': throw new Error(FIND_USAGE);
      default:
        if (a.startsWith('--')) throw new Error(`Unknown filter ${a}\n\n${FIND_USAGE}`);
        f.price = price('price', a); // bare price, as before
    }
  }
  if (f.item == null && f.price == null && f.min == null && f.max == null && f.qty == null) {
    throw new Error(FIND_USAGE);
  }
  return f;
}

function describeFilters(f) {
  const parts = [];
  if (f.item != null) parts.push(`item ${f.item}`);
  if (f.price != null) parts.push(`price ${money(f.price)}`);
  if (f.min != null) parts.push(`at least ${money(f.min)} each`);
  if (f.max != null) parts.push(`at most ${money(f.max)} each`);
  if (f.qty != null) parts.push(`quantity ${f.qty}`);
  return parts.join(', ');
}

function matches(r, f) {
  if (f.item != null && r.itemId !== f.item) return false;
  if (f.price != null && r.total !== f.price && Math.round(r.unit) !== f.price) return false;
  if (f.min != null && r.unit < f.min) return false;
  if (f.max != null && r.unit > f.max) return false;
  if (f.qty != null && r.qty !== f.qty) return false;
  return true;
}

async function cmdFind(ctx, args) {
  const f = parseFindArgs(args);
  const houses = (await getHouses(ctx)).filter((h) => !f.houses || f.houses.includes(h.id));
  const where = f.houses ? `houses ${f.houses.join(', ')}` : 'every house';
  console.log(`Looking for listings with ${describeFilters(f)} in ${where}...\n`);

  const foundIn = [];
  for (const h of houses) {
    const house = await fetchHouse(ctx, h.id);
    const hits = listingRows(house).filter((r) => matches(r, f)).sort((a, b) => a.unit - b.unit);
    if (!hits.length) continue;
    foundIn.push(h.id);
    const qty = hits.reduce((s, r) => s + r.qty, 0);
    console.log(`  House ${h.id} (${h.name}): ${hits.length} match${hits.length === 1 ? '' : 'es'}, ${qty} item${qty === 1 ? '' : 's'}`);
    for (const r of hits.slice(0, f.limit)) {
      console.log(`      item ${String(r.itemId).padEnd(7)} ${String(r.qty).padStart(4)} x ${money(r.unit)} each   (${money(r.total)} total)`);
    }
    if (hits.length > f.limit) console.log(`      ...and ${hits.length - f.limit} more (use --limit to show more)`);
    console.log('');
  }

  if (!foundIn.length) {
    console.log('No match. Blizzard refreshes this data roughly hourly, so a listing posted recently may not be in it yet.');
  } else if (foundIn.length === 1 && f.price != null) {
    console.log(`Only house ${foundIn[0]} matched. If that's your test listing, set "houseIds": [${foundIn[0]}] in config.json.`);
  }
}

// Show the cheapest listings of one item in every house (or only the given ones),
// so you can compare them with what the in-game auction house shows.
async function cmdItem(ctx, args) {
  const [itemArg, ...houseArgs] = args;
  const itemId = Number(itemArg);
  if (!Number.isInteger(itemId) || itemId <= 0) {
    throw new Error('Usage: node fetch-prices.mjs item <itemID> [houseID ...]   e.g. item 2589 113 114');
  }
  const only = houseArgs.map(Number).filter(Number.isFinite);
  const houses = (await getHouses(ctx)).filter((h) => !only.length || only.includes(h.id));
  console.log(`Item ${itemId}, cheapest listings per house:\n`);
  for (const h of houses) {
    const house = await fetchHouse(ctx, h.id);
    const rows = listingRows(house).filter((r) => r.itemId === itemId).sort((a, b) => a.unit - b.unit);
    if (!rows.length) {
      if (only.length) console.log(`  ${h.id} ${h.name}: none listed\n`);
      continue;
    }
    const qty = rows.reduce((s, r) => s + r.qty, 0);
    console.log(`  ${h.id} ${h.name}: ${rows.length} listings, ${qty} total`);
    for (const r of rows.slice(0, 8)) {
      console.log(`      ${String(r.qty).padStart(4)} x ${money(r.unit)} each   (${money(r.total)} total)`);
    }
    console.log('');
  }
  console.log(`Data is from Blizzard's last snapshot, so very new or just-sold listings won't line up exactly.`);
}

// One archive per process (see archive.mjs). "archive": false in config.json turns it off.
let archive = null;
export function getArchive(cfg) {
  if (cfg.archive === false) return null;
  archive ??= new Archive(path.join(HERE, 'archive'), {
    minChangePct: Number(cfg.archiveMinChangePct ?? 5),
    qtyChangePct: Number(cfg.archiveQtyChangePct ?? 25),
    compressAfterDays: Number(cfg.archiveCompressAfterDays ?? 7),
  });
  return archive;
}

// Downloads (or reuses) your houses, updates history and, if Blizzard has new data,
// rewrites Data.lua. Returns { items, updated, changed, history } for the dashboard.
export async function update(ctx, log = console.log) {
  if (!ctx.cfg.houseIds.length) {
    throw new Error('No houseIds in config.json yet. Run "list" and "find" first to work out which house is yours.');
  }
  if (!ctx.cfg.addonDataFile) throw new Error('Set "addonDataFile" in config.json to the path of ForeverAH\\Data.lua.');

  const rows = [];
  const lastMods = [];
  let changed = false;
  for (const id of ctx.cfg.houseIds) {
    const house = await fetchHouse(ctx, id);
    for (const r of listingRows(house)) rows.push(r); // not push(...rows): 200k+ arguments overflows the stack
    if (house.lastModified) lastMods.push(Date.parse(house.lastModified));
    changed ||= house.changed;
    log(`  House ${id}: ${house.auctions.length} auctions, ${house.commodities.length} commodities${house.changed ? '' : ' (unchanged)'}`);
  }
  await saveState(ctx.state);

  const items = computeStats(rows, ctx.cfg.marketPercent);
  const updated = Math.floor((lastMods.length ? Math.max(...lastMods) : Date.now()) / 1000);

  const history = await readJson(HISTORY_PATH, {});
  addToHistory(history, items, updated);
  await writeAtomic(HISTORY_PATH, JSON.stringify(history));
  for (const [id, s] of items) Object.assign(s, historyAverage(history, id) ?? {});

  const arch = getArchive(ctx.cfg);
  if (arch) {
    const saved = await arch.add(updated, items); // skips snapshots it already has
    if (saved) log(`Archived ${saved} price changes.`);
  }

  if (!changed && existsSync(ctx.cfg.addonDataFile)) {
    log('No new data from Blizzard since the last run. Data.lua left as it is.');
  } else {
    const lua = toLua({ updated, region: ctx.cfg.region, ruleset: ctx.cfg.rulesetId, houses: ctx.cfg.houseIds }, items);
    await writeAtomic(ctx.cfg.addonDataFile, lua);
    log(`Wrote ${items.size} items to ${ctx.cfg.addonDataFile}. Type /reload in game to load them.`);
  }
  if (ctx.cfg.latestFile) {
    // compact copy of the latest prices for the dashboard: items[id] = [min, market, qty, auctions, avg, days, commodity]
    const out = { updated, region: ctx.cfg.region, ruleset: ctx.cfg.rulesetId, houses: ctx.cfg.houseIds, items: {} };
    for (const [id, s] of items) {
      out.items[id] = [s.min, s.market, s.qty, s.auctions, s.avg ?? s.market, s.days ?? 1, s.commodity ? 1 : 0];
    }
    await writeAtomic(ctx.cfg.latestFile, JSON.stringify(out));
  }
  return { items, updated, changed, history };
}

async function cmdUpdate(ctx) {
  await update(ctx);
}

// ---------- item names ----------
// data/items.json: { [itemId]: [name, quality (0 poor .. 5 legendary), vendorPrice, source] }
// Each item ID is looked up once. Forever's own item data is tried first; items it doesn't
// have are tried in Classic Era, Classic and Retail item data. Misses are retried weekly.

const ITEMS_PATH = path.join(HERE, 'data', 'items.json');
const MISSING_PATH = path.join(HERE, 'data', 'items-missing.json');
const SOURCE_LABEL = { forever: 'forever', classic1x: 'classic-era', classic: 'classic', retail: 'retail' };
const QUALITY = { POOR: 0, COMMON: 1, UNCOMMON: 2, RARE: 3, EPIC: 4, LEGENDARY: 5, ARTIFACT: 6, HEIRLOOM: 7 };

async function lookupItem(ctx, id, namespaces) {
  for (const ns of namespaces) {
    try {
      const { data } = await api(ctx, `/data/wow/item/${id}`, { namespace: ns });
      if (data?.name) {
        return [data.name, QUALITY[data.quality?.type] ?? 1, data.sell_price ?? 0, SOURCE_LABEL[ns.split('-').slice(1, -1).join('-') || 'retail']];
      }
    } catch (e) {
      if (e.status !== 404) throw e;
    }
  }
  return null;
}

export async function updateItemNames(ctx, ids, log = console.log) {
  const r = ctx.cfg.region;
  const namespaces = [`static-forever-${r}`, `static-classic1x-${r}`, `static-classic-${r}`, `static-${r}`];
  const items = await readJson(ITEMS_PATH, {});
  const missing = await readJson(MISSING_PATH, {});
  const now = Math.floor(Date.now() / 1000);
  const todo = [...new Set(ids.map(String))]
    .filter((id) => !items[id] && !(missing[id] && now - missing[id] < 7 * 86400));
  if (!todo.length) {
    log('Item names: nothing new to look up.');
    return { found: 0, missing: 0 };
  }
  log(`Item names: looking up ${todo.length} items...`);
  let found = 0, notFound = 0, next = 0;
  const bySource = {};
  async function worker() {
    while (next < todo.length) {
      const id = todo[next++];
      const info = await lookupItem(ctx, id, namespaces);
      if (info) {
        items[id] = info;
        delete missing[id];
        found++;
        bySource[info[3]] = (bySource[info[3]] || 0) + 1;
      } else {
        missing[id] = now;
        notFound++;
      }
    }
  }
  await Promise.all(Array.from({ length: 8 }, worker)); // 8 at a time, well under Blizzard's limits
  await writeAtomic(ITEMS_PATH, JSON.stringify(items));
  await writeAtomic(MISSING_PATH, JSON.stringify(missing));
  log(`Item names: found ${found} (${Object.entries(bySource).map(([k, v]) => `${v} from ${k}`).join(', ') || 'none'}), not found ${notFound}. ` +
    `${Object.keys(items).length} names known in total.`);
  return { found, missing: notFound };
}

async function cmdItems(ctx) {
  const latest = await readJson(ctx.cfg.latestFile || path.join(HERE, 'data', 'latest.json'), null);
  let ids;
  if (latest?.items) ids = Object.keys(latest.items);
  else ids = [...(await update(ctx)).items.keys()].map(String);
  await updateItemNames(ctx, ids);
}

async function cmdWatch(ctx) {
  console.log(`Updating every ${ctx.cfg.intervalMinutes} minutes. Press Ctrl+C to stop.`);
  for (;;) {
    console.log(`\n[${new Date().toLocaleString()}]`);
    try {
      await cmdUpdate(ctx);
    } catch (e) {
      console.error(`Update failed: ${e.message}`);
    }
    await sleep(ctx.cfg.intervalMinutes * 60_000);
  }
}

// ---------- main ----------

async function main() {
  const [cmd = 'update', ...args] = process.argv.slice(2);
  const ctx = { cfg: await loadConfig(), state: await loadState() };
  switch (cmd) {
    case 'list': return cmdList(ctx);
    case 'find': return cmdFind(ctx, args);
    case 'item': return cmdItem(ctx, args);
    case 'update': return cmdUpdate(ctx);
    case 'watch': return cmdWatch(ctx);
    case 'items': return cmdItems(ctx);
    default:
      throw new Error(`Unknown command "${cmd}". Use list, find, item, items, update or watch.`);
  }
}

export { loadConfig, loadState, readJson, money, HERE };

// Only run the command line when this file is run directly, not when server.mjs imports it.
const runDirectly = process.argv[1] &&
  fileURLToPath(import.meta.url).toLowerCase() === path.resolve(process.argv[1]).toLowerCase();
if (runDirectly) {
  main().catch((e) => {
    console.error(`Error: ${e.message}`);
    process.exitCode = 1;
  });
}
