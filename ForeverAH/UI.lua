-- ForeverAH main window: title bar, tabs, and the live listings panel shared by tabs.

local _, ns = ...
local S, AH = ns.Style, ns.AH
local UI = { tabs = {} }
ns.UI = UI

function UI:AddTab(name, build)
  table.insert(self.tabs, { name = name, build = build })
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

function UI:Create()
  if self.frame then return self.frame end
  local f = CreateFrame("Frame", "ForeverAHFrame", UIParent, S.TPL)
  self.frame = f
  f:SetSize(640, 600)
  S.Backdrop(f, S.c.bg, S.c.border)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:Hide()
  tinsert(UISpecialFrames, "ForeverAHFrame") -- Esc closes it

  local bar = S.Panel(f, S.c.titlebar, S.c.titlebar)
  bar:SetPoint("TOPLEFT", 1, -1)
  bar:SetPoint("TOPRIGHT", -1, -1)
  bar:SetHeight(30)
  bar:EnableMouse(true)
  bar:RegisterForDrag("LeftButton")
  bar:SetScript("OnDragStart", function() f:StartMoving() end)
  bar:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    local point, _, relPoint, x, y = f:GetPoint()
    ns.db.pos = { point, relPoint, x, y }
  end)

  local accent = bar:CreateTexture(nil, "ARTWORK")
  accent:SetColorTexture(unpack(S.c.accent))
  accent:SetPoint("BOTTOMLEFT")
  accent:SetPoint("BOTTOMRIGHT")
  accent:SetHeight(1)

  local title = S.Text(bar, 14, S.c.accent)
  title:SetPoint("LEFT", 12, 0)
  title:SetText("ForeverAH")

  local close = S.Button(bar, "x", 24, 20, function() f:Hide() end)
  close:SetPoint("RIGHT", -6, 0)

  f.scan = S.Button(bar, "Scan AH", 110, 20, function() ns.Scan:Start() end)
  f.scan:SetPoint("RIGHT", close, "LEFT", -8, 0)
  f.scan.tip = "Read the whole auction house now (Blizzard allows this once every 15 minutes). The results replace the downloaded prices until a newer download arrives."

  f.age = S.Text(bar, 11, S.c.muted, "RIGHT")
  f.age:SetPoint("RIGHT", f.scan, "LEFT", -10, 0)

  -- keep the scan button's countdown current
  local elapsed = 0
  f:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed >= 1 then
      elapsed = 0
      UI:UpdateScanButton()
    end
  end)

  f.tabButtons, f.pages = {}, {}
  for i, tab in ipairs(self.tabs) do
    local b = S.Button(f, tab.name, 96, 24, function() UI:SelectTab(i) end)
    b:SetPoint("TOPLEFT", 10 + (i - 1) * 100, -40)
    local page = CreateFrame("Frame", nil, f)
    page:SetPoint("TOPLEFT", 10, -72)
    page:SetPoint("BOTTOMRIGHT", -10, 10)
    page:Hide()
    tab.build(page)
    f.tabButtons[i], f.pages[i] = b, page
  end

  f:SetScript("OnShow", function()
    UI:UpdateAge()
    UI:UpdateScanButton()
  end)
  self:RestorePosition()
  self:SelectTab(ns.db.tab or 1)
  return f
end

function UI:RestorePosition()
  local f = self.frame
  if not f then return end
  f:ClearAllPoints()
  local p = ns.db.pos
  if p then
    f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  elseif AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    f:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 8, 0)
  else
    f:SetPoint("CENTER")
  end
end

function UI:SelectTab(i)
  local f = self.frame
  if not f.pages[i] then i = 1 end
  for j, page in ipairs(f.pages) do
    page:SetShown(j == i)
    f.tabButtons[j]:SetActive(j == i)
  end
  ns.db.tab = i
end

function UI:UpdateAge()
  local f = self.frame
  if not f then return end
  local d = ns.Data
  if d.updated == 0 then
    f.age:SetText("No price data yet")
  else
    f.age:SetText(format("%s %s  ·  house %s", d.source == "scan" and "Scanned" or "Data",
      ns.Age(d.updated), table.concat(d.houses, ", ")))
  end
end

