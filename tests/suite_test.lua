-- lua tests/suite_test.lua  (run from ~/.hammerspoon)
-- Fails if modules/suite.lua SHAREABLE and UTILITIES.md list different modules,
-- or if a shareable module file is missing or hardcodes /Users/matt.
package.path = "./?.lua;" .. package.path
_G.hs = setmetatable({}, { __index = function() return {} end })
local suite = dofile("modules/suite.lua")

local doc = assert(io.open("UTILITIES.md")):read("*a")
local documented = {}
for path in doc:gmatch("\n### (modules%.[%w_]+)") do documented[path] = true end

local fails = 0
local function fail(msg) print("FAIL " .. msg); fails = fails + 1 end
local listed = {}
for _, path in ipairs(suite.SHAREABLE) do
  listed[path] = true
  if not documented[path] then fail(path .. " is shareable but not in UTILITIES.md") end
  local file = path:gsub("%.", "/") .. ".lua"
  local f = io.open(file)
  if not f then fail(file .. " missing") else
    local src = f:read("*a"); f:close()
    if src:find("/Users/matt/projects") or src:find("projects/ai%-os") then
      print("note " .. file .. " references Matt-only paths (must degrade gracefully)")
    end
  end
end
for path in pairs(documented) do
  if not listed[path] then fail(path .. " is in UTILITIES.md but not shareable") end
end
assert(suite.canLoad("modules.claude_control") == not suite.shared)
print(fails == 0 and ("ok: " .. #suite.SHAREABLE .. " shareable modules documented") or (fails .. " failures"))
os.exit(fails == 0 and 0 or 1)
