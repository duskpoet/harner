local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
vim.o.columns = 160; vim.o.lines = 50
-- Several chats per nvim: a chat survives :bwipeout / :bdelete of its buffer
-- (also mid-run), <leader>hn keeps the old one, the picker switches, and tool
-- calls act for the chat their bridge names (window, grants, cancel).

-- fake claude: waits a bit so the test can wipe the buffer mid-run
local fake = vim.fn.tempname() .. "-fake-claude"
local events = {
  { type = "stream_event", event = { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "late answer" } } },
  { type = "result", subtype = "success", is_error = false, duration_api_ms = 1, total_cost_usd = 0.001, result = "x" },
}
local lines = { "#!/bin/sh", "cat >/dev/null", "sleep 0.3" }
for _, e in ipairs(events) do
  lines[#lines + 1] = "echo '" .. vim.json.encode(e):gsub("'", "'\\''") .. "'"
end
vim.fn.writefile(lines, fake)
vim.fn.setfperm(fake, "rwxr-xr-x")

require("harner").setup({ claude_cmd = fake })
require("harner").config.auto.enabled = false
local chat = require("harner.chat")
local tools = require("harner.tools")

-- two files side by side, as origins of two chats
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "alpha" }, dir .. "/a.txt")
vim.fn.writefile({ "beta" }, dir .. "/b.txt")
vim.cmd("edit " .. dir .. "/a.txt")
local win_a = vim.api.nvim_get_current_win()
vim.cmd("vsplit " .. dir .. "/b.txt")
local win_b = vim.api.nvim_get_current_win()

-- 1. a run keeps writing after its buffer was wiped; reopening restores it
vim.api.nvim_set_current_win(win_a)
check(chat.ask("first question", win_a), "ask sent")
local a = chat.chats[chat.current]
check(a.title == "first question", "title from the first prompt")
local old_buf = a.buf
vim.cmd("bwipeout! " .. old_buf)
check(chat.chats[a.id] == a, "chat kept after :bwipeout")
check(a.buf == nil and a.lines ~= nil, "lines kept while detached")
check(vim.wait(5000, function() return a.run == nil end, 20), "run finished")
check(a.buf ~= nil and vim.api.nvim_buf_is_valid(a.buf), "run output rebuilt a buffer")
local text = table.concat(vim.api.nvim_buf_get_lines(a.buf, 0, -1, false), "\n")
check(text:find("first question", 1, true) and text:find("late answer", 1, true), "transcript intact:\n" .. text)
check(vim.api.nvim_buf_get_name(a.buf):match("harner://chat/" .. a.id .. "$"), "rebuilt buffer reuses the name")
check(a.started, "session started, next send resumes the same session")

-- 2. :bdelete also only detaches; open() shows the same transcript
local sid = a.session_id
vim.cmd("bdelete! " .. a.buf)
vim.wait(50)
check(a.buf == nil, "detached after :bdelete")
chat.open()
vim.cmd("stopinsert")
check(a.session_id == sid and chat.current == a.id, "same chat reopened")
text = table.concat(vim.api.nvim_buf_get_lines(a.buf, 0, -1, false), "\n")
check(text:find("late answer", 1, true) ~= nil, "transcript restored after :bdelete")
check(vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win()) == a.buf, "shown in a window")

-- 3. new chat keeps the old; picker switches back in the same window
chat.new()
vim.cmd("stopinsert")
local b = chat.chats[chat.current]
check(b ~= a and chat.chats[a.id] == a, "<leader>hn keeps the old chat")
local chat_win = vim.api.nvim_get_current_win()
local orig_select = vim.ui.select
local offered
vim.ui.select = function(items, opts, cb)
  offered = vim.tbl_map(opts.format_item, items)
  cb(items[1])
end
chat.pick()
vim.ui.select = orig_select
check(offered and #offered == 2 and offered[1]:find("first question", 1, true), "picker lists both chats: " .. vim.inspect(offered))
check(chat.current == a.id and vim.api.nvim_win_get_buf(chat_win) == a.buf, "picked chat shown in the chat window")
check(#vim.tbl_filter(function(w) return chat.by_buf(vim.api.nvim_win_get_buf(w)) end, vim.api.nvim_list_wins()) == 1, "no extra chat split")

-- 4. tool calls act for the chat their bridge names
a.origin_win, b.origin_win = win_a, win_b
chat.current = b.id
local function first_text(r) return r.content[1].text end
local res = first_text(tools.call("get_current_buffer", {}, a.id))
check(res:find("a.txt", 1, true) ~= nil, "chat A's call reads A's window")
res = first_text(tools.call("get_current_buffer", {}, b.id))
check(res:find("b.txt", 1, true) ~= nil, "chat B's call reads B's window")
check(chat.ctx == nil, "ctx cleared after the call")

-- grants from a confirm land on the calling chat even when answered later
local confirm = require("harner.confirm")
local orig_ask = confirm.ask
local answers = {}
confirm.ask = function(_, cb)
  answers[#answers + 1] = cb
  return function(choice) cb(choice) end
end
local r = tools.call("run_command", { cmd = "echo 'hi'" }, a.id)
check(type(r) == "table" and r.pending, "run_command waits on the confirm")
answers[1]("always")
check(a.grants and a.grants.commands["echo 'hi'"], "grant stored on chat A")
check(not (b.grants and b.grants.commands["echo 'hi'"]), "chat B not granted")

-- cancel_chat only touches its own chat's calls
local ra = tools.call("run_command", { cmd = "echo 'one'" }, a.id)
local rb = tools.call("run_command", { cmd = "echo 'two'" }, b.id)
tools.cancel_chat("cancelled by the user", a.id)
check(not tools.is_pending(ra.pending), "A's call cancelled")
check(tools.is_pending(rb.pending), "B's call still waiting")
tools.cancel_pending("cleanup")
confirm.ask = orig_ask

-- a prompt for a chat that is not on screen (the web UI) runs in the background
vim.wait(3000, function() return not a.run and not b.run end, 20)
chat.show(b, false)
local function chat_wins()
  local n = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if chat.by_buf(vim.api.nvim_win_get_buf(w)) then n = n + 1 end
  end
  return n
end
check(chat.current == b.id and chat_wins() == 1, "B shown and current")
check(chat.ask("background question", nil, a.id), "background ask sent")
check(chat.current == b.id, "B stays current: " .. tostring(chat.current))
check(chat_wins() == 1, "no second chat split")
check(a.run ~= nil, "A runs")
-- <leader>hx with the current chat idle cancels the one running chat
local function cancelled(c)
  return table.concat(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), "\n"):find("> cancelled", 1, true) ~= nil
end
chat.cancel()
check(cancelled(a) and not cancelled(b), "idle current: the only running chat (A) is cancelled")
vim.wait(3000, function() return not a.run end, 20)
-- with several running, nothing is guessed
chat.ask("again", nil, a.id)
chat.ask("and B", nil, b.id)
chat.new()
local idle = chat.chats[chat.current]
local notify, warned = vim.notify, nil
vim.notify = function(msg) warned = msg end
chat.cancel()
vim.notify = notify
check(warned and warned:find("several chats", 1, true), "several running: warns")
local function count(c)
  local _, n = table.concat(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), "\n"):gsub("> cancelled", "")
  return n
end
check(count(a) == 1 and count(b) == 0 and a.run and b.run and not idle.run, "several running: nothing cancelled")
vim.wait(3000, function() return not a.run and not b.run end, 20)

t.finish()
