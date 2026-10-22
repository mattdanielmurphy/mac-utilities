-- Wrap a non-empty editable Accessibility selection when an opening delimiter is typed.
-- Unsupported controls and failed Accessibility operations pass the original key through.

local M = {
  id = "selection_wrap",
  name = "Selection Wrapping",
  defaultEnabled = false
}

_G.activeWatchers = _G.activeWatchers or {}
local activeWatchers = _G.activeWatchers

local pairsByOpening = {
  ["`"] = "`",
  ["'"] = "'",
  ['"'] = '"',
  ["("] = ")",
  ["["] = "]",
  ["{"] = "}"
}

local function utf16Length(value)
  local length = 0
  for _, codepoint in utf8.codes(value) do
    length = length + (codepoint > 0xFFFF and 2 or 1)
  end
  return length
end

local function utf16Slice(value, startOffset, length)
  local finishOffset = startOffset + length
  local offset = 0
  local parts = {}

  for _, codepoint in utf8.codes(value) do
    local units = codepoint > 0xFFFF and 2 or 1
    local nextOffset = offset + units
    if offset < finishOffset and nextOffset > startOffset then
      if offset < startOffset or nextOffset > finishOffset then return nil end
      parts[#parts + 1] = utf8.char(codepoint)
    end
    offset = nextOffset
  end

  if finishOffset > offset then return nil end
  return table.concat(parts)
end

local function safeAttribute(element, name)
  local ok, value = pcall(function()
    return element:attributeValue(name)
  end)
  if ok then return value end
  return nil
end

local function isPlainTextKey(event)
  local flags = event:getFlags() or {}
  return not flags.cmd and not flags.alt and not flags.ctrl and not flags.fn
end

local function wrapSelection(opening, closing)
  if hs.eventtap.isSecureInputEnabled() then return false end

  local system = hs.axuielement.systemWideElement()
  local element = safeAttribute(system, "AXFocusedUIElement")
  if not element then return false end

  local role = safeAttribute(element, "AXRole")
  local subrole = safeAttribute(element, "AXSubrole")
  if role == "AXSecureTextField" or subrole == "AXSecureTextField" then return false end

  local selected = safeAttribute(element, "AXSelectedText")
  local range = safeAttribute(element, "AXSelectedTextRange")
  local value = safeAttribute(element, "AXValue")
  if type(selected) ~= "string" or selected == "" or type(range) ~= "table" or type(value) ~= "string" then return false end
  if type(range.location) ~= "number" or type(range.length) ~= "number"
      or range.location < 0 or range.length <= 0
      or range.location % 1 ~= 0 or range.length % 1 ~= 0 then return false end
  if range.length ~= utf16Length(selected) then return false end

  local prefix = utf16Slice(value, 0, range.location)
  local valueSelection = utf16Slice(value, range.location, range.length)
  local suffix = utf16Slice(value, range.location + range.length, utf16Length(value) - range.location - range.length)
  if prefix == nil or valueSelection ~= selected or suffix == nil then return false end

  local okText, canSetText = pcall(function() return element:isAttributeSettable("AXSelectedText") end)
  local okRange, canSetRange = pcall(function() return element:isAttributeSettable("AXSelectedTextRange") end)
  if not okText or not okRange then return false end
  if canSetText ~= true or canSetRange ~= true then return false end

  local wrapped = opening .. selected .. closing
  local expectedValue = prefix .. wrapped .. suffix
  local expectedRange = {
    location = range.location + utf16Length(opening),
    length = utf16Length(selected)
  }

  -- AXSelectedText replaces the active selection and some editors collapse the
  -- selection as part of that write. Do not interpret the collapsed selection
  -- as a failed text write or try to roll it back at the new caret position.
  local writeCallOK, writeResult = pcall(function()
    return element:setAttributeValue("AXSelectedText", wrapped)
  end)

  local valueReadOK, updatedValue = pcall(function()
    return element:attributeValue("AXValue")
  end)
  if not valueReadOK or type(updatedValue) ~= "string" then
    -- The write may have taken effect despite an AX error; swallowing avoids
    -- delivering a second delimiter into a potentially modified field.
    return writeCallOK and writeResult ~= nil
  end
  if updatedValue == value then return false end

  -- Once the value changed, always consume the physical key. Further AX errors
  -- must not make the application apply the same delimiter a second time.
  if updatedValue ~= expectedValue then return true end

  local rangeWriteOK, rangeWriteResult = pcall(function()
    return element:setAttributeValue("AXSelectedTextRange", expectedRange)
  end)
  if not rangeWriteOK or not rangeWriteResult then return true end

  local verifyOK, finalValue, finalSelection, finalRange = pcall(function()
    return element:attributeValue("AXValue"),
      element:attributeValue("AXSelectedText"),
      element:attributeValue("AXSelectedTextRange")
  end)

  local verified = verifyOK and finalValue == expectedValue and finalSelection == selected
      and type(finalRange) == "table" and finalRange.location == expectedRange.location
      and finalRange.length == expectedRange.length
  -- The second return value is internal verification status. The first stays
  -- true after a mutation so the app cannot apply the physical key twice.
  return true, verified
end

function M.start()
  M.stop()

  activeWatchers.selectionWrapTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if not isPlainTextKey(event) then return false end
    if event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) == 1 then return false end

    local opening = event:getCharacters(true)
    local closing = opening and pairsByOpening[opening]
    if not closing then return false end

    if wrapSelection(opening, closing) then return true end
    return false
  end)

  if activeWatchers.selectionWrapTap then activeWatchers.selectionWrapTap:start() end
end

function M.stop()
  if activeWatchers.selectionWrapTap then
    activeWatchers.selectionWrapTap:stop()
    activeWatchers.selectionWrapTap = nil
  end
end

return M
