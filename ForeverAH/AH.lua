-- ForeverAH auction house wrapper around C_AuctionHouse (Forever uses the modern AH).
-- Searching is free to call any time the AH is open. Buying and posting must come
-- from a click, so the UI calls BuyItem / StartCommodityBuy / ConfirmCommodityBuy /
-- Post straight from button handlers.
--
-- Fires: AH_OPENED, AH_CLOSED, RESULTS(search), PURCHASE_PRICE(purchase),
--        PURCHASE_DONE(ok), POSTED

local _, ns = ...
local CAH = C_AuctionHouse
local AH = { isOpen = false }
ns.AH = AH

local priceSort
local function PriceSort()
  if not priceSort and Enum and Enum.AuctionHouseSortOrder then
    priceSort = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
  end
  return priceSort or {}
end

function AH:Available()
  if not CAH then return false, "This client has no C_AuctionHouse." end
  if not self.isOpen then return false, "Open the auction house to see live listings." end
  return true
end

---------------------------------------------------------------------------
-- Searching
---------------------------------------------------------------------------
-- A search goes: stage 1, search the item key directly. If an item (not a
-- commodity) comes back empty, stage 2 browses by name to find the exact item
-- key the server uses (random suffixes etc.), then stage 3 searches that key.

local function Finish(s, results)
  s.results = results
  s.pending = false
  ns.Fire("RESULTS", s)
end

-- key is optional: an item key from a browse result, used as-is.
function AH:Search(itemID, commodity, key)
  local ok, err = self:Available()
  if not ok then return false, err end
  self.search = { itemID = itemID, commodity = commodity, results = {}, pending = true, stage = 1, key = key, givenKey = key }
  self:SendSearch()
  return true
end

function AH:Research()
  local s = self.search
  if s and self.isOpen then self:Search(s.itemID, s.commodity, s.givenKey) end
end

function AH:SendSearch()
  local s = self.search
  if not s then return end
  if CAH.IsThrottledMessageSystemReady and not CAH.IsThrottledMessageSystemReady() then
    s.waiting = true -- sent again on AUCTION_HOUSE_THROTTLED_SYSTEM_READY
    return
  end
  s.waiting = false
  local ok, err = pcall(function()
    if s.stage == 2 then
      local name = ns.GetItemInfo(s.itemID)
      if not name then error("item name not loaded yet") end
      CAH.SendBrowseQuery({ searchString = name, sorts = PriceSort(), filters = {}, itemClassFilters = {} })
    else
      local key = s.key
      if not key then
        local level = 0
        if not s.commodity then level = select(4, ns.GetItemInfo(s.itemID)) or 0 end
        key = CAH.MakeItemKey(s.itemID, level)
        s.key = key
      end
      CAH.SendSearchQuery(key, PriceSort(), true)
    end
  end)
  if not ok then
    ns.Print("search failed: " .. tostring(err))
    Finish(s, {})
  end
end

local function OnCommodityResults(itemID)
  local s = AH.search
  if not s or s.itemID ~= itemID then return end
  local list = {}
  local n = CAH.GetNumCommoditySearchResults(itemID) or 0
  for i = 1, n do
    local r = CAH.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice then
      local q = r.quantity or 1
      list[#list + 1] = {
        auctionID = r.auctionID, unit = r.unitPrice, qty = q, total = r.unitPrice * q,
        mine = (r.numOwnerItems or 0) > 0 or r.containsOwnerItem or false, commodity = true,
      }
    end
  end
  s.commodity = true
  Finish(s, list)
end

local function OnItemResults(itemKey)
  local s = AH.search
  if not s or not itemKey or itemKey.itemID ~= s.itemID then return end
  local list = {}
  local n = CAH.GetNumItemSearchResults(itemKey) or 0
  for i = 1, n do
    local r = CAH.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount then -- bid-only auctions are skipped
      local q = r.quantity or 1
      list[#list + 1] = {
        auctionID = r.auctionID, unit = r.buyoutAmount / q, qty = q, total = r.buyoutAmount,
        mine = r.containsOwnerItem or false, commodity = false, link = r.itemLink,
      }
    end
  end
  s.commodity = false
  if #list == 0 and s.stage == 1 then
    s.stage = 2
    AH:SendSearch()
    return
  end
  Finish(s, list)
end

-- Live name search (Search tab). Results arrive as BROWSE(text, results).
function AH:Browse(text)
  local ok, err = self:Available()
  if not ok then return false, err end
  if CAH.IsThrottledMessageSystemReady and not CAH.IsThrottledMessageSystemReady() then
    return false, "The auction house is busy, try again in a moment."
  end
  self.browsing = text
  local sent, sendErr = pcall(CAH.SendBrowseQuery,
    { searchString = text, sorts = PriceSort(), filters = {}, itemClassFilters = {} })
  if not sent then
    self.browsing = nil
    return false, tostring(sendErr)
  end
  return true
