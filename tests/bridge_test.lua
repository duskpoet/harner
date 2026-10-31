vim.opt.rtp:prepend(vim.fn.expand("~/.config/nvim"))
-- Bridge round-trip test: initialize, tools/list, every tool category
-- (display, open_file, edit_file / write_file / save_file, async ask_user /
-- run_command), error paths. Offline.
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

-- fixtures for edit_file / write_file / save_file
local tmp = vim.fn.tempname() .. "-harner-edit"
vim.fn.mkdir(tmp, "p")
local edit_path = tmp .. "/edit.lua"
vim.fn.writefile({
  "local function greet(name)",
  "\tif name == \"\" then",
  "\t\treturn \"hello\"",
  "\tend",
  "\treturn \"hello \" .. name",
  "end",
  "",
  "local x = 1",
  "local x = 1",
  "",
  "\t\tdeep = true",
}, edit_path)
-- a second file, already open in a buffer, for write_file through a loaded buffer
local other_path = tmp .. "/other.lua"
vim.fn.writefile({ "one", "two", "three" }, other_path)
local obuf = vim.fn.bufadd(other_path)
vim.fn.bufload(obuf)

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
  { jsonrpc = "2.0", id = 20, method = "tools/call", params = { name = "edit_file", arguments = { path = edit_path, old_str = "\t\treturn \"hello\"\n", new_str = "\t\treturn \"hi\"\n" } } },
  { jsonrpc = "2.0", id = 21, method = "tools/call", params = { name = "edit_file", arguments = { path = edit_path, old_str = "greet(name)", new_str = "greet(who)" } } },
  { jsonrpc = "2.0", id = 22, method = "tools/call", params = { name = "edit_file", arguments = { path = edit_path, old_str = "    return \"hello \" .. name", new_str = "    local out = \"hello \" .. name\n        .. \"!\"\n    return out" } } },
  { jsonrpc = "2.0", id = 23, method = "tools/call", params = { name = "edit_file", arguments = { path = edit_path, old_str = "local x = 1", new_str = "local y = 2" } } },
  { jsonrpc = "2.0", id = 24, method = "tools/call", params = { name = "edit_file", arguments = { path = edit_path, old_str = "local x = 1", new_str = "local y = 2", replace_all = true } } },
  { jsonrpc = "2.0", id = 25, method = "tools/call", params = { name = "edit_file", arguments = { path = edit_path, old_str = "nope nope", new_str = "x" } } },
  { jsonrpc = "2.0", id = 26, method = "tools/call", params = { name = "edit_file", arguments = { path = tmp .. "/missing.lua", old_str = "a", new_str = "b" } } },
  { jsonrpc = "2.0", id = 34, method = "tools/call", params = { name = "edit_file", arguments = { path = edit_path, old_str = "   ", new_str = "x", replace_all = true } } },
  { jsonrpc = "2.0", id = 35, method = "tools/call", params = { name = "edit_file", arguments = { path = edit_path, old_str = "\n        deep = true", new_str = "\n        deep = false\n            more = 1" } } },
  { jsonrpc = "2.0", id = 6, method = "tools/call", params = { name = "open_file", arguments = { path = "mcp.lua", line = 12, end_line = 14 } } },
  { jsonrpc = "2.0", id = 7, method = "tools/call", params = { name = "open_file", arguments = { path = "does/not/exist.lua" } } },
  { jsonrpc = "2.0", id = 27, method = "tools/call", params = { name = "save_file", arguments = { path = edit_path } } },
  { jsonrpc = "2.0", id = 28, method = "tools/call", params = { name = "write_file", arguments = { path = tmp .. "/new.txt", content = "a\nb\n" } } },
  { jsonrpc = "2.0", id = 29, method = "tools/call", params = { name = "write_file", arguments = { path = tmp .. "/decline-me.txt", content = "x" } } },
  { jsonrpc = "2.0", id = 30, method = "tools/call", params = { name = "write_file", arguments = { path = tmp .. "/sub/dir/deep.txt", content = "deep" } } },
  { jsonrpc = "2.0", id = 31, method = "tools/call", params = { name = "write_file", arguments = { path = tmp .. "/sub/dir/deep.txt", content = "deep", create_dirs = true } } },
  { jsonrpc = "2.0", id = 32, method = "tools/call", params = { name = "save_file", arguments = { path = tmp .. "/new.txt" } } },
  { jsonrpc = "2.0", id = 33, method = "tools/call", params = { name = "write_file", arguments = { path = other_path, content = "-- gone\n" } } },
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
check(vim.deep_equal(names, { "ask_user", "edit_file", "get_current_buffer", "get_cursor", "get_diagnostics", "get_selection", "list_buffers", "open_file", "run_command", "save_file", "show_text", "write_file" }), "tools/list names: " .. table.concat(names, ","))
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

