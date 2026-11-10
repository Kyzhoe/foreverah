-- ForeverAH style kit: flat dark panels, 1px borders, one accent colour.
-- Change the colours here and the whole window follows.

local _, ns = ...
local S = {}
ns.Style = S

S.TPL = BackdropTemplateMixin and "BackdropTemplate" or nil
S.WHITE = "Interface\\Buttons\\WHITE8x8"
S.FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

S.c = {
  bg           = { 0.055, 0.060, 0.075, 0.96 },
  titlebar     = { 0.080, 0.087, 0.105, 1 },
  panel        = { 0.085, 0.092, 0.112, 1 },
  row          = { 0.110, 0.118, 0.142, 1 },
  rowHover     = { 0.150, 0.162, 0.195, 1 },
  rowSelected  = { 0.120, 0.250, 0.330, 1 },
  input        = { 0.040, 0.044, 0.056, 1 },
  button       = { 0.125, 0.135, 0.165, 1 },
  buttonActive = { 0.110, 0.230, 0.300, 1 },
  border       = { 0.190, 0.205, 0.245, 1 },
  accent       = { 0.350, 0.780, 0.980, 1 },
  text         = { 0.920, 0.930, 0.950, 1 },
  muted        = { 0.560, 0.590, 0.650, 1 },
  good         = { 0.400, 0.850, 0.450, 1 },
  warn         = { 1.000, 0.700, 0.250, 1 },
  bad          = { 0.950, 0.400, 0.400, 1 },
}

function S.Backdrop(f, bg, border)
  if not f.SetBackdrop then return end
  f:SetBackdrop({ bgFile = S.WHITE, edgeFile = S.WHITE, edgeSize = 1 })
  f:SetBackdropColor(unpack(bg or S.c.bg))
  f:SetBackdropBorderColor(unpack(border or S.c.border))
end

function S.Panel(parent, bg, border)
  local f = CreateFrame("Frame", nil, parent, S.TPL)
  S.Backdrop(f, bg or S.c.panel, border)
  return f
end

function S.Text(parent, size, color, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(S.FONT, size or 12, "")
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, 0.8)
  fs:SetTextColor(unpack(color or S.c.text))
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

function S.Icon(parent, size)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetSize(size, size)
  t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  return t
end

function S.Button(parent, label, width, height, onClick)
  local b = CreateFrame("Button", nil, parent, S.TPL)
  b:SetSize(width or 80, height or 22)
  S.Backdrop(b, S.c.button, S.c.border)
  b.text = S.Text(b, 12, S.c.text, "CENTER")
  b.text:SetPoint("LEFT", 4, 0)
  b.text:SetPoint("RIGHT", -4, 0)
  b.text:SetText(label or "")
  b:SetScript("OnEnter", function(self)
    if self:IsEnabled() then self:SetBackdropBorderColor(unpack(S.c.accent)) end
    if self.tip then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(self.tip, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(unpack(self.active and S.c.accent or S.c.border))
    if self.tip then GameTooltip:Hide() end
  end)
  b:SetScript("OnDisable", function(self) self.text:SetTextColor(unpack(S.c.muted)) end)
  b:SetScript("OnEnable", function(self) self.text:SetTextColor(unpack(S.c.text)) end)
  if onClick then b:SetScript("OnClick", onClick) end
  function b:SetLabel(t) self.text:SetText(t) end
  function b:SetActive(on)
    self.active = on
    self:SetBackdropColor(unpack(on and S.c.buttonActive or S.c.button))
    self:SetBackdropBorderColor(unpack(on and S.c.accent or S.c.border))
  end
  return b
end

function S.Input(parent, width, height)
  local e = CreateFrame("EditBox", nil, parent, S.TPL)
  e:SetSize(width or 80, height or 22)
  S.Backdrop(e, S.c.input, S.c.border)
  e:SetFont(S.FONT, 12, "")
  e:SetTextColor(unpack(S.c.text))
  e:SetTextInsets(6, 6, 0, 0)
  e:SetAutoFocus(false)
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEditFocusGained", function(self)
    self:SetBackdropBorderColor(unpack(S.c.accent))
    self:HighlightText()
  end)
  e:SetScript("OnEditFocusLost", function(self)
    self:SetBackdropBorderColor(unpack(S.c.border))
    self:HighlightText(0, 0)
    if self.onCommit then self.onCommit(self) end
  end)
  return e