end

local function OnBrowseResults()
  local s = AH.search
  if AH.browsing and not (s and s.stage == 2) then
    local text = AH.browsing
    AH.browsing = nil
    ns.Fire("BROWSE", text, CAH.GetBrowseResults() or {})
    return
  end
  if not s or s.stage ~= 2 then return end
  for _, r in ipairs(CAH.GetBrowseResults() or {}) do
    if r.itemKey and r.itemKey.itemID == s.itemID and (r.totalQuantity or 0) > 0 then
      s.stage = 3
      s.key = r.itemKey
      AH:SendSearch()
      return
    end
  end
  Finish(s, {})
end

---------------------------------------------------------------------------
-- Buying (call only from a click)
---------------------------------------------------------------------------

function AH:BuyItem(row)
  if not self:Available() then return end
  self.buying = row
  CAH.PlaceBid(row.auctionID, row.total)
end

function AH:StartCommodityBuy(itemID, qty)
  if not self:Available() then return end
  self.purchase = { itemID = itemID, qty = qty }
  CAH.StartCommoditiesPurchase(itemID, qty)
end

function AH:ConfirmCommodityBuy()
  local p = self.purchase
  if p and p.total then CAH.ConfirmCommoditiesPurchase(p.itemID, p.qty) end
end

function AH:CancelCommodityBuy()
  if self.purchase then
    self.purchase = nil
    if CAH and CAH.CancelCommoditiesPurchase then pcall(CAH.CancelCommoditiesPurchase) end
  end
end

local function PurchaseDone(ok)
  AH.purchase, AH.buying = nil, nil
  ns.Fire("PURCHASE_DONE", ok)
  AH:Research()
end

---------------------------------------------------------------------------
-- Posting (call only from a click)
---------------------------------------------------------------------------

-- unitPrice is per item. Items (non-commodities) are posted one at a time.
function AH:Post(loc, commodity, duration, qty, unitPrice)
  local ok, err = self:Available()
  if not ok then return false, err end
  if commodity then
    CAH.PostCommodity(loc, duration, qty, unitPrice)
  else
    CAH.PostItem(loc, duration, 1, nil, unitPrice)
  end
  return true
end

function AH:Deposit(loc, itemID, commodity, duration, qty)
  if not CAH then return nil end
  local ok, v
  if commodity then
    ok, v = pcall(CAH.CalculateCommodityDeposit, itemID, duration, qty)
  else
    ok, v = pcall(CAH.CalculateItemDeposit, loc, duration, 1)
  end
  if ok then return v end
end

-- true / false / nil (unknown)
function AH:IsCommodity(loc, itemID)
  local p = ns.GetPrice(itemID)
  if p and p.commodity ~= nil then return p.commodity end
  if CAH and CAH.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
    local ok, status = pcall(CAH.GetItemCommodityStatus, loc)
    if ok then
      if status == Enum.ItemCommodityStatus.Commodity then return true end
      if status == Enum.ItemCommodityStatus.Item then return false end
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {
  AUCTION_HOUSE_SHOW = function()
    AH.isOpen = true
    ns.Fire("AH_OPENED")
  end,
  AUCTION_HOUSE_CLOSED = function()
    AH.isOpen = false
    AH:CancelCommodityBuy()
    AH.search = nil
    ns.Fire("AH_CLOSED")
  end,
  COMMODITY_SEARCH_RESULTS_UPDATED = OnCommodityResults,
  ITEM_SEARCH_RESULTS_UPDATED = OnItemResults,
  AUCTION_HOUSE_BROWSE_RESULTS_UPDATED = OnBrowseResults,
  AUCTION_HOUSE_THROTTLED_SYSTEM_READY = function()
    if AH.search and AH.search.waiting then AH:SendSearch() end
  end,
  COMMODITY_PRICE_UPDATED = function(unitPrice, totalPrice)
    local p = AH.purchase
    if not p then return end
    p.unit, p.total = unitPrice, totalPrice
    ns.Fire("PURCHASE_PRICE", p)
  end,
  COMMODITY_PRICE_UNAVAILABLE = function() PurchaseDone(false) end,
  COMMODITY_PURCHASE_SUCCEEDED = function() PurchaseDone(true) end,
  COMMODITY_PURCHASE_FAILED = function() PurchaseDone(false) end,
  AUCTION_HOUSE_PURCHASE_COMPLETED = function() if AH.buying then PurchaseDone(true) end end,
  BID_ADDED = function() if AH.buying then PurchaseDone(true) end end,
  AUCTION_HOUSE_AUCTION_CREATED = function()
    ns.Fire("POSTED")
    C_Timer.After(0.5, function() AH:Research() end)
  end,
}

local frame = CreateFrame("Frame")
for event in pairs(handlers) do
  pcall(frame.RegisterEvent, frame, event) -- events this client doesn't have are skipped
end
frame:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
