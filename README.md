# ForeverAH: auction prices for WoW: Forever

## Collected on GitHub

This repository collects prices by itself. The **Collect prices** workflow (`.github/workflows/collect.yml`) runs every hour on GitHub Actions, downloads the auction house from Blizzard's API, and commits:

- `data/latest.json`: the latest prices (read by the dashboard in GitHub mode),
- `data/Data.lua`: the same prices for the addon,
- `archive/`: the change-only price archive (see "Price archive" below),
- `history.json`: daily averages used for the 14-day average.

It needs two repository secrets (Settings → Secrets and variables → Actions): `BLIZZARD_CLIENT_ID` and `BLIZZARD_CLIENT_SECRET`. The house, region and ruleset are set in the workflow file.

To use it from your PC without downloading from Blizzard there, add `"github": "Kyzhoe/foreverah"` to `config.json` and run `node server.mjs`. The dashboard then pulls the latest prices from this repository every hour, keeps the addon's `Data.lua` up to date, and reads the archive from GitHub when you search the History tab, so nothing builds up on your PC.


Two parts:

- **fetch-prices.mjs** runs on your PC. It downloads your auction house from Blizzard's API and writes the prices into the addon's `Data.lua`.
- **ForeverAH** (the addon folder) shows those prices on item tooltips and adds an auction window with **Deals** and **Sell** tabs.

## In game

- The ForeverAH window opens next to the auction house. `/fah` opens or closes it anywhere, and there's a ForeverAH button under the auction house window.
- **Deals** lists items whose cheapest listing is at most a set % of their average price, with at least a set profit per unit after the 5% AH cut. It works from the downloaded data, so it's as fresh as your last download. Click a deal to check the live auction house, then buy:
  - Commodities (stackable goods): click a row to fill in "everything up to this price", or type a quantity, then click **Buy**, then **Confirm** once the game quotes the total.
  - Items: select a listing and click **Buy selected**.
- **Sell** lists what's in your bags. Pick something to see its live listings; the price is set 1c under the cheapest listing that isn't yours. Pick a quantity and duration, then **Post**. Items (not commodities) post one at a time.
- `/fah status` shows the data age, `/fah auto` toggles opening with the AH, `/fah reset` resets the window position, `/fah <item link>` prints a price.
- Buying and posting always need your click. The addon never buys or posts on its own.

Forever's auction API isn't documented by Blizzard. It could change without warning.

## Setup

1. **Install Node.js 18 or newer** from nodejs.org. Check it with `node --version`.
2. **Install the addon.** Copy the `ForeverAH` folder into your Forever `Interface\AddOns` folder. That's inside your World of Warcraft install, next to `_retail_` and `_classic_`. Check the exact name of the Forever folder there.
3. **Create your config.** Put `fetch-prices.mjs` and `config.example.json` in a folder of their own, for example `Documents\forever-ah`. Copy `config.example.json` to `config.json` and fill in:
   - `clientId` and `clientSecret` from develop.battle.net
   - `addonDataFile`: the full path to `...\Interface\AddOns\ForeverAH\Data.lua`. Use forward slashes, or double the backslashes.
   - `region` is already `us` and `rulesetId` is already `1` (PvP).
4. **See the houses.** Open a terminal in that folder and run:
   ```
   node fetch-prices.mjs list
   ```
5. **Find out which house is yours.** In game, post one cheap single item at an odd price, for example 1g 23s 45c. Wait an hour or so for Blizzard's next refresh, then run:
   ```
   node fetch-prices.mjs find 1g23s45c
   ```
   Put the house ID it reports into `config.json`, for example `"houseIds": [113]`.
6. **Download prices:**
   ```
   node fetch-prices.mjs
   ```
   Then type `/reload` in game and hover over an item.

## Desktop dashboard

```
node server.mjs
```

This starts a small server on your PC and opens the dashboard in your browser at http://localhost:8787. Leave the terminal open while you play: it downloads new prices every `intervalMinutes`, so you don't need `watch` as well.

- **Browse**: every item in your house, searchable and sortable.
- **Deals** and **Vendor**: the same lists as the addon's tabs.
- **Watchlist**: click the star next to any item.
- **History**: search the price archive by item name or ID, date range and price range, and export the results as a CSV for Excel or Google Sheets.
- Click an item for its details and a price chart. The chart needs two days of history, and builds up the longer the server runs.
- **Notifications**: turn them on, and your browser pops up a notice when new deals or vendor flips appear after an update. The dashboard page has to stay open for this.

Item names and vendor prices come from the addon, because Blizzard's web API is missing many of them. The addon saves them when you log out or `/reload`. Until it has done that once, the dashboard shows item IDs.

The server only listens on this PC. Use `node server.mjs --no-open` to start it without opening the browser, and set `"port"` in `config.json` if 8787 is taken.

## Price archive

Every download and every in-game scan is added to the `archive` folder. To keep it small, an item only gets a new row when something changes:

- its cheapest or market price moves by at least `archiveMinChangePct` % (5% by default) since its last saved row,
- the amount listed moves by at least `archiveQtyChangePct` % (25% by default),
- it disappears from the auction house (a row with no prices and 0 listed) or comes back,
- or it's the item's first row of the day.

So between two saved rows, the price stayed within those limits. Expect about 0.5 MB a day; days older than a week are compressed to `.csv.gz` automatically, to roughly a third of that. Each day is a plain CSV (`time,item,min,market,qty,auctions`, time in Unix seconds, prices in copper), so you can also open the files directly. The History tab's **Export CSV** gives friendlier columns with dates and item names.

Set `"archive": false` in `config.json` to turn it off. Lower `archiveMinChangePct` to keep more detail, or raise it to keep less.

## Keeping it updated

- `node fetch-prices.mjs watch` updates every `intervalMinutes` (60 by default) for as long as the window stays open.
- Or use Windows Task Scheduler to run `node fetch-prices.mjs` every hour.

The game only reads `Data.lua` at login and on `/reload`.

## How the prices are worked out

- **Min buyout:** the cheapest per-unit price listed.
- **Market:** the average per-unit price of the cheapest `marketPercent`% of units listed (20% by default). This stops one cheap listing from setting the price.
- **Average:** the average of the daily market values over the last 14 days, kept in `history.json`. It starts with one day and fills in as you keep downloading.
- These are asking prices from current listings, not completed sales.
- For regular (non-commodity) auctions, the script assumes `buyout` is the price of the whole stack, as in Blizzard's Classic API. That's unconfirmed for Forever, which is why the find test uses a single item.

## Keep these private

`config.json` holds your secret. `state.json` holds your access token. Don't share them or upload them anywhere. The `cache` folder is just the last download and is safe to delete. Deleting `history.json` resets the 14-day averages.
