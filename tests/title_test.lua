local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
-- Terminal title (config.title): prefix, format, and format falling back to the
-- default when it errors or returns a non-string. Offline, no runner involved.

require("harner").setup({ title = { enabled = true } })
local cfg = require("harner").config.title
local chat = require("harner.chat")
local c = chat.ensure()
c.state = "idle"

local function title()
  chat.refresh_winbar(c)
  return vim.o.titlestring
end

-- 1. default: "harner <state>", prefix string and function
check(title() == "harner idle", "default title")
cfg.prefix = "dt · "
check(title() == "dt · harner idle", "prefix string")
cfg.prefix = function() return "fn · " end
check(title() == "fn · harner idle", "prefix function")
cfg.prefix = ""

-- 2. format replaces the whole title and gets state + chat; % is escaped
local seen
cfg.format = function(state, ch)
  seen = ch
  return "ℌ proj | " .. state .. " 100%"
end
check(title() == "ℌ proj | idle 100%%", "format result used, % escaped")
check(seen == c, "format receives the chat")
cfg.prefix = "ignored · "
check(title() == "ℌ proj | idle 100%%", "prefix ignored with format")
cfg.prefix = ""

-- 3. a broken format falls back to the default title instead of erroring
cfg.format = function() error("boom") end
local ok = pcall(title)
check(ok, "erroring format does not propagate")
check(vim.o.titlestring == "harner idle", "erroring format falls back")
cfg.format = function() return nil end
check(title() == "harner idle", "nil from format falls back")
cfg.format = function() return 42 end
check(title() == "harner idle", "non-string from format falls back")

-- 4. disabled: titlestring left alone
cfg.format = nil
cfg.enabled = false
vim.o.titlestring = "untouched"
check(title() == "untouched", "disabled leaves titlestring alone")

t.finish()
