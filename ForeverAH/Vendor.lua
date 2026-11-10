-- ForeverAH Vendor tab: items listed on the AH for less than a vendor pays for them.
-- Buy them, sell them to any vendor. No AH cut applies because you sell to an NPC.

local _, ns = ...
local S, UI = ns.Style, ns.UI

local function VendorPrice(itemID)
  if not ns.IsCached(itemID) then return nil end -- don't trigger a server request
  return select(11, ns.GetItemInfo(itemID))
end

local function BuildFlips(minProfit)
  local out = {}
  for id in pairs(ns.Data.items) do
    local vendor = VendorPrice(id)
    if vendor and vendor > 0 then
      local p = ns.GetPrice(id)
      local profit = vendor - p.minBuyout
      if profit >= minProfit then
        out[#out + 1] = {
          itemID = id, min = p.minBuyout, vendor = vendor, profit = profit,
          qty = p.quantity, commodity = p.commodity,
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.profit > b.profit end)
  return out
end

local function BuildRow(row)
  row.icon = S.Icon(row, 16)
  row.icon:SetPoint("LEFT", 4, 0)
  row.name = S.Text(row, 12)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetWidth(220)
  row.min = S.Text(row, 12, S.c.text, "RIGHT")
  row.min:SetPoint("RIGHT", row, "LEFT", 335, 0)
  row.vendor = S.Text(row, 12, S.c.muted, "RIGHT")
  row.vendor:SetPoint("RIGHT", row, "LEFT", 430, 0)
  row.profit = S.Text(row, 12, S.c.good, "RIGHT")
  row.profit:SetPoint("RIGHT", row, "LEFT", 530, 0)
  row.qty = S.Text(row, 12, S.c.muted, "RIGHT")
  row.qty:SetPoint("RIGHT", row, "RIGHT", -8, 0)
  function row:Update(e)
    local name, color, icon = ns.ItemInfo(e.itemID)
    self.icon:SetTexture(icon)
    self.name:SetText(color .. name .. "|r")
    self.min:SetText(ns.Money(e.min))
    self.vendor:SetText(ns.Money(e.vendor))
    self.profit:SetText(ns.Money(e.profit))
    self.qty:SetText(e.qty)
  end
  function row:OnEnterTip()
    local _, _, _, _, _, link = ns.ItemInfo(self.item.itemID)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if link then GameTooltip:SetHyperlink(link) else GameTooltip:SetText("Item #" .. self.item.itemID) end
    GameTooltip:Show()
  end
end

UI:AddTab("Vendor", function(page)
  local profitLabel = S.Text(page, 11, S.c.muted)
  profitLabel:SetPoint("TOPLEFT", 2, -6)
  profitLabel:SetText("Min profit each")
  local profitBox = S.Input(page, 80, 22)
  profitBox:SetPoint("LEFT", profitLabel, "RIGHT", 6, 0)
  local refresh = S.Button(page, "Refresh", 76, 22)
  refresh:SetPoint("LEFT", profitBox, "RIGHT", 10, 0)
  local count = S.Text(page, 11, S.c.muted, "RIGHT")
  count:SetPoint("TOPRIGHT", -2, -10)

  local function Col(text, x, justify)
    local c = S.Text(page, 10, S.c.muted, justify)
    c:SetText(text)
    if justify == "RIGHT" then c:SetPoint("TOPRIGHT", page, "TOPLEFT", x, -38)
    else c:SetPoint("TOPLEFT", page, "TOPLEFT", x, -38) end
  end
  Col("ITEM", 6)
  Col("CHEAPEST", 335, "RIGHT")
  Col("VENDOR PAYS", 430, "RIGHT")
  Col("PROFIT EACH", 530, "RIGHT")
  local qtyHeader = S.Text(page, 10, S.c.muted, "RIGHT")
  qtyHeader:SetText("LISTED")
  qtyHeader:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -38)

  local panel = UI:ListingsPanel(page, true)
  local selected -- the flip being checked live
  local list = S.List(page, 20, BuildRow, function(e)
    selected = e
    panel:Load(e.itemID, e.commodity)
  end)
  list:SetPoint("TOPLEFT", 0, -52)
  list:SetPoint("TOPRIGHT", 0, -52)
  list:SetHeight(241)
  panel:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -8)
  panel:SetPoint("BOTTOMRIGHT", 0, 0)

  -- When live listings arrive, pre-fill a purchase of everything below vendor price.
  panel.onResults = function(s)
    if not selected or s.itemID ~= selected.itemID or not panel.qty then return end
    local vendor = selected.vendor
    local qty, cost, cheapest = 0, 0, nil
    for _, r in ipairs(s.results) do
      if r.unit >= vendor then break end
      if not r.mine then
        qty = qty + r.qty
        cost = cost + r.total
        cheapest = cheapest or r
      end
    end
    if qty == 0 then
      panel.note:SetText("|cffff6666Nothing below vendor price any more.|r")
      return
    end
    local profit = vendor * qty - cost
    if s.commodity then
      panel.qty:SetText(qty)
      panel.note:SetText(format("%d below vendor  ·  profit %s", qty, ns.Money(profit)))
    else
      panel.list.selected = cheapest
      panel.list:Refresh()
      panel.note:SetText(format("%d below vendor  ·  cheapest selected", qty))
    end
  end

  local function Rebuild()
    local profit = ns.ParseMoney(profitBox:GetText())
    if profit then ns.db.vendorMinProfit = profit end
    ns.db.vendorMinProfit = ns.db.vendorMinProfit or 1
    profitBox:SetText(ns.MoneyInput(ns.db.vendorMinProfit))
    if ns.Data.updated == 0 then
      list.emptyText = "No price data yet. Run fetch-prices.mjs, then /reload."
      list:SetData({}, true)
      count:SetText("")
      return
    end
    local flips = BuildFlips(ns.db.vendorMinProfit)
    local selectedID = list.selected and list.selected.itemID
    list.emptyText = "Nothing on the AH is below vendor price right now."
    list:SetData(flips, true)
    list.selected = nil
    for _, e in ipairs(flips) do
      if e.itemID == selectedID then list.selected = e break end
    end
    list:Refresh()
    local known, total = ns.CountItemInfo()
    local status = #flips .. " items below vendor"
    if ns.itemInfoLoading then
      status = status .. format("  ·  checking %d/%d items", known, total)
    elseif known < total then
      status = status .. format("  ·  %d items have no vendor info", total - known)
    end
    count:SetText(status)
  end

  refresh:SetScript("OnClick", Rebuild)
  ns.On("DATA_CHANGED", function() if page:IsVisible() then Rebuild() end end)
  profitBox.onCommit = Rebuild
  -- While item info is loading, refresh at most every 2 seconds, then once more when done.
  local pending
  ns.On("ITEM_INFO", function()
    if not page:IsVisible() or pending then return end
    pending = C_Timer.NewTimer(2, function()
      pending = nil
      if page:IsVisible() then Rebuild() end
    end)
  end)
  ns.On("ITEM_INFO_DONE", function() if page:IsVisible() then Rebuild() end end)
  page:SetScript("OnShow", function()
    Rebuild()
    ns.RequestAllItemInfo()
  end)
end)
