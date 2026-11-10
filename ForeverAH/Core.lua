-- ForeverAH core: price data, helpers, tooltips, slash commands, saved settings.

local ADDON, ns = ...

local Data = ForeverAH_Data or {}
Data.updated = Data.updated or 0
Data.houses = Data.houses or {}
Data.items = Data.items or {}
ns.Data = Data

ns.PREFIX = "|cff59c7faForeverAH|r: "
function ns.Print(msg) print(ns.PREFIX .. msg) end

local GetItemInfo = GetItemInfo or (C_Item and C_Item.GetItemInfo)
ns.GetItemInfo = GetItemInfo

local DEFAULTS = {
  tab = 1,
  autoOpen = true,
  dealPct = 70,          -- deals: cheapest listing at most this % of the 14-day average
  dealMinProfit = 1000,  -- deals: at least this much profit per unit, in copper
  duration = 2,          -- posting duration index (1 short, 2 medium, 3 long)
}

---------------------------------------------------------------------------
-- Tiny event/callback hub shared by every file
---------------------------------------------------------------------------

local callbacks = {}
function ns.On(name, fn)
  callbacks[name] = callbacks[name] or {}
  table.insert(callbacks[name], fn)
end
function ns.Fire(name, ...)
  for _, fn in ipairs(callbacks[name] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
  end
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------

function ns.Money(copper)
  if not copper then return "-" end
  copper = floor(copper + 0.5)
  if GetCoinTextureString then return GetCoinTextureString(copper) end
  return format("%dg %ds %dc", floor(copper / 10000), floor((copper % 10000) / 100), copper % 100)
end

-- "1g23s45c" style, for edit boxes
function ns.MoneyInput(copper)
  if not copper then return "" end
  copper = floor(copper + 0.5)
  local g, s, c = floor(copper / 10000), floor((copper % 10000) / 100), copper % 100
  local out = ""
  if g > 0 then out = out .. g .. "g" end
  if s > 0 then out = out .. s .. "s" end
  if c > 0 or out == "" then out = out .. c .. "c" end
  return out
end

-- Accepts "12345" (copper) or "1g23s45c", "1g 23s", "45c". Returns nil if it can't parse.
function ns.ParseMoney(text)
  if not text then return nil end
  local t = text:lower():gsub("%s+", "")
  if t == "" then return nil end
  if t:match("^%d+$") then return tonumber(t) end
  local rest = t:gsub("%d+[gsc]", "")
  if rest ~= "" then return nil end
  local g = tonumber(t:match("(%d+)g")) or 0
  local s = tonumber(t:match("(%d+)s")) or 0
  local c = tonumber(t:match("(%d+)c")) or 0
  return g * 10000 + s * 100 + c
end

function ns.Age(ts)
  if not ts or ts == 0 then return "never" end
  local minutes = floor((time() - ts) / 60)
  if minutes < 1 then return "just now" end
  if minutes < 60 then return minutes .. "m ago" end
  local hours = floor(minutes / 60)
  if hours < 48 then return hours .. "h ago" end
  return floor(hours / 24) .. "d ago"
end

---------------------------------------------------------------------------
-- Prices and items
---------------------------------------------------------------------------

-- Row layout written by fetch-prices.mjs:
-- { minBuyout, market, quantity, auctions, avg14, daysOfHistory, isCommodity }
function ns.GetPrice(itemID)
  local row = itemID and Data.items[itemID]
  if not row then return nil end
  local commodity
  if row[7] == 1 then commodity = true elseif row[7] == 0 then commodity = false end
  return {
    minBuyout = row[1],
    market = row[2],
    quantity = row[3],
    auctions = row[4],
    avg = row[5] or row[2],
    days = row[6] or 1,
    commodity = commodity,
  }
end

local requested = {} -- item IDs already asked for this session
local IsCachedByID = C_Item and C_Item.IsItemDataCachedByID

function ns.IsCached(id)
  if IsCachedByID then return IsCachedByID(id) and true or false end
  return GetItemInfo(id) ~= nil
end

-- name, colorPrefix, icon, vendorPrice, loaded, link
function ns.ItemInfo(itemID)
  local name, link, quality, _, _, _, _, _, _, icon, sellPrice
  if ns.IsCached(itemID) then
    name, link, quality, _, _, _, _, _, _, icon, sellPrice = GetItemInfo(itemID)
  end
  if not name then
    if not requested[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
      requested[itemID] = true
      C_Item.RequestLoadItemDataByID(itemID)
    end
    local fallbackIcon = (GetItemIcon and GetItemIcon(itemID)) or 134400
    return "Item #" .. itemID, "|cff9d9d9d", fallbackIcon, nil, false, nil
  end
  local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
  local color = (q and q.hex) or "|cffffffff"
  return name, color, icon, sellPrice, true, link
end

-- A full in-game scan (Scan.lua) replaces the downloaded prices if it's newer.
-- scan = { time, items = { [itemID] = { min, market, quantity, auctions } } }
-- The averages and commodity flags from the download are kept.
function ns.ApplyScan(scan)
  if not scan or not scan.items or (scan.time or 0) <= Data.updated then return false end
  local old, new = Data.items, {}
  for id, r in pairs(scan.items) do
    local o = old[id]
    new[id] = { r[1], r[2], r[3], r[4], o and o[5] or r[2], o and o[6] or 1, o and o[7] }
  end
  Data.items = new
  Data.updated = scan.time
  Data.source = "scan"
  ns.Fire("DATA_CHANGED")
  return true
end

-- The data only has item IDs; names and vendor prices come from the game's item
-- cache. RequestAllItemInfo asks for every missing item in small batches; they
-- arrive over a few seconds and fire ITEM_INFO.
--
-- Checking with GetItemInfo asks the server for any item that isn't cached, and every
-- answer fires another event, so counting and filtering use ns.IsCached instead, which
-- only looks. Each item is requested once per session. ns.itemInfoLoading is true from
-- the first request until answers stop arriving; then ITEM_INFO_DONE fires. Items still
-- missing after that are ones this client doesn't know.
local itemLoader
ns.itemInfoLoading = false

function ns.CountItemInfo()
  local total, known = 0, 0
  for id in pairs(Data.items) do
    total = total + 1
    if ns.IsCached(id) then known = known + 1 end
  end
  return known, total
end

local quietTimer
local function ScheduleDone()
  -- loading counts as finished once no new item info has arrived for 4 seconds
  if quietTimer then quietTimer:Cancel() end
  quietTimer = C_Timer.NewTimer(4, function()
    quietTimer = nil
    if itemLoader then return end
    ns.itemInfoLoading = false
    ns.Fire("ITEM_INFO_DONE")
  end)
end
ns.On("ITEM_INFO", function() if ns.itemInfoLoading then ScheduleDone() end end)

function ns.RequestAllItemInfo(onProgress)
  if itemLoader or not (C_Item and C_Item.RequestLoadItemDataByID) then return end
  local missing = {}
  for id in pairs(Data.items) do
    if not requested[id] and not ns.IsCached(id) then missing[#missing + 1] = id end
  end
  if #missing == 0 then return end
  ns.itemInfoLoading = true
  local i = 0
  itemLoader = C_Timer.NewTicker(0.05, function(t)
    for _ = 1, 100 do
      i = i + 1
      local id = missing[i]
      if not id then
        t:Cancel()
        itemLoader = nil
        ScheduleDone()
        break
      end
      requested[id] = true
      C_Item.RequestLoadItemDataByID(id)
    end
    if onProgress then onProgress() end
  end)
end

-- Public API so other addons can read prices.
ForeverAH = {
  GetPrice = ns.GetPrice,
  GetUpdated = function() return Data.updated end,
}

---------------------------------------------------------------------------
-- Tooltips
---------------------------------------------------------------------------

local function AddLines(tooltip, itemID)
  if not itemID then return end
  local p = ns.GetPrice(itemID)
  if p then
    tooltip:AddDoubleLine("AH market", ns.Money(p.market), 1, 0.82, 0, 1, 1, 1)
    if p.days > 1 then
      tooltip:AddDoubleLine(format("AH %d-day avg", p.days), ns.Money(p.avg), 1, 0.82, 0, 1, 1, 1)
    end
    tooltip:AddDoubleLine("AH min buyout", ns.Money(p.minBuyout), 1, 0.82, 0, 1, 1, 1)
    tooltip:AddDoubleLine("AH listed", p.quantity .. " in " .. p.auctions .. " auctions", 1, 0.82, 0, 0.7, 0.7, 0.7)
  elseif Data.updated > 0 then
    tooltip:AddLine("AH: none listed", 0.6, 0.6, 0.6)
  end
end

local tooltipMethod = "none"
local function HookTooltips()
  if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      if tooltip == GameTooltip or tooltip == ItemRefTooltip then
        AddLines(tooltip, data and data.id)
      end
    end)
    tooltipMethod = "TooltipDataProcessor"
  else
    local function OnSetItem(tooltip)
      local _, link = tooltip:GetItem()
      AddLines(tooltip, link and tonumber(link:match("item:(%d+)")))
    end
    GameTooltip:HookScript("OnTooltipSetItem", OnSetItem)
    ItemRefTooltip:HookScript("OnTooltipSetItem", OnSetItem)
    tooltipMethod = "OnTooltipSetItem"
  end
end

---------------------------------------------------------------------------
-- Status and slash commands
---------------------------------------------------------------------------

local function CountItems()
  local n = 0
  for _ in pairs(Data.items) do n = n + 1 end
  return n
end

function ns.Status()
  if Data.updated == 0 then
    ns.Print("no price data yet. Run fetch-prices.mjs, then /reload.")
  else
    ns.Print(format("%d items, %s %s (house %s).", CountItems(),
      Data.source == "scan" and "scanned" or "data from", ns.Age(Data.updated), table.concat(Data.houses, ", ")))
  end
end

SLASH_FOREVERAH1 = "/fah"
SlashCmdList.FOREVERAH = function(msg)
  msg = msg or ""
  local cmd = msg:lower():match("^%s*(%S*)")
  if cmd == "" then
    if ns.UI then ns.UI:Toggle() end
    return
  elseif cmd == "status" then
    return ns.Status()
  elseif cmd == "reset" then
    ns.db.pos = nil
    if ns.UI then ns.UI:RestorePosition() end
    return ns.Print("window position reset.")
  elseif cmd == "auto" then
    ns.db.autoOpen = not ns.db.autoOpen
    return ns.Print("open with the auction house: " .. (ns.db.autoOpen and "on" or "off"))
  end
  local id = tonumber(msg:match("item:(%d+)") or msg:match("^%s*(%d+)%s*$"))
  if not id then
    ns.Print("/fah  open or close the window")
    ns.Print("/fah status  data age and item count")
    ns.Print("/fah auto  toggle opening with the auction house")
    ns.Print("/fah reset  reset the window position")
    ns.Print("/fah <item link or ID>  show a price")
    return
  end
  local p = ns.GetPrice(id)
  if p then
    ns.Print(format("%s (item ID %d)  market %s, avg %s, min %s, %d listed", msg, id, ns.Money(p.market),
      ns.Money(p.avg), ns.Money(p.minBuyout), p.quantity))
  else
    ns.Print(format("%s (item ID %d) has no listings in the data.", msg, id))
  end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

local hookOk, hookErr = pcall(HookTooltips)

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
pcall(f.RegisterEvent, f, "GET_ITEM_INFO_RECEIVED")

local itemInfoPending = false
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    ForeverAHDB = ForeverAHDB or {}
    for k, v in pairs(DEFAULTS) do
      if ForeverAHDB[k] == nil then ForeverAHDB[k] = v end
    end
    ns.db = ForeverAHDB
    ns.ApplyScan(ns.db.scan) -- a scan newer than the last download wins
  elseif event == "PLAYER_LOGIN" then
    ns.Status()
    if not hookOk then
      ns.Print("|cffff4444couldn't hook tooltips:|r " .. tostring(hookErr))
    end
    -- load names/vendor prices in the background so Search, Vendor and the dashboard have them
    C_Timer.After(15, function() ns.RequestAllItemInfo() end)
    if Data.updated > 0 and time() - Data.updated > 3 * 3600 then
      ns.Print("|cffff8800prices are over 3 hours old.|r Is fetch-prices.mjs running?")
    end
  elseif event == "PLAYER_LOGOUT" then
    -- Save names, vendor prices and quality for the desktop dashboard, which can't
    -- get them from Blizzard's web API. Kept across sessions and added to each time.
    -- itemNames[itemID] = { name, vendorPrice, quality }
    local saved = ns.db and ns.db.itemNames or {}
    for id in pairs(Data.items) do
      if ns.IsCached(id) then
        local name, _, quality, _, _, _, _, _, _, _, sell = GetItemInfo(id)
        if name then saved[id] = { name, sell or 0, quality or 1 } end
      end
    end
    if ns.db then ns.db.itemNames = saved end
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    -- Item names arrive one by one; refresh lists at most a few times a second.
    if not itemInfoPending then
      itemInfoPending = true
      C_Timer.After(0.25, function()
        itemInfoPending = false
        ns.Fire("ITEM_INFO")
      end)
    end
  end
end)

ns.tooltipMethod = function() return tooltipMethod end
