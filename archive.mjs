// ForeverAH price archive: keeps price history small by only saving changes.
//
// For each snapshot (an hourly download or an in-game scan), an item gets a row only if:
//   - it's the item's first row of the day (a daily baseline), or
//   - its cheapest or market price moved by at least minChangePct % since its last saved row, or
//   - the amount listed moved by at least qtyChangePct %, or
//   - it disappeared from the AH (saved as a row with no prices and qty 0) or came back.
// So between saved rows, an item's price stayed within those limits.
//
// Files: archive/YYYY-MM-DD.csv (local date), columns: time,item,min,market,qty,auctions
// time is Unix seconds; prices are in copper. Days older than compressAfterDays are gzipped
// to YYYY-MM-DD.csv.gz. archive/last.json remembers each item's last saved row.

import { readFile, writeFile, appendFile, mkdir, readdir, stat, rename, unlink } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { gzipSync, gunzipSync } from 'node:zlib';
import path from 'node:path';

const HEADER = 'time,item,min,market,qty,auctions\n';
const FILE_RE = /^(\d{4}-\d{2}-\d{2})\.csv(\.gz)?$/;

export const localDay = (sec) => new Date(sec * 1000).toLocaleDateString('en-CA'); // YYYY-MM-DD

function moved(a, b, pct) {
  if (a == null || b == null) return a !== b;
  return Math.abs(a - b) / Math.max(Math.abs(b), 1) >= pct / 100;
}

export class Archive {
  constructor(dir, { minChangePct = 5, qtyChangePct = 25, compressAfterDays = 7 } = {}) {
    this.dir = dir;
    this.minChangePct = minChangePct;
    this.qtyChangePct = qtyChangePct;
    this.compressAfterDays = compressAfterDays;
    this.statePath = dir ? path.join(dir, 'last.json') : null;
    this.queue = Promise.resolve();
  }

  // Run archive work one job at a time (downloads and scans can arrive together).
  serial(fn) {
    const run = this.queue.then(fn, fn);
    this.queue = run.catch(() => {});
    return run;
  }

  async loadState() {
    if (!this.state) {
      try {
        this.state = JSON.parse(await readFile(this.statePath, 'utf8'));
      } catch {
        this.state = {};
      }
      this.state.items ??= {};
      this.state.lastSnapshot ??= 0;
    }
    return this.state;
  }

  // items: iterable of [itemId, { min, market, qty, auctions }] covering the whole auction house.
  // Snapshots older than the newest one already archived are skipped.
  add(snapshotSec, items) {
    return this.serial(async () => {
      const st = await this.loadState();
      if (snapshotSec <= st.lastSnapshot) return 0;
      st.lastSnapshot = snapshotSec;
      const day = localDay(snapshotSec);
      const lines = [];
      const seen = new Set();

      for (const [rawId, s] of items) {
        const id = String(rawId);
        seen.add(id);
        const prev = st.items[id];
        const save = !prev || prev.day !== day || prev.qty === 0 ||
          moved(s.min, prev.min, this.minChangePct) ||
          moved(s.market, prev.market, this.minChangePct) ||
          moved(s.qty, prev.qty, this.qtyChangePct);
        if (save) {
          lines.push(`${snapshotSec},${id},${s.min},${s.market},${s.qty},${s.auctions}`);
          st.items[id] = { min: s.min, market: s.market, qty: s.qty, day };
        }
      }
      // items that were listed before and aren't any more
      for (const [id, prev] of Object.entries(st.items)) {
        if (!seen.has(id) && prev.qty !== 0) {
          lines.push(`${snapshotSec},${id},,,0,0`);
          st.items[id] = { ...prev, qty: 0, day };
        }
      }

      await mkdir(this.dir, { recursive: true });
      const file = path.join(this.dir, `${day}.csv`);
      if (!existsSync(file)) await writeFile(file, HEADER);
      if (lines.length) await appendFile(file, lines.join('\n') + '\n');
      const tmp = this.statePath + '.tmp';
      await writeFile(tmp, JSON.stringify(st));
      await rename(tmp, this.statePath);
      await this.compressOld();
      return lines.length;
    });
  }

  async files() {
    const names = await readdir(this.dir).catch(() => []);
    const out = [];
    for (const name of names) {
      const m = FILE_RE.exec(name);
      if (m) out.push({ day: m[1], gz: Boolean(m[2]), file: path.join(this.dir, name) });
    }
    return out.sort((a, b) => a.day.localeCompare(b.day));
  }

