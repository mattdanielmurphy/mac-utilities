-- modules/tweaks.lua
-- Live tweaks: an app's feel knobs (timings, fade curves, sizes, colours) live in one
-- tweaks.json that Matt edits by hand or with the Tweaks panel (⌃⌥⌘T, modules/tweaks_panel.lua).
-- A save applies at once: values are read on use, and a reload only swaps values
-- (no restarts, no re-registering, no side effects). Bad JSON keeps the last good values.
--
--   local tweaks = require("modules.tweaks")
--   local T = tweaks.open{
--     app = "Reload indicator",                       -- name shown in the panel
--     file = tweaks.dir .. "/reload_indicator.json",  -- Hammerspoon modules keep theirs here
--     knobs = {
--       ["fade.hold"] = { 1.2, min = 0, max = 5, step = 0.1, note = "Seconds fully visible" },
--       ["look.color"] = { "#262626", note = "Light-mode colour" },
--     },
--     onChange = function() ... end,                  -- optional
--   }
--   T("fade.hold")  --> 1.2, or whatever the file says now
--
-- File format (shared with hud-kit Tweaks.swift):
--   { "app": "...", "tweaks": { "fade.hold": { "value": 1.2, "default": 1.2, "min": 0, ... } } }
-- The part of a key before the first dot is its group in the panel. Missing knobs are
-- seeded into the file; value/min/max/step/note in the file win, default always comes from code.
-- Every tweaks file is listed in ~/.hammerspoon/tweaks_registry.json for the panel.
--
-- The panel colours knobs that differ from their default, and can:
--   Apply: rewrites the knob declarations in the app's code (Lua or Swift), commits and
--     pushes that file (M.saveDefaults), then runs the app's build command, if it has one in
--     ~/.hammerspoon/tweaks_apps.json, so the new values are how the app ships from now on.
--   Follow focus: the panel shows the focused app's tweaks (tweaks_apps.json "focus" bundle
--     IDs, or a matching app name) until Matt pins another app (M.appsForFocus).
--   Finding new knobs: `bin/tweaks scan` lists literal feel values in modules (no AI),
--     `bin/tweaks prune` has Sonnet keep/drop and name them, `bin/tweaks report` shows the
--     keepers for an agent to wire up. Decisions live in tweaks/candidates/ and stick.
--   Presets: named value sets in ~/Library/Application Support/MDMA/tweak-presets/<app>.json,
--     outside every repo so switching never dirties git (M.savePreset / loadPreset).

local M = {}

local HOME = os.getenv("HOME")
M.dir = HOME .. "/.hammerspoon/tweaks"
M.registry = HOME .. "/.hammerspoon/tweaks_registry.json"

local FIELD_ORDER = { "value", "default", "min", "max", "step", "note", "choices" }

-- ── Pure functions (no hs.*), tested by tests/tweaks_test.lua ─────────────────

