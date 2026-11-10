-- ForeverAH Deals tab: items whose cheapest listing is well below their average price.
-- The list comes from the downloaded data (no AH needed); clicking a row checks
-- the live auction house and lets you buy.

local _, ns = ...
local S, UI = ns.Style, ns.UI
local AH_CUT = 0.05

local function BuildDeals()
  local pct = (tonumber(ns.db.dealPct) or 70) / 100
  local minProfit = tonumber(ns.db.dealMinProfit) or 0
  local out, maxDays = {}, 1
  for id in pairs(ns.Data.items) do
    local p = ns.GetPrice(id)
    if p and p.avg and p.avg > 0 and p.minBuyout <= p.avg * pct then
      local profit = floor(p.avg * (1 - AH_CUT)) - p.minBuyout
      if profit >= minProfit then
        out[#out + 1] = {
          itemID = id, min = p.minBuyout, avg = p.avg, profit = profit,
          pct = p.minBuyout / p.avg, commodity = p.commodity, qty = p.quantity,
        }
      end
    end
    if p and p.days > maxDays then maxDays = p.days end
  end
  table.sort(out, function(a, b) return a.profit > b.profit end)
  return out, maxDays
end

local function BuildDealRow(row)
  row.icon = S.Icon(row, 16)
  row.icon:SetPoint("LEFT", 4, 0)
  row.name = S.Text(row, 12)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetWidth(210)
  row.min = S.Text(row, 12, S.c.text, "RIGHT")
  row.min:SetPoint("RIGHT", row, "LEFT", 340, 0)
  row.avg = S.Text(row, 12, S.c.muted, "RIGHT")
  row.avg:SetPoint("RIGHT", row, "LEFT", 440, 0)
  row.profit = S.Text(row, 12, S.c.good, "RIGHT")
  row.profit:SetPoint("RIGHT", row, "LEFT", 545, 0)
  row.pct = S.Text(row, 12, S.c.muted, "RIGHT")
  row.pct:SetPoint("RIGHT", row, "RIGHT", -8, 0)
  function row:Update(d)
    local name, color, icon = ns.ItemInfo(d.itemID)
    self.icon:SetTexture(icon)
    self.name:SetText(color .. name .. "|r")
    self.min:SetText(ns.Money(d.min))
    self.avg:SetText(ns.Money(d.avg))
    self.profit:SetText(ns.Money(d.profit))
    self.pct:SetText(floor(d.pct * 100 + 0.5) .. "%")
  end
  function row:OnEnterTip()
    local _, _, _, _, _, link = ns.ItemInfo(self.item.itemID)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if link then GameTooltip:SetHyperlink(link) else GameTooltip:SetText("Item #" .. self.item.itemID) end
    GameTooltip:Show()
  end
end

UI:AddTab("Deals", function(page)
  -- filter bar
  local pctLabel = S.Text(page, 11, S.c.muted)
  pctLabel:SetPoint("TOPLEFT", 2, -6)
  pctLabel:SetText("Max % of avg")
  local pctBox = S.Input(page, 44, 22)
  pctBox:SetPoint("LEFT", pctLabel, "RIGHT", 6, 0)
  pctBox:SetNumeric(true)

  local profitLabel = S.Text(page, 11, S.c.muted)
  profitLabel:SetPoint("LEFT", pctBox, "RIGHT", 14, 0)
  profitLabel:SetText("Min profit")
  local profitBox = S.Input(page, 80, 22)
  profitBox:SetPoint("LEFT", profitLabel, "RIGHT", 6, 0)

  local refresh = S.Button(page, "Refresh", 76, 22)
  refresh:SetPoint("LEFT", profitBox, "RIGHT", 10, 0)

  local count = S.Text(page, 11, S.c.muted, "RIGHT")
  count:SetPoint("TOPRIGHT", -2, -10)

  -- column headers
  local function Col(text, x, justify)
    local c = S.Text(page, 10, S.c.muted, justify)
    c:SetText(text)
    if justify == "RIGHT" then c:SetPoint("TOPRIGHT", page, "TOPLEFT", x, -38)
    else c:SetPoint("TOPLEFT", page, "TOPLEFT", x, -38) end
  end
  Col("ITEM", 6)
  Col("CHEAPEST", 340, "RIGHT")
  local avgHeader = S.Text(page, 10, S.c.muted, "RIGHT")
  avgHeader:SetPoint("TOPRIGHT", page, "TOPLEFT", 440, -38)
  Col("PROFIT", 545, "RIGHT")
  local pctHeader = S.Text(page, 10, S.c.muted, "RIGHT")
  pctHeader:SetText("%")
  pctHeader:SetPoint("TOPRIGHT", page, "TOPRIGHT", -16, -38)

  local panel = UI:ListingsPanel(page, true)
  local list = S.List(page, 20, BuildDealRow, function(d) panel:Load(d.itemID, d.commodity) end)
  list:SetPoint("TOPLEFT", 0, -52)
  list:SetPoint("TOPRIGHT", 0, -52)
  list:SetHeight(241)

  panel:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -8)
  panel:SetPoint("BOTTOMRIGHT", 0, 0)

  local function Rebuild()
    local pct = tonumber(pctBox:GetText())
    if pct and pct > 0 and pct <= 100 then ns.db.dealPct = pct end
    local profit = ns.ParseMoney(profitBox:GetText())
    if profit then ns.db.dealMinProfit = profit end
    pctBox:SetText(ns.db.dealPct)
    profitBox:SetText(ns.MoneyInput(ns.db.dealMinProfit))

    if ns.Data.updated == 0 then
      list.emptyText = "No price data yet. Run fetch-prices.mjs, then /reload."
      list:SetData({})
      count:SetText("")
      return
    end
    local deals, days = BuildDeals()
    avgHeader:SetText(days > 1 and (days .. "-DAY AVG") or "AVG (1 DAY)")
    list.emptyText = "No deals match these filters."
    list:SetData(deals)
    count:SetText(#deals .. " deals  ·  profit after 5% AH cut, per unit")
  end

  refresh:SetScript("OnClick", Rebuild)
  pctBox.onCommit = Rebuild
  profitBox.onCommit = Rebuild
  page:SetScript("OnShow", Rebuild)
  ns.On("DATA_CHANGED", function() if page:IsVisible() then Rebuild() end end)
  ns.On("ITEM_INFO", function() if page:IsVisible() then list:Refresh() end end)
end)
