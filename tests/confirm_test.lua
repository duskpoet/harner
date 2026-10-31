local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
vim.o.columns = 120; vim.o.lines = 40
-- Offline, in-process: the confirm float (full text, keys), per-chat grants
-- from its `a` key, save_file with several paths, cancel closing an open
-- confirm, and edit_file / open_file reusing windows instead of splitting.
require("harner").setup()
local tools = require("harner.tools")
local confirm = require("harner.confirm")
local function keys(s) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "x", false) end
local function floats()
  return vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())
end
local function normal_wins()
  return #vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative == "" end, vim.api.nvim_list_wins())
end
local function text(res) return res and res.content[1].text end
-- an async call: answer its confirm with `key` and return the result
local function call(name, args, key)
  local r = tools.call(name, args)
  if r.pending == nil then return r end
  if key then keys(key) end
  return tools.poll(r.pending)
end

-- 1. the float shows the whole command, wrapped, and its keys
local long = "Git log --oneline --decorate --graph --all --since='2 weeks ago' -- lua/harner/tools.lua lua/harner/confirm.lua lua/harner/chat.lua"
local got
confirm.ask({ title = "harner: Claude wants to run", body = { ":" .. long }, filetype = "vim", yes = "run", always = "always" }, function(c) got = c end)
local fw = floats()[1]
check(fw ~= nil and vim.api.nvim_get_current_win() == fw, "confirm float opened and has focus")
local fbuf = vim.api.nvim_win_get_buf(fw)
check(vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)[1] == ":" .. long, "float body holds the full command")
local cfg = vim.api.nvim_win_get_config(fw)
check(vim.wo[fw].wrap and vim.api.nvim_win_get_height(fw) >= 2 and cfg.width <= vim.o.columns - 8, "long command wraps inside the screen (height " .. vim.api.nvim_win_get_height(fw) .. ")")
local footer = table.concat(vim.tbl_map(function(c) return c[1] end, cfg.footer or {}))
check(footer:find("y run", 1, true) and footer:find("a always", 1, true) and footer:find("n skip", 1, true), "footer lists the keys: " .. footer)
keys("a")
check(got == "always" and #floats() == 0, "a answers always and closes the float")
confirm.ask({ title = "x", body = { "y" }, yes = "ok" }, function(c) got = c end)
keys("<Esc>")
check(got == "no" and #floats() == 0, "<Esc> declines")
confirm.ask({ title = "x", body = { "y" }, yes = "ok" }, function(c) got = c end)
keys("<CR>")
check(got == "yes", "<CR> approves")

-- 2. run_command: `a` grants exactly that command for the chat
local r = call("run_command", { cmd = "echo 'granted'" }, "a")
check(text(r) == "granted" and not r.isError, "run_command approved with a: " .. tostring(text(r)))
r = tools.call("run_command", { cmd = "echo 'granted'" })
check(r.pending == nil and #floats() == 0 and text(r) == "granted", "same command runs without asking, result returned directly")
r = tools.call("run_command", { cmd = "echo 'other'" })
check(#floats() == 1, "a different command still asks")
keys("n")
check(tools.poll(r.pending).isError, "declined with n")

-- 3. writes: save_file with several paths confirms once; `a` stops later write prompts
local tmp = vim.fn.tempname() .. "-harner-confirm"
vim.fn.mkdir(tmp, "p")
local files = {}
for i, n in ipairs({ "a.lua", "b.lua", "c.lua", "u.lua" }) do
  files[i] = tmp .. "/" .. n
  vim.fn.writefile({ "local v = " .. i }, files[i])
end
-- the user's own file, with unsaved changes of their own
vim.cmd("edit " .. vim.fn.fnameescape(files[4]))
local user_win, user_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { "-- mine" })
check(normal_wins() == 1, "start with one window")
local function edit(i)
  return tools.call("edit_file", { path = files[i], old_str = "local v = " .. i, new_str = "local v = " .. i * 10 })
end
check(not edit(1).isError, "edit a.lua")
local side = vim.api.nvim_get_current_win()
check(normal_wins() == 2 and side ~= user_win and vim.api.nvim_win_get_buf(user_win) == user_buf, "first edit split once, the user's modified buffer stays visible")
check(not edit(2).isError and not edit(3).isError, "edit b.lua and c.lua")
check(normal_wins() == 2 and vim.api.nvim_get_current_win() == side, "later edits reuse the side window (no new splits)")
check(text(tools.call("open_file", { path = files[1], line = 1 })):find("Opened", 1, true) and normal_wins() == 2, "open_file reuses it too")
check(vim.api.nvim_win_get_buf(user_win) == user_buf, "user's window untouched")

local before = #floats()
r = tools.call("save_file", { paths = { files[1], files[2], files[3] } })
local sw = floats()[1]
check(r.pending and #floats() == before + 1, "one confirm for three files")
local body = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(sw), 0, -1, false)
check(#body == 3 and body[1]:find("a.lua$") and body[3]:find("c.lua$"), "confirm lists every file: " .. table.concat(body, " | "))
check(vim.api.nvim_win_get_config(sw).title[1][1]:find("save 3 files", 1, true), "title counts the files")
keys("a")
local res = tools.poll(r.pending)
check(not res.isError and select(2, text(res):gsub("Saved", "")) == 3, "all three saved: " .. text(res))
check(vim.fn.readfile(files[2])[1] == "local v = 20", "b.lua on disk")
r = tools.call("write_file", { path = tmp .. "/new.txt", content = "x\n" })
check(#floats() == 0 and r.pending == nil and not r.isError, "write after `a` does not ask")
res = tools.call("save_file", { paths = { files[1], tmp .. "/nope.lua" } })
check(res.isError and text(res):find("no unsaved changes", 1, true) and text(res):find("not open", 1, true), "per-file notes for clean / unopened files: " .. text(res))

-- 4. a new chat asks again; cancel closes an open confirm and nothing runs
tools.reset_grants()
r = tools.call("write_file", { path = tmp .. "/late.txt", content = "x\n" })
check(#floats() == 1, "after reset, writes ask again")
tools.cancel_pending("cancelled by the user")
check(#floats() == 0, "cancel closed the confirm")
check(text(tools.poll(r.pending)) == "cancelled by the user" and vim.uv.fs_stat(tmp .. "/late.txt") == nil, "cancelled write did not happen")
-- the bridge timing out one call (cancel by id) closes its confirm too
r = tools.call("write_file", { path = tmp .. "/timeout.txt", content = "x\n" })
check(#floats() == 1, "write asks")
tools.cancel_pending("timed out waiting for the user", r.pending)
check(#floats() == 0 and vim.uv.fs_stat(tmp .. "/timeout.txt") == nil, "timeout closed the write confirm, nothing written")
check(text(tools.poll(r.pending)) == "timed out waiting for the user", "the call reports the timeout")

-- 5. without unsaved work of the user's, edits replace the target window
vim.cmd("silent only")
vim.cmd("edit " .. vim.fn.fnameescape(tmp .. "/new.txt"))
for i = 1, 3 do vim.fn.writefile({ "local v = " .. i }, files[i]); vim.cmd("silent! checktime") end
for i = 1, 3 do
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == files[i] then vim.cmd("bwipeout! " .. b) end
  end
end
check(not edit(1).isError and not edit(2).isError, "edits with a clean target")
check(normal_wins() == 1, "no split when nothing of the user's is unsaved")
check(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()) == files[2], "last edited file shown")
local a = vim.fn.bufnr(files[1])
check(a > 0 and vim.bo[a].modified and vim.bo[a].buflisted, "earlier edited buffer is hidden, still listed and modified")

-- 6. edit_file on a file with the user's own unsaved changes asks: save / drop / skip
local x = tmp .. "/x.lua"
vim.fn.writefile({ "local a = 1", "local b = 2" }, x)
vim.cmd("silent only")
vim.cmd("edit " .. vim.fn.fnameescape(x))
local xbuf = vim.api.nvim_get_current_buf()
local function mine(l) vim.api.nvim_buf_set_lines(xbuf, 0, 1, false, { l }) end
local function edit_x() return tools.call("edit_file", { path = x, old_str = "local b = 2", new_str = "local b = 3" }) end
mine("local a = 10")
r = edit_x()
check(r.pending and #floats() == 1, "edit of a file with the user's changes asks first")
footer = table.concat(vim.tbl_map(function(c) return c[1] end, vim.api.nvim_win_get_config(floats()[1]).footer))
check(footer:find("s save mine", 1, true) and footer:find("d drop mine", 1, true) and footer:find("n skip", 1, true), "footer offers save / drop / skip: " .. footer)
keys("n")
res = tools.poll(r.pending)
check(res.isError and text(res):find("not edited", 1, true), "skip fails the call: " .. text(res))
check(vim.api.nvim_buf_get_lines(xbuf, 0, -1, false)[2] == "local b = 2", "skipped: buffer untouched")
r = edit_x()
keys("s")
res = tools.poll(r.pending)
check(not res.isError and text(res):find("Saved the user's changes first", 1, true), "save then edit: " .. text(res))
check(vim.deep_equal(vim.fn.readfile(x), { "local a = 10", "local b = 2" }), "the user's change is on disk")
check(vim.deep_equal(vim.api.nvim_buf_get_lines(xbuf, 0, -1, false), { "local a = 10", "local b = 3" }) and vim.bo[xbuf].modified, "Claude's edit applied unsaved on top")
r = tools.call("edit_file", { path = x, old_str = "local b = 3", new_str = "local b = 4" })
check(r.pending == nil and not r.isError, "a further edit of Claude's own unsaved change does not ask")
mine("local a = 99")
r = edit_x()
check(r.pending and #floats() == 1, "the user changing it again makes the next edit ask")
keys("d")
res = tools.poll(r.pending)
check(not res.isError and text(res):find("Dropped the user's unsaved changes", 1, true), "drop then edit: " .. text(res))
check(vim.deep_equal(vim.api.nvim_buf_get_lines(xbuf, 0, -1, false), { "local a = 10", "local b = 3" }), "the user's change is gone, Claude's edit applied to the file on disk")

-- 7. a buffer Claude edited is protected again once the user changes it
vim.cmd("silent write")
vim.fn.writefile({ "local v = 1" }, files[1])
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(b) == files[1] then vim.cmd("bwipeout! " .. b) end
end
vim.cmd("silent only")
check(not edit(1).isError and normal_wins() == 1, "Claude edits a.lua in place")
local mine_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(mine_buf, 0, 0, false, { "-- user note" })
check(not edit(2).isError and normal_wins() == 2, "after the user changed a.lua, the next file gets a split")
check(vim.fn.bufwinnr(mine_buf) > 0, "a.lua with the user's change stays visible")

vim.fn.delete(tmp, "rf")
t.finish()
