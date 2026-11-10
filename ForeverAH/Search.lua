-- ForeverAH Search tab: find items by name in the downloaded data (works anywhere),
-- plus a live name search when the auction house is open.

local _, ns = ...
local S, UI, AH = ns.Style, ns.UI, ns.AH

local MAX_RESULTS = 300

---------------------------------------------------------------------------
-- Item names. The data only has item IDs, so names come from the game's item
-- cache. Missing ones are requested in small batches and arrive over a few seconds.
---------------------------------------------------------------------------

local names = {}     -- itemID -> lowercase name
local total, known = 0, 0

local function NameOf(id)
  local n = names[id]
  if n then return n end
  if not ns.IsCached(id) then return nil end -- don't trigger a server request
  local name = ns.GetItemInfo(id)
  if name then
    n = name:lower()
    names[id] = n
  end
  return n
end

local function CountNames()
  known, total = ns.CountItemInfo()
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function BuildRow(row)
  row.icon = S.Icon(row, 16)
  row.icon:SetPoint("LEFT", 4, 0)
  row.name = S.Text(row, 12)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetWidth(220)
  row.market = S.Text(row, 12, S.c.text, "RIGHT")
  row.market:SetPoint("RIGHT", row, "LEFT", 335, 0)
  row.avg = S.Text(row, 12, S.c.muted, "RIGHT")
  row.avg:SetPoint("RIGHT", row, "LEFT", 430, 0)
  row.low = S.Text(row, 12, S.c.text, "RIGHT")
  row.low:SetPoint("RIGHT", row, "LEFT", 530, 0)
  row.qty = S.Text(row, 12, S.c.muted, "RIGHT")
  row.qty:SetPoint("RIGHT", row, "RIGHT", -8, 0)
  function row:Update(e)
    local name, color, icon = ns.ItemInfo(e.itemID)
    self.icon:SetTexture(icon)
    self.name:SetText(color .. name .. "|r")
    local p = ns.GetPrice(e.itemID)
    self.market:SetText(p and ns.Money(p.market) or "-")
    self.avg:SetText(p and ns.Money(p.avg) or "-")
    if e.liveMin then
      self.low:SetText(ns.Money(e.liveMin))
      self.low:SetTextColor(unpack(S.c.accent))
      self.qty:SetText(e.liveQty or "-")
    else
      self.low:SetText(p and ns.Money(p.minBuyout) or "-")
      self.low:SetTextColor(unpack(S.c.text))
      self.qty:SetText(p and p.quantity or "-")
    end
  end
  function row:OnEnterTip()
    local _, _, _, _, _, link = ns.ItemInfo(self.item.itemID)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if link then GameTooltip:SetHyperlink(link) else GameTooltip:SetText("Item #" .. self.item.itemID) end
    if self.item.liveMin then
      GameTooltip:AddLine("Blue price: live from the auction house", 0.35, 0.78, 0.98)
    end
    GameTooltip:Show()
  end
end

---------------------------------------------------------------------------
-- Tab
---------------------------------------------------------------------------

