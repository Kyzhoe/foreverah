-- ForeverAH full scan: reads the whole auction house in one request (C_AuctionHouse.ReplicateItems).
-- Blizzard allows this about once every 15 minutes. The results replace the downloaded prices
-- until a newer download arrives, and are saved for the desktop dashboard.
--
-- Fires: SCAN_PROGRESS(fraction), SCAN_DONE(ok)

local _, ns = ...
local CAH = C_AuctionHouse
local Scan = { running = false, progress = 0 }
ns.Scan = Scan

local COOLDOWN = 15 * 60   -- seconds between scans
local TIMEOUT = 90         -- give up waiting for the server after this
local CHUNK = 4000         -- auctions read per frame, so the game doesn't freeze
local MARKET_PCT = 0.20    -- market = average of the cheapest 20% of units (same as fetch-prices.mjs)

function Scan:Cooldown()
  local last = ns.db and ns.db.lastScanStart or 0
  local left = last + COOLDOWN - time()
  return left > 0 and left or 0
end

function Scan:CanScan()
  if self.running then return false, "A scan is already running." end
  if not (CAH and CAH.ReplicateItems and CAH.GetNumReplicateItems) then
    return false, "Full scans aren't available on this client."
  end
  if not ns.AH.isOpen then return false, "Open the auction house to scan." end
  local cd = self:Cooldown()
  if cd > 0 then return false, format("Blizzard allows one full scan every 15 minutes. Next in %d:%02d.", floor(cd / 60), cd % 60) end
  return true
end

function Scan:Fail(msg)
  self.running, self.waiting = false, false
  if self.timer then self.timer:Cancel() end
  if self.ticker then self.ticker:Cancel() end
  ns.Print("|cffff6666scan failed:|r " .. msg)
  ns.Fire("SCAN_DONE", false)
end

function Scan:Start()
  local ok, why = self:CanScan()
  if not ok then
    ns.Print(why)
    return
  end
  self.running, self.waiting, self.progress = true, true, 0
  ns.db.lastScanStart = time()
  ns.Print("scanning the auction house...")
  ns.Fire("SCAN_PROGRESS", 0)
  self.timer = C_Timer.NewTimer(TIMEOUT, function()
    if self.waiting then
      self:Fail("the auction house didn't answer. The 15-minute limit may still be running from an earlier scan; try again later.")
    end
  end)
  local sent, err = pcall(CAH.ReplicateItems)
  if not sent then self:Fail(tostring(err)) end
end

-- Market value and minimum per item from a list of { unitPrice, count }.
local function Stats(list)
  table.sort(list, function(a, b) return a[1] < b[1] end)
  local total = 0
  for _, e in ipairs(list) do total = total + e[2] end
  local target = math.max(1, math.ceil(total * MARKET_PCT))
  local taken, sum = 0, 0
  for _, e in ipairs(list) do
    if taken >= target then break end
    local take = math.min(e[2], target - taken)
    sum = sum + take * e[1]
    taken = taken + take
  end
  return floor(list[1][1] + 0.5), floor(sum / taken + 0.5), total, #list
end

function Scan:Finish(byItem, numAuctions)
  local results, count = {}, 0
  for id, list in pairs(byItem) do
    local min, market, qty, auctions = Stats(list)
    results[id] = { min, market, qty, auctions }
    count = count + 1
  end
  ns.db.scan = { time = time(), items = results }
  ns.ApplyScan(ns.db.scan)
  self.running = false
  self.progress = 1
  ns.Print(format("scan done: %d auctions, %d items. Prices updated.", numAuctions, count))
  ns.Fire("SCAN_DONE", true)
end

function Scan:OnReplicate()
  if not self.waiting then return end
  self.waiting = false
  if self.timer then self.timer:Cancel() end

  local n = CAH.GetNumReplicateItems() or 0
  if n == 0 then
    self:Fail("the auction house sent back no auctions.")
    return
  end
  local byItem, i = {}, 0
  self.ticker = C_Timer.NewTicker(0.01, function(t)
    local stop = math.min(i + CHUNK, n)
    for index = i, stop - 1 do -- replicate indexes start at 0
      local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = CAH.GetReplicateItemInfo(index)
      if itemID and buyout and buyout > 0 then
        count = (count and count > 0) and count or 1
        local list = byItem[itemID]
        if not list then
          list = {}
          byItem[itemID] = list
        end
        list[#list + 1] = { buyout / count, count } -- buyout is for the whole stack
      end
    end
    i = stop
    self.progress = i / n
    ns.Fire("SCAN_PROGRESS", self.progress)
    if i >= n then
      t:Cancel()
      self.ticker = nil
      local ok, err = pcall(self.Finish, self, byItem, n)
      if not ok then self:Fail(tostring(err)) end
    end
  end)
end

local frame = CreateFrame("Frame")
pcall(frame.RegisterEvent, frame, "REPLICATE_ITEM_LIST_UPDATE")
pcall(frame.RegisterEvent, frame, "AUCTION_HOUSE_CLOSED")
frame:SetScript("OnEvent", function(_, event)
  if event == "REPLICATE_ITEM_LIST_UPDATE" then
    Scan:OnReplicate()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if Scan.waiting then
      Scan:Fail("the auction house was closed before the scan arrived.")
    elseif Scan.ticker then
      Scan:Fail("the auction house was closed while reading the scan. Stay at the AH until it says done.")
    end
  end
end)