  async compressOld() {
    const cutoff = localDay(Date.now() / 1000 - this.compressAfterDays * 86400);
    for (const f of await this.files()) {
      if (f.gz || f.day >= cutoff) continue;
      let data = await readFile(f.file);
      const gzFile = f.file + '.gz';
      if (existsSync(gzFile)) {
        // a compressed copy already exists for this day: keep both, minus the second header
        const old = gunzipSync(await readFile(gzFile));
        data = Buffer.concat([old, data.subarray(data.indexOf(10) + 1)]);
      }
      await writeFile(gzFile + '.tmp', gzipSync(data));
      await rename(gzFile + '.tmp', gzFile);
      await unlink(f.file);
    }
  }

  async info() {
    const files = await this.files();
    let bytes = 0;
    for (const f of files) bytes += (await stat(f.file)).size;
    return { days: files.length, bytes, first: files[0]?.day ?? null, last: files.at(-1)?.day ?? null };
  }

  async readText(f) {
    const data = await readFile(f.file);
    return (f.gz ? gunzipSync(data) : data).toString('utf8');
  }

  // Rows between two local dates (inclusive), optionally only some item IDs and a price range
  // (on the cheapest price). Calls onRow(row) for each match, oldest first.
  async scan({ from, to, ids, minPrice, maxPrice }, onRow) {
    const idSet = ids ? new Set(ids.map(String)) : null;
    for (const f of await this.files()) {
      if ((from && f.day < from) || (to && f.day > to)) continue;
      const text = await this.readText(f);
      if (text == null) continue;
      let start = text.indexOf('\n') + 1; // skip header
      while (start < text.length) {
        let end = text.indexOf('\n', start);
        if (end < 0) end = text.length;
        const line = text.slice(start, end);
        start = end + 1;
        if (!line) continue;
        const c1 = line.indexOf(',');
        const c2 = line.indexOf(',', c1 + 1);
        const id = line.slice(c1 + 1, c2);
        if (idSet && !idSet.has(id)) continue;
        const [t, , min, market, qty, auctions] = line.split(',');
        const row = {
          t: Number(t), id: Number(id),
          min: min === '' ? null : Number(min), market: market === '' ? null : Number(market),
          qty: Number(qty), auctions: Number(auctions),
        };
        if (minPrice != null && (row.min == null || row.min < minPrice)) continue;
        if (maxPrice != null && (row.min == null || row.min > maxPrice)) continue;
        onRow(row);
      }
    }
  }
}

// Read-only archive kept in a GitHub repository (filled by the GitHub Actions workflow).
// Files are fetched when a search needs them and kept in memory, so nothing is stored on disk.
export class RemoteArchive extends Archive {
  constructor(repo, branch = 'main') {
    super(null);
    this.repo = repo;
    this.branch = branch;
    this.cache = new Map();   // day file name -> { text, at }
    this.listing = null;      // { at, files }
  }

  raw(file) {
    return `https://raw.githubusercontent.com/${this.repo}/${this.branch}/${file}`;
  }

  add() { return Promise.resolve(0); } // the workflow writes the archive, not this PC

  async files() {
    // GitHub's API allows 60 requests an hour without signing in, so the listing is cached.
    if (this.listing && Date.now() - this.listing.at < 10 * 60_000) return this.listing.files;
    const res = await fetch(`https://api.github.com/repos/${this.repo}/contents/archive?ref=${this.branch}`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'foreverah-dashboard' },
    });
    if (!res.ok) {
      if (this.listing) return this.listing.files;
      if (res.status === 404) return [];
      throw new Error(`GitHub answered ${res.status} when listing the archive`);
    }
    const out = [];
    for (const entry of await res.json()) {
      const m = FILE_RE.exec(entry.name);
      if (m) out.push({ day: m[1], gz: Boolean(m[2]), file: `archive/${entry.name}`, size: entry.size });
    }
    out.sort((a, b) => a.day.localeCompare(b.day));
    this.listing = { at: Date.now(), files: out };
    return out;
  }

  async readText(f) {
    const today = localDay(Date.now() / 1000);
    const hit = this.cache.get(f.file);
    // past days never change; today's file is refreshed every 10 minutes
    if (hit && (f.day < today || Date.now() - hit.at < 10 * 60_000)) return hit.text;
    const res = await fetch(this.raw(f.file));
    if (!res.ok) return hit?.text ?? null;
    const data = Buffer.from(await res.arrayBuffer());
    const text = (f.gz ? gunzipSync(data) : data).toString('utf8');
    this.cache.set(f.file, { text, at: Date.now() });
    if (this.cache.size > 120) this.cache.delete(this.cache.keys().next().value);
    return text;
  }

  async info() {
    const files = await this.files();
    return {
      days: files.length,
      bytes: files.reduce((n, f) => n + (f.size || 0), 0),
      first: files[0]?.day ?? null,
      last: files.at(-1)?.day ?? null,
      remote: this.repo,
    };
  }
}
