-- ForeverAH Sell tab: pick something from your bags, see live listings, post with an undercut.

local _, ns = ...
local S, UI, AH = ns.Style, ns.UI, ns.AH

local DURATIONS = {
  { label = (AUCTION_DURATION_ONE or "Short"), short = "Short" },
  { label = (AUCTION_DURATION_TWO or "Medium"), short = "Medium" },
  { label = (AUCTION_DURATION_THREE or "Long"), short = "Long" },
}

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------

local function NumSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
  return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

local function SlotInfo(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if info then return info.itemID, info.stackCount, info.isBound, info.hyperlink, info.iconFileID end
  elseif GetContainerItemInfo then
    local icon, count, _, _, _, _, link, _, _, id = GetContainerItemInfo(bag, slot)
    return id, count, nil, link, icon
  end
end

-- One entry per item ID with the total count and the first bag slot holding it.
local function ScanBags()
  local byID, list = {}, {}
  local canCheck = AH.isOpen and C_AuctionHouse and C_AuctionHouse.IsSellItemValid
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, NumSlots(bag) do
      local id, count, bound, link, icon = SlotInfo(bag, slot)
      if id and not bound then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        local valid = true
        if canCheck then
          local ok, v = pcall(C_AuctionHouse.IsSellItemValid, loc, false)
          valid = ok and v
        end
        if valid then
          local e = byID[id]
          if not e then
            e = { itemID = id, count = 0, loc = loc, link = link, icon = icon }
            byID[id] = e
            list[#list + 1] = e
          end
          e.count = e.count + (count or 1)
        end
      end
    end
  end
  for _, e in ipairs(list) do
    e.name = ns.ItemInfo(e.itemID)
    e.commodity = AH:IsCommodity(e.loc, e.itemID)
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list, byID
end

local function BuildBagRow(row)
  row.icon = S.Icon(row, 18)
  row.icon:SetPoint("LEFT", 4, 0)
  row.name = S.Text(row, 12)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetPoint("RIGHT", row, "RIGHT", -40, 0)
  row.count = S.Text(row, 11, S.c.muted, "RIGHT")
  row.count:SetPoint("RIGHT", -6, 0)
  function row:Update(e)
    local name, color, icon = ns.ItemInfo(e.itemID)
    self.icon:SetTexture(e.icon or icon)
    self.name:SetText(color .. name .. "|r")
    self.count:SetText(e.count)
  end
  function row:OnEnterTip()
    if not self.item.link then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(self.item.link)
    GameTooltip:Show()
  end
end

---------------------------------------------------------------------------
-- Tab
---------------------------------------------------------------------------

UI:AddTab("Sell", function(page)
  local sel -- selected bag entry
  local byID = {}
  local ShowItem -- defined below; the bag list calls it on click

  -- left: bag items
  local bagsTitle = S.Text(page, 10, S.c.muted)
  bagsTitle:SetPoint("TOPLEFT", 4, -4)
  bagsTitle:SetText("IN YOUR BAGS")
  local bags = S.List(page, 22, BuildBagRow, function(e) ShowItem(e) end)
  bags:SetPoint("TOPLEFT", 0, -20)
  bags:SetPoint("BOTTOMLEFT", 0, 0)
  bags:SetWidth(226)

  -- right: post form
  local form = S.Panel(page, S.c.panel, S.c.border)
  form:SetPoint("TOPLEFT", bags, "TOPRIGHT", 10, 20)
  form:SetPoint("TOPRIGHT", 0, 0)
  form:SetHeight(236)

  local icon = S.Icon(form, 32)
  icon:SetPoint("TOPLEFT", 10, -10)
  local name = S.Text(form, 14)
  name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
  name:SetPoint("RIGHT", form, "RIGHT", -10, 0)
  local stock = S.Text(form, 11, S.c.muted)
  stock:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)

  local lMarket, vMarket = S.Stat(form, "Market", 70)
  lMarket:SetPoint("TOPLEFT", 10, -54)
  local lAvg, vAvg = S.Stat(form, "Average", 70)
  lAvg:SetPoint("TOPLEFT", 190, -54)
  local lLow, vLow = S.Stat(form, "Lowest now", 70)
  lLow:SetPoint("TOPLEFT", 10, -72)
  local lVendor, vVendor = S.Stat(form, "Vendor", 70)
  lVendor:SetPoint("TOPLEFT", 190, -72)

  local priceLabel = S.Text(form, 11, S.c.muted)
  priceLabel:SetPoint("TOPLEFT", 10, -102)
  priceLabel:SetText("Price each")
  local priceBox = S.Input(form, 110, 22)
  priceBox:SetPoint("TOPLEFT", 84, -97)
  local priceNote = S.Text(form, 11, S.c.muted)
  priceNote:SetPoint("LEFT", priceBox, "RIGHT", 8, 0)
  priceNote:SetPoint("RIGHT", form, "RIGHT", -10, 0)

  local qtyLabel = S.Text(form, 11, S.c.muted)
  qtyLabel:SetPoint("TOPLEFT", 10, -132)
  qtyLabel:SetText("Quantity")
  local qtyBox = S.Input(form, 56, 22)
  qtyBox:SetPoint("TOPLEFT", 84, -127)
  qtyBox:SetNumeric(true)
  local maxBtn = S.Button(form, "Max", 44, 22)
  maxBtn:SetPoint("LEFT", qtyBox, "RIGHT", 6, 0)
  local qtyNote = S.Text(form, 11, S.c.muted)
  qtyNote:SetPoint("LEFT", maxBtn, "RIGHT", 8, 0)

  local durLabel = S.Text(form, 11, S.c.muted)
  durLabel:SetPoint("TOPLEFT", 10, -162)
  durLabel:SetText("Duration")
  local durButtons = {}
  for i, d in ipairs(DURATIONS) do
    local b = S.Button(form, d.label, 84, 22)
    b:SetPoint("TOPLEFT", 84 + (i - 1) * 88, -157)
    durButtons[i] = b
  end

  local deposit = S.Text(form, 11, S.c.muted)
  deposit:SetPoint("TOPLEFT", 10, -194)
  local postBtn = S.Button(form, "Post", 120, 26)
  postBtn:SetPoint("BOTTOMRIGHT", -10, 10)
  local status = S.Text(form, 11, S.c.muted, "RIGHT")
  status:SetPoint("RIGHT", postBtn, "LEFT", -10, 0)
  status:SetPoint("LEFT", deposit, "LEFT", 0, 0)

  local panel = UI:ListingsPanel(page, false)
  panel:SetPoint("TOPLEFT", form, "BOTTOMLEFT", 0, -8)
  panel:SetPoint("BOTTOMRIGHT", 0, 0)

  -- helpers
  local function Qty()
    if not sel then return 0 end
    if sel.commodity == false then return 1 end
    local q = tonumber(qtyBox:GetText()) or 0
    return math.min(q, sel.count)
  end

  local function UpdateDeposit()
    if not sel then deposit:SetText("") return end
    local d = AH:Deposit(sel.loc, sel.itemID, sel.commodity, ns.db.duration, Qty())
    deposit:SetText(d and ("Deposit " .. ns.Money(d)) or "")
  end

  local function CheckPrice()
    if not sel then return end
    local price = ns.ParseMoney(priceBox:GetText())
    local _, _, _, vendor = ns.ItemInfo(sel.itemID)
    local p = ns.GetPrice(sel.itemID)
    if not price then
      priceNote:SetText("|cffff6666Use a price like 1g23s45c|r")
    elseif vendor and vendor > 0 and price < vendor then
      priceNote:SetText("|cffff6666Below vendor price!|r")
    elseif p and p.avg > 0 and price < p.avg * 0.5 then
      priceNote:SetText("|cffffb340Under half the average|r")
    else
      priceNote:SetText(priceNote.base or "")
    end
  end

  local function SetDuration(i)
    ns.db.duration = i
    for j, b in ipairs(durButtons) do b:SetActive(j == i) end
    UpdateDeposit()
  end
  for i, b in ipairs(durButtons) do b:SetScript("OnClick", function() SetDuration(i) end) end

  function ShowItem(e)
    sel = e
    if not e then
      icon:SetTexture(nil)
      name:SetText("|cff8f96a6Pick an item from your bags|r")
      stock:SetText("")
      for _, v in ipairs({ vMarket, vAvg, vLow, vVendor }) do v:SetText("-") end
      priceBox:SetText("")
      priceNote.base = nil
      priceNote:SetText("")
      qtyBox:SetText("")
      postBtn:Disable()
      UpdateDeposit()
      return
    end
    local itemName, color, itemIcon, vendor = ns.ItemInfo(e.itemID)
    icon:SetTexture(e.icon or itemIcon)
    name:SetText(color .. itemName .. "|r")
    local kind = e.commodity == true and "commodity" or (e.commodity == false and "item, posts one at a time" or "")
    stock:SetText(e.count .. " in bags" .. (kind ~= "" and ("  ·  " .. kind) or ""))
    local p = ns.GetPrice(e.itemID)
    vMarket:SetText(p and ns.Money(p.market) or "-")
    vAvg:SetText(p and (ns.Money(p.avg) .. (p.days > 1 and ("  (" .. p.days .. "d)") or "")) or "-")
    vLow:SetText(AH.isOpen and "checking..." or "open the AH")
    vVendor:SetText(vendor and vendor > 0 and ns.Money(vendor) or "-")
    -- start from the data's cheapest price until the live search answers
    priceNote.base = p and "from data, checking live..." or "no data, checking live..."
    priceBox:SetText(p and ns.MoneyInput(math.max(1, p.minBuyout - 1)) or "")
    local commodityQty = e.commodity ~= false
    qtyBox:SetShown(commodityQty)
    maxBtn:SetShown(commodityQty)
    qtyLabel:SetShown(commodityQty)
    qtyNote:SetText("")
    qtyBox:SetText(commodityQty and e.count or 1)
    postBtn:SetEnabled(AH.isOpen)
    CheckPrice()
    UpdateDeposit()
    panel:Load(e.itemID, e.commodity)
  end

  -- live results set the suggested price: 1c under the cheapest listing that isn't yours
  panel.onResults = function(s)
    if not sel or s.itemID ~= sel.itemID then return end
    sel.commodity = s.commodity
    local lowest, lowestOther
    for _, r in ipairs(s.results) do
      lowest = lowest or r
      if not r.mine then lowestOther = r break end
    end
    vLow:SetText(lowest and ns.Money(lowest.unit) or "none listed")
    if lowestOther then
      if lowest.mine and lowest.unit <= lowestOther.unit then
        priceBox:SetText(ns.MoneyInput(lowest.unit))
        priceNote.base = "matches your cheapest listing"
      else
        priceBox:SetText(ns.MoneyInput(math.max(1, floor(lowestOther.unit) - 1)))
        priceNote.base = "1c under the cheapest"
      end
    elseif lowest then
      priceBox:SetText(ns.MoneyInput(lowest.unit))
      priceNote.base = "only your listings are up"
    else
      local p = ns.GetPrice(sel.itemID)
      if p then
        priceBox:SetText(ns.MoneyInput(p.avg))
        priceNote.base = "none listed, using the average"
      else
        priceNote.base = "none listed, set your own price"
      end
    end
    CheckPrice()
    UpdateDeposit()
  end

  local function RefreshBags(keepSelection)
    local list
    list, byID = ScanBags()
    bags.emptyText = "Nothing in your bags can be auctioned."
    local prev = sel and sel.itemID
    bags:SetData(list, true)
    if keepSelection and prev and byID[prev] then
      sel = byID[prev]
      bags.selected = sel
      bags:Refresh()
      stock:SetText(sel.count .. " in bags")
    elseif prev and not byID[prev] then
      bags.selected = nil
      bags:Refresh()
      ShowItem(nil)
    end
  end

  priceBox.onCommit = function() CheckPrice() end
  priceBox:SetScript("OnTextChanged", function(_, user) if user then CheckPrice() end end)
  qtyBox:SetScript("OnTextChanged", function(_, user) if user then UpdateDeposit() end end)
  maxBtn:SetScript("OnClick", function()
    if sel then qtyBox:SetText(sel.count) UpdateDeposit() end
  end)

  postBtn:SetScript("OnClick", function()
    if not sel then return end
    local price = ns.ParseMoney(priceBox:GetText())
    if not price or price < 1 then
      status:SetText("|cffff6666Set a price first.|r")
      return
    end
    local q = Qty()
    if q < 1 then
      status:SetText("|cffff6666Set a quantity.|r")
      return
    end
    -- bag slots may have moved since we scanned; find the item again
    local _, fresh = ScanBags()
    local e = fresh[sel.itemID]
    if not e then
      status:SetText("|cffff6666That item isn't in your bags any more.|r")
      return
    end
    local commodity = sel.commodity
    if commodity == nil then commodity = e.commodity end
    local ok, err = AH:Post(e.loc, commodity, ns.db.duration, q, price)
    if ok then
      status:SetText("Posting...")
      postBtn:Disable()
    else
      status:SetText("|cffff6666" .. tostring(err) .. "|r")
    end
  end)

  ns.On("POSTED", function()
    status:SetText("|cff66dd77Posted.|r")
    postBtn:SetEnabled(AH.isOpen and sel ~= nil)
    if page:IsVisible() then RefreshBags(true) end
  end)

  local events = CreateFrame("Frame")
  pcall(events.RegisterEvent, events, "BAG_UPDATE_DELAYED")
  events:SetScript("OnEvent", function() if page:IsVisible() then RefreshBags(true) end end)

  ns.On("AH_OPENED", function() if page:IsVisible() then RefreshBags(true) end end)
  ns.On("AH_CLOSED", function() postBtn:Disable() end)
  ns.On("ITEM_INFO", function() if page:IsVisible() then bags:Refresh() end end)

  page:SetScript("OnShow", function()
    RefreshBags(true)
    if not sel then ShowItem(nil) end
  end)
  SetDuration(ns.db.duration or 2)
  ShowItem(nil)
end)