function UI:UpdateScanButton()
  local f = self.frame
  if not f then return end
  local Scan = ns.Scan
  if Scan.running then
    f.scan:SetLabel(format("Scanning %d%%", floor(Scan.progress * 100)))
    f.scan:Disable()
    return
  end
  local cd = Scan:Cooldown()
  if cd > 0 then
    f.scan:SetLabel(format("Scan in %d:%02d", floor(cd / 60), cd % 60))
  else
    f.scan:SetLabel("Scan AH")
  end
  f.scan:SetEnabled(Scan:CanScan() and true or false)
end

ns.On("SCAN_PROGRESS", function() UI:UpdateScanButton() end)
ns.On("SCAN_DONE", function()
  UI:UpdateScanButton()
  UI:UpdateAge()
end)

function UI:Show() self:Create():Show() end
function UI:Hide() if self.frame then self.frame:Hide() end end
function UI:Toggle()
  local f = self:Create()
  f:SetShown(not f:IsShown())
end

-- A small button under the Blizzard auction house window to reopen ours.
function UI:AttachToAH()
  if self.ahButton or not AuctionHouseFrame then return end
  local b = S.Button(AuctionHouseFrame, "ForeverAH", 90, 22, function() UI:Toggle() end)
  b:SetPoint("TOPRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", 0, -4)
  self.ahButton = b
end

ns.On("AH_OPENED", function()
  UI:AttachToAH()
  if ns.db.autoOpen then
    UI:Show()
    if not ns.db.pos then UI:RestorePosition() end
  end
end)
ns.On("AH_CLOSED", function() UI:Hide() end)

---------------------------------------------------------------------------
-- Live listings panel (used by both tabs)
---------------------------------------------------------------------------

local function BuildListingRow(row)
  row.qty = S.Text(row, 12)
  row.qty:SetPoint("LEFT", 8, 0)
  row.each = S.Text(row, 12, S.c.text, "RIGHT")
  row.each:SetPoint("RIGHT", row, "LEFT", 200, 0)
  row.total = S.Text(row, 12, S.c.muted, "RIGHT")
  row.total:SetPoint("RIGHT", row, "LEFT", 330, 0)
  row.tag = S.Text(row, 11, S.c.accent)
  row.tag:SetPoint("LEFT", row, "LEFT", 342, 0)
  function row:Update(r)
    self.qty:SetText(r.qty)
    self.each:SetText(ns.Money(r.unit))
    self.total:SetText(ns.Money(r.total))
    self.tag:SetText(r.mine and "yours" or "")
  end
end