UI:AddTab("Search", function(page)
  local box = S.Input(page, 260, 24)
  box:SetPoint("TOPLEFT", 0, -2)
  local hint = S.Text(box, 12, S.c.muted)
  hint:SetPoint("LEFT", 7, 0)
  hint:SetText("Search item names...")

  local liveBtn = S.Button(page, "Search AH live", 120, 24)
  liveBtn:SetPoint("LEFT", box, "RIGHT", 8, 0)
  liveBtn.tip = "Ask the auction house directly. Finds items that weren't listed in your last download, and shows current cheapest prices in blue."

  local count = S.Text(page, 11, S.c.muted, "RIGHT")
  count:SetPoint("TOPRIGHT", -2, -9)

  local function Col(text, x, justify)
    local c = S.Text(page, 10, S.c.muted, justify)
    c:SetText(text)
    if justify == "RIGHT" then c:SetPoint("TOPRIGHT", page, "TOPLEFT", x, -38)
    else c:SetPoint("TOPLEFT", page, "TOPLEFT", x, -38) end
  end
  Col("ITEM", 6)
  Col("MARKET", 335, "RIGHT")
  Col("AVERAGE", 430, "RIGHT")
  Col("CHEAPEST", 530, "RIGHT")
  local qtyHeader = S.Text(page, 10, S.c.muted, "RIGHT")
  qtyHeader:SetText("LISTED")
  qtyHeader:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -38)

  local panel = UI:ListingsPanel(page, true)
  local list = S.List(page, 20, BuildRow, function(e)
    local p = ns.GetPrice(e.itemID)
    panel:Load(e.itemID, p and p.commodity, e.key)
  end)
  list:SetPoint("TOPLEFT", 0, -52)
  list:SetPoint("TOPRIGHT", 0, -52)
  list:SetHeight(241)
  list.emptyText = "Type at least 2 letters."
  panel:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -8)
  panel:SetPoint("BOTTOMRIGHT", 0, 0)

  local current = ""   -- lowercase text of the current search
  local live = {}      -- itemID -> { min, qty, key } from the last live search of `current`

  local function UpdateCount(shown)
    local status = shown .. " found"
    if ns.itemInfoLoading and known < total then status = status .. format("  ·  names %d/%d loaded", known, total) end
    count:SetText(status)
  end

  local function Run(keepScroll)
    local t = current
    if #t < 2 then
      list.emptyText = ns.Data.updated == 0 and "No price data yet. Run fetch-prices.mjs, then /reload."
        or "Type at least 2 letters."
      list:SetData({})
      count:SetText("")
      return
    end
    local results, seen = {}, {}
    local function Add(id)
      if seen[id] then return end
      local n = NameOf(id)
      if not n or not n:find(t, 1, true) then return end
      seen[id] = true
      local l = live[id]
      results[#results + 1] = {
        itemID = id, name = n, starts = n:sub(1, #t) == t,
        liveMin = l and l.min, liveQty = l and l.qty, key = l and l.key,
      }
    end
    for id in pairs(ns.Data.items) do Add(id) end
    for id in pairs(live) do Add(id) end
    table.sort(results, function(a, b)
      if a.starts ~= b.starts then return a.starts end
      return a.name < b.name
    end)
    for i = #results, MAX_RESULTS + 1, -1 do results[i] = nil end
    list.emptyText = "No items match. Try \"Search AH live\" at the auction house."
    local selected = list.selected and list.selected.itemID
    list:SetData(results, true)
    if selected then
      list.selected = nil
      for _, e in ipairs(results) do
        if e.itemID == selected then list.selected = e break end
      end
    end
    if not keepScroll then list.offset = 0 end
    list:Refresh()
    UpdateCount(#results)
  end

  local pending
  box:SetScript("OnTextChanged", function(self, user)
    hint:SetShown(self:GetText() == "")
    if not user then return end
    local t = self:GetText():lower():gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= current then live = {} end
    current = t
    if pending then pending:Cancel() end
    pending = C_Timer.NewTimer(0.25, function() pending = nil Run() end)
  end)

  local function LiveSearch()
    if #current < 2 then
      count:SetText("Type at least 2 letters first.")
      return
    end
    local ok, err = AH:Browse(box:GetText())
    if ok then
      count:SetText("Searching the auction house...")
    else
      count:SetText("|cffff6666" .. tostring(err) .. "|r")
    end
  end
  liveBtn:SetScript("OnClick", LiveSearch)
  box:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    if AH.isOpen then LiveSearch() end
  end)

  ns.On("BROWSE", function(text, results)
    if text:lower():gsub("^%s+", ""):gsub("%s+$", "") ~= current then return end
    live = {}
    for _, r in ipairs(results) do
      local id = r.itemKey and r.itemKey.itemID
      if id and (r.totalQuantity or 0) > 0 then
        local prev = live[id]
        if not prev or (r.minPrice or 0) < prev.min then
          live[id] = { min = r.minPrice or 0, qty = r.totalQuantity, key = r.itemKey }
        end
        if not NameOf(id) and C_Item and C_Item.RequestLoadItemDataByID then
          C_Item.RequestLoadItemDataByID(id)
        end
      end
    end
    Run(true)
  end)

  local pendingInfo
  local function InfoArrived()
    pendingInfo = nil
    if not page:IsVisible() then return end
    CountNames()
    if #current >= 2 then Run(true) else UpdateCount(0) end
  end
  ns.On("ITEM_INFO", function()
    if page:IsVisible() and not pendingInfo then pendingInfo = C_Timer.NewTimer(1, InfoArrived) end
  end)
  ns.On("ITEM_INFO_DONE", InfoArrived)

  ns.On("DATA_CHANGED", function() if page:IsVisible() then Run(true) end end)
  ns.On("AH_OPENED", function() liveBtn:Enable() end)
  ns.On("AH_CLOSED", function() liveBtn:Disable() end)

  page:SetScript("OnShow", function()
    liveBtn:SetEnabled(AH.isOpen)
    CountNames()
    ns.RequestAllItemInfo(function()
      if page:IsVisible() and known < total then UpdateCount(#list.data) end
    end)
    Run(true)
    box:SetFocus()
  end)
end)