local function jsonString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\t"] = "\\t", ["\r"] = "\\r" }
    return map[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local sortedKeys

local function jsonLeaf(v)
  local t = type(v)
  if t == "string" then return jsonString(v) end
  if t == "table" then -- a flat map, e.g. a chips knob's choices {value: label}
    local parts = {}
    for _, k in ipairs(sortedKeys(v)) do parts[#parts + 1] = jsonString(tostring(k)) .. ": " .. jsonLeaf(v[k]) end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  if t == "boolean" then return tostring(v) end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    return string.format("%.10g", v)
  end
  return "null"
end

function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Stable, readable JSON: keys sorted, each knob on one line, fields in FIELD_ORDER.
function M.encode(doc)
  local lines = { "{", '  "app": ' .. jsonString(doc.app or "") .. ",", '  "tweaks": {' }
  local keys = sortedKeys(doc.tweaks or {})
  for i, key in ipairs(keys) do
    local knob, parts = doc.tweaks[key], {}
    for _, f in ipairs(FIELD_ORDER) do
      if knob[f] ~= nil then parts[#parts + 1] = jsonString(f) .. ": " .. jsonLeaf(knob[f]) end
    end
    lines[#lines + 1] = "    " .. jsonString(key) .. ": { " .. table.concat(parts, ", ") .. " }"
      .. (i < #keys and "," or "")
  end
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n") .. "\n"
end

-- Merges the code's knob declarations into what the file holds.
-- Returns values (key -> value) and the doc to write back, plus whether it changed.
function M.merge(doc, app, knobs)
  doc = type(doc) == "table" and doc or {}
  local tweaks = type(doc.tweaks) == "table" and doc.tweaks or {}
  local out, values, changed = { app = app, tweaks = {} }, {}, doc.app ~= app or doc.tweaks == nil
  -- Knobs the file has but the code no longer declares are kept (they may belong to an older build).
  for key, knob in pairs(tweaks) do
    if type(knob) == "table" then out.tweaks[key] = knob end
  end
  for key, decl in pairs(knobs) do
    local default = decl[1]
    local knob = out.tweaks[key]
    if not knob then
      knob = {}
      out.tweaks[key] = knob
      changed = true
    end
    for _, f in ipairs({ "min", "max", "step", "note", "choices" }) do
      if knob[f] == nil and decl[f] ~= nil then knob[f] = decl[f]; changed = true end
    end
    if knob.default ~= default then knob.default = default; changed = true end
    if type(knob.value) ~= type(default) then knob.value = default; changed = true end
    values[key] = knob.value
  end
  return values, out, changed
end

-- True when a knob's value is not its default (numbers within a hair, colours ignore case).
function M.differs(value, default)
  if default == nil then return false end
  if type(value) == "number" and type(default) == "number" then
    return math.abs(value - default) > 1e-9 * math.max(1, math.abs(default))
  end
  if type(value) == "string" and type(default) == "string" then return value:lower() ~= default:lower() end
  return value ~= default
end

-- A value as a source literal; the same text is valid Lua and Swift.
function M.literal(v)
  if type(v) == "string" then return jsonString(v) end
  return jsonLeaf(v)
end

local LITERALS = { '"[^"\n]*"', "true", "false", "%-?%d+%.?%d*[eE]?[%-+]?%d*", "%-?%.%d+" }

-- Rewrites a knob's default where the code declares it:
--   Lua    ["fade.hold"] = { 1.2, ...
--   Swift  .number("fade.loudWeight", 1.8, ...
-- Returns the new source and true, or the source unchanged and false.
function M.rewriteDefault(src, key, value)
  local k = key:gsub("%p", "%%%0")
  local heads = { '(%["' .. k .. '"%]%s*=%s*{%s*)', '(%.%a+%(%s*"' .. k .. '"%s*,%s*)' }
  for _, head in ipairs(heads) do
    for _, lit in ipairs(LITERALS) do
      local out, n = src:gsub(head .. lit, function(h)
        return h .. M.literal(value)
      end, 1)
      if n > 0 then return out, true end
    end
  end
  return src, false
end

-- ── File + registry I/O ───────────────────────────────────────────────────────

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- Write via a temp file + rename, so a reader never sees half a file.
function M.writeFile(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(text)
  f:close()
  return os.rename(tmp, path)
end

function M.readDoc(path)
  local text = readFile(path)
  if not text then return nil, nil end
  local ok, doc = pcall(hs.json.decode, text)
  if not ok or type(doc) ~= "table" then return nil, text, "bad JSON in " .. path end
  return doc, text
end

-- Registry: { "apps": { "<app>": "<absolute path to its tweaks.json>" } }
function M.register(app, file)
  local doc = M.readDoc(M.registry) or {}
  doc.apps = doc.apps or {}
  if doc.apps[app] == file then return end
  doc.apps[app] = file
  M.writeFile(M.registry, hs.json.encode(doc, true) .. "\n")
end

function M.apps()
  local doc = M.readDoc(M.registry) or {}
  return doc.apps or {}
end

-- Sets one knob's value in a file (used by the panel). Owners pick it up through their watchers.
function M.setValue(file, key, value)
  local doc = M.readDoc(file)
  if not doc or not doc.tweaks or not doc.tweaks[key] then return false end
  doc.tweaks[key].value = value
  return M.writeFile(file, M.encode(doc))
end

-- Puts every knob in a file back to its default.
function M.resetAll(file)
  local doc = M.readDoc(file)
  if not doc or not doc.tweaks then return false end
  for _, knob in pairs(doc.tweaks) do
    if knob.default ~= nil then knob.value = knob.default end
  end
  return M.writeFile(file, M.encode(doc))
end

-- ── Save as defaults ──────────────────────────────────────────────────────────
-- Defaults live in code (the knob declarations), so the official build ships them.
-- Saving rewrites those declarations in the app's repo and commits the file.

M._decls = M._decls or {} -- tweaks file -> live knob declarations of a Lua module

local function sh(cmd)
  local p = io.popen(cmd .. " </dev/null 2>/dev/null")
  local out = p:read("*a")
  local ok = p:close()
  return out, ok
end

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- The source file that declares a tweaks file's knobs: a .lua or .swift file in the same git
-- repo that names the tweaks file and declares every given key.
function M.findSource(file, keys)
  local dir = file:match("^(.*)/[^/]+$")
  local root = (sh("git -c core.fsmonitor=false -C " .. q(dir) .. " rev-parse --show-toplevel")):gsub("%s+$", "")
  if root == "" then return nil, "tweaks file isn't in a git repo" end
  local base = file:match("([^/]+)$")
  local list = sh("git -c core.fsmonitor=false -C " .. q(root) .. " ls-files '*.lua' '*.swift'")
  for rel in list:gmatch("[^\n]+") do
    if not rel:match("^tests/") and not rel:match("^vendor/") and rel ~= "modules/tweaks.lua" and not rel:match("Tweaks%.swift$") then
      local path = root .. "/" .. rel
      local src = readFile(path)
      if src and src:find(base, 1, true) then
        local all = true
        for _, key in ipairs(keys) do
          local _, ok = M.rewriteDefault(src, key, 0)
          if not ok then all = false break end
        end
        if all then return path, root end
      end
    end
  end
  return nil, "couldn't find the code that declares these knobs"
end

-- Makes every changed knob's current value its default, in code and in the file.
-- Returns a short message for the panel.
function M.saveDefaults(file, willBuild)
  local doc = M.readDoc(file)
  if not doc or not doc.tweaks then return "Couldn't read the tweaks file." end
  local keys = {}
  for _, key in ipairs(sortedKeys(doc.tweaks)) do
    local knob = doc.tweaks[key]
    if M.differs(knob.value, knob.default) then keys[#keys + 1] = key end
  end
  if #keys == 0 then return "Nothing to save: every knob is at its default." end

  local path, root = M.findSource(file, keys)
  if not path then
    -- No code declares these knobs: the tweaks file is its own source (e.g. the explainer reels), so its
    -- defaults are what ships. Commit just that file.
    local tracked = select(2, sh("git -c core.fsmonitor=false -C " .. q(file:match("^(.*)/[^/]+$")) .. " ls-files --error-unmatch " .. q(file)))
    local froot = M.repoRoot(file)
    if not tracked or not froot then return "Not saved: " .. root .. "." end
    for _, key in ipairs(keys) do doc.tweaks[key].default = doc.tweaks[key].value end
    if not M.writeFile(file, M.encode(doc)) then return "Not saved: couldn't write the tweaks file." end
    local rel = file:sub(#froot + 2)
    local what = #keys == 1 and keys[1] or (#keys .. " knobs")
    local subject = "Tweaks: new defaults for " .. (doc.app or "app") .. " (" .. table.concat(keys, ", ") .. ")"
    hs.task.new("/bin/sh", nil, { "-c", "cd " .. q(froot) .. " && git -c core.fsmonitor=false add -- " .. q(rel)
      .. " && git commit -q -m " .. q(subject) .. " -- " .. q(rel) .. " && git push -q" }):start()
    return "Saved " .. what .. " as default in " .. rel .. ". Committed."
  end
  local rel = path:sub(#root + 2)
  local wasClean = select(2, sh("git -c core.fsmonitor=false -C " .. q(root) .. " diff --quiet -- " .. q(rel)))
  local src = readFile(path)
  for _, key in ipairs(keys) do src = M.rewriteDefault(src, key, doc.tweaks[key].value) end
  if not M.writeFile(path, src) then return "Not saved: couldn't write " .. rel .. "." end

  local decls = M._decls[file]
  for _, key in ipairs(keys) do
    doc.tweaks[key].default = doc.tweaks[key].value
    if decls and decls[key] then decls[key][1] = doc.tweaks[key].value end
  end
  M.writeFile(file, M.encode(doc))

  local what = #keys == 1 and keys[1] or (#keys .. " knobs")
  local msg = "Saved " .. what .. " as default in " .. rel .. "."
  if wasClean then
    local subject = "Tweaks: new defaults for " .. (doc.app or "app") .. " (" .. table.concat(keys, ", ") .. ")"
    hs.task.new("/bin/sh", nil, { "-c", "cd " .. q(root) .. " && git -c core.fsmonitor=false add -- " .. q(rel)
      .. " && git commit -q -m " .. q(subject) .. " -- " .. q(rel) .. " && git push -q" }):start()
    msg = msg .. " Committed."
  else
    msg = msg .. " Not committed: that file had other edits."
  end
  if path:match("%.swift$") and not willBuild then msg = msg .. " Rebuild the app to ship it (until then it still shows as changed)." end
  return msg
end

-- ── Focus follow ──────────────────────────────────────────────────────────────
-- Which registered apps to show for the focused app: those whose tweaks_apps.json entry lists
-- its bundle ID, plus one whose panel name is the app's own name. Sorted, may be empty.
function M.appsForFocus(meta, names, bundleID, appName)
  local out, seen = {}, {}
  local lname = appName and appName:lower()
  for _, name in ipairs(names) do
    local entry = meta and meta[name]
    local hit = lname and name:lower() == lname
    if not hit and type(entry) == "table" and type(entry.focus) == "table" then
      for _, id in ipairs(entry.focus) do
        if id == bundleID then hit = true break end
      end
    end
    if hit and not seen[name] then seen[name] = true out[#out + 1] = name end
  end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

-- The git repo root a tweaks file lives in, or nil.
function M.repoRoot(file)
  local dir = file:match("^(.*)/[^/]+$")
  local root = (sh("git -c core.fsmonitor=false -C " .. q(dir) .. " rev-parse --show-toplevel")):gsub("%s+$", "")
  return root ~= "" and root or nil
end

-- ── Presets ───────────────────────────────────────────────────────────────────
-- Named sets of values, kept outside every repo so switching never dirties git.
-- One file per app: { "app": "...", "presets": { "<name>": { "<key>": value } } }

M.presetDir = HOME .. "/Library/Application Support/MDMA/tweak-presets"

local function presetFile(app)
  return M.presetDir .. "/" .. app:gsub("[^%w%-]+", "_") .. ".json"
end

function M.presets(app)
  local doc = M.readDoc(presetFile(app))
  return (doc and type(doc.presets) == "table") and doc.presets or {}
end

local function writePresets(app, presets)
  hs.fs.mkdir(HOME .. "/Library/Application Support/MDMA")
  hs.fs.mkdir(M.presetDir)
  local doc = { app = app, presets = presets }
  return M.writeFile(presetFile(app), hs.json.encode(doc, true) .. "\n")
end

function M.savePreset(file, name)
  local doc = M.readDoc(file)
  if not doc or not doc.tweaks then return false end
  local values = {}
  for key, knob in pairs(doc.tweaks) do values[key] = knob.value end
  local presets = M.presets(doc.app)
  presets[name] = values
  return writePresets(doc.app, presets)
end

function M.deletePreset(app, name)
  local presets = M.presets(app)
  presets[name] = nil
  return writePresets(app, presets)
end

-- Sets every knob the preset knows; knobs added since keep their value.
function M.loadPreset(file, name)
  local doc = M.readDoc(file)
  if not doc or not doc.tweaks then return false end
  local values = M.presets(doc.app)[name]
  if not values then return false end
  for key, v in pairs(values) do
    local knob = doc.tweaks[key]
    if knob and type(knob.value) == type(v) then knob.value = v end
  end
  return M.writeFile(file, M.encode(doc))
end

-- ── Live handle ───────────────────────────────────────────────────────────────

M._watchers = M._watchers or {}

function M.open(opts)
  local app, file, knobs = opts.app, opts.file, opts.knobs or {}
  M._decls[file] = knobs
  hs.fs.mkdir(file:match("^(.*)/[^/]+$"))

  local values, lastText = {}, nil
  local function load()
    local doc, text, err = M.readDoc(file)
    if err then
      print("⚠️ tweaks: " .. err .. " (keeping last good values)")
      return false
    end
    if text ~= nil and text == lastText then return false end
    local merged, out, changed = M.merge(doc, app, knobs)
    values = merged
    if changed then
      lastText = M.encode(out)
      M.writeFile(file, lastText)
    else
      lastText = text
    end
    return true
  end
  load()
  M.register(app, file)

  -- Watch the folder, not the file: editors often save by replacing the file.
  if M._watchers[file] then M._watchers[file]:stop() end
  M._watchers[file] = hs.pathwatcher.new(file:match("^(.*)/[^/]+$"), function(paths)
    for _, p in ipairs(paths) do
      if p == file then
        if load() and opts.onChange then pcall(opts.onChange) end
        return
      end
    end
  end):start()

  return setmetatable({ file = file, app = app }, {
    __call = function(_, key)
      local v = values[key]
      if v == nil and knobs[key] then v = knobs[key][1] end
      return v
    end,
  })
end

return M
