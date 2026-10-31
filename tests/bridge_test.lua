vim.opt.rtp:prepend(vim.fn.expand("~/.config/nvim"))
-- Bridge round-trip test: initialize, tools/list, every tool category
-- (display, open_file, async ask_user / run_command), error paths. Offline.
-- vim.ui.select / vim.ui.input are stubbed and answer after a short delay so
-- the async path really goes through the bridge's poll loop.
require("harner").setup({ show_text = { mode = "split" } })
local mcp = require("harner.mcp")
local addr = mcp.server_address()
local bridge = vim.fn.expand("~/.config/nvim/lua/harner/bridge.lua")
local here = vim.fn.expand("~/.config/nvim/lua/harner")
vim.cmd("cd " .. here)

local fails = 0
local function check(cond, msg) if not cond then fails = fails + 1 end; io.stderr:write((cond and "ok   " or "FAIL ") .. msg .. "\n") end

local ui_prompts = {}
vim.ui.select = function(items, opts, cb)
  ui_prompts[#ui_prompts + 1] = opts.prompt
  vim.defer_fn(function()
    if opts.prompt:find("decline", 1, true) then cb("skip") else cb(items[1]) end
  end, 150)
end
vim.ui.input = function(opts, cb)
  ui_prompts[#ui_prompts + 1] = opts.prompt
  vim.defer_fn(function() cb("typed answer") end, 150)
end

local reqs = {
  { jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-06-18", capabilities = {}, clientInfo = { name = "t", version = "0" } } },
  { jsonrpc = "2.0", method = "notifications/initialized" },
  { jsonrpc = "2.0", id = 2, method = "tools/list" },
  { jsonrpc = "2.0", id = 3, method = "tools/call", params = { name = "show_text", arguments = { title = "Hi", content = "line1\nline2", filetype = "lua" } } },
  { jsonrpc = "2.0", id = 4, method = "tools/call", params = { name = "nope", arguments = {} } },
  { jsonrpc = "2.0", id = 5, method = "bogus" },
  { jsonrpc = "2.0", id = 8, method = "tools/call", params = { name = "ask_user", arguments = { question = "Pick one", choices = { "alpha", "beta" } } } },
  { jsonrpc = "2.0", id = 9, method = "tools/call", params = { name = "ask_user", arguments = { question = "Type it" } } },
  { jsonrpc = "2.0", id = 10, method = "tools/call", params = { name = "run_command", arguments = { cmd = "echo 'confirmed'" } } },
  { jsonrpc = "2.0", id = 11, method = "tools/call", params = { name = "run_command", arguments = { cmd = "echo 'decline me'" } } },
  { jsonrpc = "2.0", id = 12, method = "tools/call", params = { name = "run_command", arguments = { cmd = "edit tools.lua" } } },
  { jsonrpc = "2.0", id = 13, method = "tools/call", params = { name = "run_command", arguments = { cmd = "NoSuchCommandHere" } } },
  { jsonrpc = "2.0", id = 14, method = "tools/call", params = { name = "ask_user", arguments = {} } },
  { jsonrpc = "2.0", id = 6, method = "tools/call", params = { name = "open_file", arguments = { path = "mcp.lua", line = 12, end_line = 14 } } },
  { jsonrpc = "2.0", id = 7, method = "tools/call", params = { name = "open_file", arguments = { path = "does/not/exist.lua" } } },
}
local input = {}
for _, r in ipairs(reqs) do input[#input + 1] = vim.json.encode(r) end
local out, err = {}, {}
local done = false
vim.system({ vim.v.progpath, "-l", bridge }, {
  stdin = table.concat(input, "\n") .. "\n",
  env = { HARNER_NVIM = addr },
  stdout = function(_, d) if d then out[#out + 1] = d end end,
  stderr = function(_, d) if d then err[#err + 1] = d end end,
}, function(obj) done = true; io.stderr:write("exit " .. obj.code .. "\n") end)
vim.wait(20000, function() return done end, 50)

local replies = {}
for _, line in ipairs(vim.split(table.concat(out), "\n", { trimempty = true })) do
  local ok, msg = pcall(vim.json.decode, line)
  if ok and msg.id then replies[msg.id] = msg end
end
local function text(id) local r = replies[id]; return r and r.result and r.result.content[1].text or "<none>" end
local function is_err(id) local r = replies[id]; return r and r.result and r.result.isError end

check(done, "bridge exited")
check(replies[1] and replies[1].result.serverInfo ~= nil, "initialize answered")
local names = vim.tbl_map(function(t) return t.name end, replies[2].result.tools)
check(vim.deep_equal(names, { "ask_user", "get_current_buffer", "get_cursor", "get_diagnostics", "get_selection", "list_buffers", "open_file", "run_command", "show_text" }), "tools/list names: " .. table.concat(names, ","))
check(text(3):find("Displayed 2 lines", 1, true) ~= nil and not is_err(3), "show_text: " .. text(3))
check(is_err(4) and text(4):find("unknown tool", 1, true), "unknown tool is an error result")
check(replies[5] and replies[5].error and replies[5].error.code == -32601, "unknown method is a jsonrpc error")

check(text(6) == "Opened mcp.lua, highlighted lines 12-14." and not is_err(6), "open_file: " .. text(6))
local fwin
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w)):match("mcp%.lua$") then fwin = w end
end
check(fwin ~= nil and vim.api.nvim_win_get_cursor(fwin)[1] == 12, "open_file placed the cursor on line 12")
local ns = vim.api.nvim_create_namespace("harner_open_file")
local marks = fwin and vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(fwin), ns, 0, -1, { details = true }) or {}
check(#marks == 1 and marks[1][2] == 11 and marks[1][4].end_row == 14, "open_file highlighted the range")
check(is_err(7) and text(7):find("no such file", 1, true), "open_file missing path is an error: " .. text(7))

check(text(8) == "alpha" and not is_err(8), "ask_user with choices returns the pick: " .. text(8))
check(text(9) == "typed answer" and not is_err(9), "ask_user free-form returns the input: " .. text(9))
check(text(10) == "confirmed" and not is_err(10), "run_command confirmed returns output: " .. text(10))
check(is_err(11) and text(11):find("declined", 1, true), "run_command declined: " .. text(11))
check(text(12):find("no output", 1, true) ~= nil and not is_err(12), "run_command allow-listed edit ran: " .. text(12))
check(is_err(13) and text(13):find("failed", 1, true), "run_command bad command is an error: " .. text(13))
check(is_err(14) and text(14):find("question is required", 1, true), "ask_user without question errors synchronously: " .. text(14))
local confirm_prompts = vim.tbl_filter(function(p) return p:find("wants to run", 1, true) end, ui_prompts)
check(#confirm_prompts == 3, "confirm asked exactly for the three non-allow-listed commands, got " .. #confirm_prompts)
check(require("harner.tools").pending_count() == 0, "no pending calls left")

-- cancel path: a pending ask resolves with an error and poll hands it over
local tools = require("harner.tools")
vim.ui.input = function() end -- never answers
local res = tools.call("ask_user", { question = "stuck?" })
check(type(res) == "table" and res.pending ~= nil and tools.poll(res.pending) == nil, "async call is pending")
tools.cancel_pending("cancelled by the user")
local got = tools.poll(res.pending)
check(got and got.isError and got.content[1].text == "cancelled by the user", "cancel_pending resolves it with an error")
check(tools.poll(res.pending).isError, "poll after collection reports the id as cancelled")

io.stderr:write("STDERR from bridge: " .. table.concat(err) .. "\n")
io.stderr:write(fails == 0 and "ALL OK\n" or (fails .. " FAILED\n"))
vim.cmd("qa!")