end

-- Scrolling list with a fixed pool of rows. buildRow(row) adds widgets to a row
-- and must set row:Update(item). onClick(item, index) runs when a row is clicked.
function S.List(parent, rowHeight, buildRow, onClick)
  local list = CreateFrame("Frame", nil, parent)
  list.rows, list.data, list.offset, list.visible = {}, {}, 0, 0
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(self, delta) self:Scroll(-delta * 3) end)

  local track = list:CreateTexture(nil, "BACKGROUND")
  track:SetColorTexture(unpack(S.c.row))
  track:SetPoint("TOPRIGHT")
  track:SetPoint("BOTTOMRIGHT")
  track:SetWidth(3)
  local thumb = list:CreateTexture(nil, "ARTWORK")
  thumb:SetColorTexture(unpack(S.c.accent))
  thumb:SetWidth(3)

  list.empty = S.Text(list, 12, S.c.muted, "CENTER")
  list.empty:SetPoint("TOP", 0, -20)

  local function RowColor(row)
    local c = S.c.row
    if row.item and row.item == list.selected then c = S.c.rowSelected
    elseif row:IsMouseOver() then c = S.c.rowHover end
    row:SetBackdropColor(unpack(c))
    row:SetBackdropBorderColor(unpack(c))
  end

  function list:Layout()
    local n = math.max(1, math.floor((self:GetHeight() + 1) / rowHeight))
    for i = #self.rows + 1, n do
      local row = CreateFrame("Button", nil, self, S.TPL)
      row:SetHeight(rowHeight - 1)
      row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
      row:SetPoint("RIGHT", self, "RIGHT", -6, 0)
      S.Backdrop(row, S.c.row, S.c.row)
      row:SetScript("OnEnter", function(r)
        RowColor(r)
        if r.OnEnterTip then r:OnEnterTip() end
      end)
      row:SetScript("OnLeave", function(r)
        RowColor(r)
        GameTooltip:Hide()
      end)
      row:SetScript("OnClick", function(r)
        if not r.item then return end
        list.selected = r.item
        list:Refresh()
        if onClick then onClick(r.item, list.offset + r.index) end
      end)
      row.index = i
      buildRow(row)
      self.rows[i] = row
    end
    self.visible = n
    for i = n + 1, #self.rows do self.rows[i]:Hide() end
    self:Scroll(0)
  end

  function list:SetData(data, keepSelection)
    self.data = data or {}
    if not keepSelection then self.selected = nil end
    self:Scroll(0)
  end

  function list:Scroll(delta)
    local maxOffset = math.max(0, #self.data - self.visible)
    self.offset = math.max(0, math.min(self.offset + delta, maxOffset))
    self:Refresh()
  end

  function list:Refresh()
    for i = 1, self.visible do
      local row, item = self.rows[i], self.data[self.offset + i]
      row.item = item
      if item then
        row:Update(item)
        RowColor(row)
        row:Show()
      else
        row:Hide()
      end
    end
    self.empty:SetShown(#self.data == 0 and self.emptyText ~= nil)
    self.empty:SetText(self.emptyText or "")
    local total, vis = #self.data, math.max(1, self.visible)
    if total <= vis then
      thumb:Hide()
    else
      local h = self:GetHeight()
      local th = math.max(16, h * vis / total)
      thumb:SetHeight(th)
      thumb:ClearAllPoints()
      thumb:SetPoint("TOPRIGHT", 0, -(h - th) * self.offset / (total - vis))
      thumb:Show()
    end
  end

  list:SetScript("OnSizeChanged", function(self) self:Layout() end)
  return list
end

-- Small helper: a muted caption with a value next to it.
function S.Stat(parent, label, width)
  local l = S.Text(parent, 11, S.c.muted)
  l:SetText(label)
  l:SetWidth(width or 90)
  local v = S.Text(parent, 12, S.c.text)
  v:SetPoint("LEFT", l, "RIGHT", 4, 0)
  return l, v
end