function UI:ListingsPanel(parent, canBuy)
  local p = S.Panel(parent, S.c.panel, S.c.border)

  p.icon = S.Icon(p, 18)
  p.icon:SetPoint("TOPLEFT", 8, -6)
  p.header = S.Text(p, 13)
  p.header:SetPoint("LEFT", p.icon, "RIGHT", 6, 0)
  p.header:SetPoint("RIGHT", p, "RIGHT", -150, 0)
  p.status = S.Text(p, 11, S.c.muted, "RIGHT")
  p.status:SetPoint("TOPRIGHT", -10, -9)

  local function Col(text, x, justify)
    local c = S.Text(p, 10, S.c.muted, justify)
    c:SetText(text)
    if justify == "RIGHT" then c:SetPoint("TOPRIGHT", p, "TOPLEFT", x, -32)
    else c:SetPoint("TOPLEFT", p, "TOPLEFT", x, -32) end
  end
  Col("QTY", 12)
  Col("EACH", 204, "RIGHT")
  Col("TOTAL", 334, "RIGHT")

  p.list = S.List(p, 20, BuildListingRow, function(item, index) p:OnRowClick(item, index) end)
  p.list:SetPoint("TOPLEFT", 4, -46)
  p.list:SetPoint("BOTTOMRIGHT", -4, canBuy and 40 or 6)
  p.list.emptyText = "Pick an item to see what's listed right now."

  function p:Load(itemID, commodity, key)
    self.itemID, self.commodity = itemID, commodity
    self.results = {}
    local name, color, icon = ns.ItemInfo(itemID)
    self.icon:SetTexture(icon)
    self.header:SetText(color .. name .. "|r")
    self.list.emptyText = "Searching..."
    self.list:SetData({})
    if canBuy then self:ResetBuy() end
    local ok, err = AH:Search(itemID, commodity, key)
    self.status:SetText(ok and "Searching..." or "")
    if not ok then
      self.list.emptyText = err
      self.list:Refresh()
    end
  end

  function p:OnResults(s)
    if s.itemID ~= self.itemID then return end
    self.commodity = s.commodity
    self.results = s.results
    self.list.emptyText = "Nothing listed right now."
    self.list:SetData(s.results)
    self.status:SetText(#s.results .. " listing" .. (#s.results == 1 and "" or "s") .. " (live)")
    if canBuy then self:ResetBuy() end
    if self.onResults then self.onResults(s) end
  end

  function p:OnRowClick(item, index)
    if not canBuy then return end
    if self.commodity then
      -- Clicking a commodity row fills in "buy everything up to this price".
      local q = 0
      for i = 1, index do
        local r = self.results[i]
        if r and not r.mine then q = q + r.qty end
      end
      self.qty:SetText(q)
      self.note:SetText("up to " .. ns.Money(item.unit) .. " each")
    else
      self.note:SetText(item.mine and "That one's yours" or ("buyout " .. ns.Money(item.total)))
    end
  end

  ns.On("RESULTS", function(s) p:OnResults(s) end)
  ns.On("AH_CLOSED", function()
    p.status:SetText("AH closed")
    if canBuy then p:ResetBuy() end
  end)

  if canBuy then
    local bar = CreateFrame("Frame", nil, p)
    bar:SetPoint("BOTTOMLEFT", 8, 8)
    bar:SetPoint("BOTTOMRIGHT", -8, 8)
    bar:SetHeight(24)

    p.qtyLabel = S.Text(bar, 11, S.c.muted)
    p.qtyLabel:SetPoint("LEFT")
    p.qtyLabel:SetText("Qty")
    p.qty = S.Input(bar, 56, 22)
    p.qty:SetPoint("LEFT", p.qtyLabel, "RIGHT", 6, 0)
    p.qty:SetNumeric(true)

    p.buy = S.Button(bar, "Buy", 170, 22, function() p:OnBuyClick() end)
    p.buy:SetPoint("RIGHT")
    p.cancel = S.Button(bar, "Cancel", 64, 22, function()
      AH:CancelCommodityBuy()
      p:ResetBuy()
    end)
    p.cancel:SetPoint("RIGHT", p.buy, "LEFT", -6, 0)

    p.note = S.Text(bar, 11, S.c.muted)
    p.note:SetPoint("LEFT", p.qty, "RIGHT", 8, 0)
    p.note:SetPoint("RIGHT", p.cancel, "LEFT", -6, 0)

    function p:ResetBuy()
      self.cancel:Hide()
      self.buy:Enable()
      self.qty:SetShown(self.commodity ~= false)
      self.qtyLabel:SetShown(self.commodity ~= false)
      self.buy:SetLabel(self.commodity == false and "Buy selected" or "Buy")
    end

    function p:OnBuyClick()
      if not self.itemID then return end
      if self.commodity == false then
        local r = self.list.selected
        if not r or r.mine then
          self.note:SetText("Pick a listing first")
          return
        end
        AH:BuyItem(r)
        self.buy:SetLabel("Buying...")
        self.buy:Disable()
        return
      end
      local pur = AH.purchase
      if pur and pur.total and pur.itemID == self.itemID then
        AH:ConfirmCommodityBuy()
        self.buy:SetLabel("Buying...")
        self.buy:Disable()
      else
        local q = tonumber(self.qty:GetText())
        if not q or q < 1 then
          self.note:SetText("Enter a quantity, or click a row")
          return
        end
        AH:StartCommodityBuy(self.itemID, q)
        self.buy:SetLabel("Getting price...")
        self.buy:Disable()
        self.cancel:Show()
      end
    end

    ns.On("PURCHASE_PRICE", function(pur)
      if pur.itemID ~= p.itemID then return end
      p.buy:SetLabel("Confirm " .. ns.Money(pur.total))
      p.buy:Enable()
      p.note:SetText(ns.Money(pur.unit) .. " each")
    end)
    ns.On("PURCHASE_DONE", function(ok)
      if not p.itemID then return end
      p:ResetBuy()
      p.note:SetText(ok and "|cff66dd77Bought.|r" or "|cffff6666Purchase failed.|r")
    end)

    p:ResetBuy()
  end

  return p
end