-- edit_file / save_file / write_file
local ebuf = vim.fn.bufnr(edit_path)
check(ebuf > 0 and vim.api.nvim_buf_is_loaded(ebuf) and vim.bo[ebuf].buflisted, "edit_file loaded the file into a listed buffer")
local disk = vim.fn.readfile(edit_path)
check(text(20):find("replaced 1 occurrence (now lines 3-3, shown in the editor)", 1, true) ~= nil and not is_err(20), "edit_file exact multi-line: " .. text(20))
check(text(21):find("now lines 1-1", 1, true) ~= nil and not is_err(21), "edit_file partial-line match: " .. text(21))
check(disk[1] == "local function greet(who)" and disk[3] == "\t\treturn \"hi\"", "exact edits landed: " .. disk[1] .. " | " .. disk[3])
check(text(22):find("ignoring indentation", 1, true) ~= nil and not is_err(22), "edit_file indentation fallback reported: " .. text(22))
check(vim.deep_equal({ disk[5], disk[6], disk[7] }, { "\tlocal out = \"hello \" .. name", "\t\t.. \"!\"", "\treturn out" }), "indentation fallback re-indented with tabs: " .. vim.inspect({ disk[5], disk[6], disk[7] }))
check(is_err(23) and text(23):find("matches 2 places", 1, true), "edit_file ambiguous old_str errors: " .. text(23))
check(text(24):find("replaced 2 occurrences", 1, true) ~= nil and not is_err(24), "edit_file replace_all: " .. text(24))
check(disk[10] == "local y = 2" and disk[11] == "local y = 2", "replace_all changed both lines")
check(is_err(25) and text(25):find("not found", 1, true), "edit_file missing old_str errors: " .. text(25))
check(is_err(26) and text(26):find("no such file", 1, true), "edit_file missing file errors: " .. text(26))
check(is_err(34) and text(34):find("not found", 1, true), "edit_file whitespace-only old_str is not found: " .. text(34))
check(not is_err(35) and disk[13] == "\t\tdeep = false" and disk[14] == "\t\t\tmore = 1", "indentation fallback with a leading blank line keeps the base indent: " .. vim.inspect({ disk[13], disk[14] }))
check(text(35):find("now lines 12-14, shown in the editor", 1, true) ~= nil, "edit_file reports the shown range: " .. text(35))
local ewin
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_buf(w) == ebuf then ewin = w end
end
check(ewin ~= nil and vim.api.nvim_win_get_cursor(ewin)[1] == 12, "edit_file showed the edited buffer with the cursor on the change")
local emarks = vim.api.nvim_buf_get_extmarks(ebuf, ns, 0, -1, { details = true })
check(#emarks == 1 and emarks[1][2] == 11 and emarks[1][4].end_row == 14, "edit_file highlighted the edited lines")
check(fwin ~= ewin, "open_file split instead of replacing the modified edit buffer")
check(text(27):find("^Saved .*%(14 lines%)") ~= nil and not is_err(27), "save_file wrote the buffer: " .. text(27))
check(text(28):find("Wrote", 1, true) ~= nil and vim.deep_equal(vim.fn.readfile(tmp .. "/new.txt"), { "a", "b" }), "write_file created new.txt: " .. text(28))
check(is_err(29) and text(29):find("declined", 1, true) and vim.uv.fs_stat(tmp .. "/decline-me.txt") == nil, "write_file declined leaves no file: " .. text(29))
check(is_err(30) and text(30):find("directory does not exist", 1, true), "write_file missing dir errors without create_dirs: " .. text(30))
check(not is_err(31) and vim.deep_equal(vim.fn.readfile(tmp .. "/sub/dir/deep.txt"), { "deep" }), "write_file create_dirs: " .. text(31))
check(is_err(32) and text(32):find("not open", 1, true), "save_file on a file without a buffer errors: " .. text(32))
check(not is_err(33) and vim.deep_equal(vim.fn.readfile(other_path), { "-- gone" }) and vim.deep_equal(vim.api.nvim_buf_get_lines(obuf, 0, -1, false), { "-- gone" }) and not vim.bo[obuf].modified, "write_file through a loaded buffer syncs buffer and disk: " .. text(33))
local write_prompts = vim.tbl_filter(function(p) return p:find("wants to write", 1, true) end, ui_prompts)
local save_prompts = vim.tbl_filter(function(p) return p:find("wants to save", 1, true) end, ui_prompts)
check(#write_prompts == 4 and #save_prompts == 1, "confirm asked for 4 writes and 1 save, got " .. #write_prompts .. "/" .. #save_prompts)
vim.fn.delete(tmp, "rf")

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
