local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local root, check = t.root, t.check
vim.o.columns = 160; vim.o.lines = 50
-- Offline UI test for the input popup and <leader>h keymaps. The runner is
-- stubbed (the only test that does so) so no claude process is started.
local started = {}
package.loaded["harner.runner"] = {
  start = function(o) started[#started + 1] = o; return { pid = 1 } end,
  cancel = function() end,
}
require("harner").setup()
local function keys(s, flags) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), flags or "x", false) end
local function set(lines) vim.api.nvim_buf_set_lines(0, 0, -1, false, lines); vim.cmd("doautocmd TextChanged") end

vim.cmd("edit " .. vim.fn.fnameescape(root .. "/lua/harner/mcp.lua"))
local edit_win = vim.api.nvim_get_current_win()
check(vim.fn.maparg("<leader>hh", "n") ~= "", "<leader>hh mapped")
check(vim.fn.maparg("<leader>ht", "n") ~= "", "<leader>ht mapped")
check(vim.fn.exists(":HarnerAsk") == 2, ":HarnerAsk exists")

-- open popup via the keymap
keys("<leader>hh")
local pwin = vim.api.nvim_get_current_win()
check(vim.api.nvim_win_get_config(pwin).relative == "editor", "popup is floating")
check(vim.fn.maparg("<S-CR>", "i", false, true).rhs == "<CR>", "S-CR inserts newline in insert mode")
-- (startinsert! is deferred to the main loop, which never runs under nvim -l; edit the buffer directly)
set({ "hello there", "second line" })
check(vim.api.nvim_win_get_height(pwin) == 2, "popup grew to 2 lines, got " .. vim.api.nvim_win_get_height(pwin))
set({ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" })
check(vim.api.nvim_win_get_height(pwin) == 10, "popup capped at max_height, got " .. vim.api.nvim_win_get_height(pwin))
set({ "hello there", "second line" })
keys("<CR>")

check(not vim.api.nvim_win_is_valid(pwin), "popup closed after send")
check(#started == 1, "runner started once")
check(started[1] and started[1].prompt == "hello there\nsecond line", "prompt text forwarded")
local chat = require("harner.chat")
local c = chat.chats[chat.current]
check(c ~= nil, "chat created lazily")
check(c.origin_win == edit_win, "origin_win is the editor window")
check(vim.api.nvim_get_current_win() == edit_win, "focus stayed in editor window")
check(vim.fn.bufwinid(c.buf) ~= -1, "chat split opened (unfocused)")
local lines = vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)
check(lines[1] == "## You" and lines[3] == "hello there" and lines[4] == "second line", "chat shows the question")
check(chat.target_win() == edit_win, "target_win is the editor window")

-- busy: the popup queues the prompt, it is sent when the run finishes
keys("<leader>hh")
set({ "again" })
keys("<CR>")
check(#started == 1, "busy: nothing started")
check(vim.api.nvim_get_current_win() == edit_win, "busy: popup closed, back in editor")
check(c.queue and #c.queue == 1 and c.queue[1].prompt == "again", "busy: prompt queued")
check(vim.wo[vim.fn.bufwinid(c.buf)].winbar:find("1 queued", 1, true) ~= nil, "winbar shows the queue")
started[1].on_done({ total_cost_usd = 0.01 })
check(#started == 2 and started[2].prompt == "again" and started[2].resume == true, "queued prompt sent on finish, resuming")
check(#c.queue == 0, "queue drained")
check(vim.wo[vim.fn.bufwinid(c.buf)].winbar:find("queued", 1, true) == nil, "winbar queue badge gone")
-- cancel: the queued prompts go back to the input instead of being sent
vim.cmd("HarnerAsk later one")
vim.cmd("HarnerAsk later two")
check(#started == 2 and #c.queue == 2, "two prompts queued")
chat.cancel()
started[2].on_done(nil)
check(#started == 2 and #c.queue == 0, "cancel: queue not sent")
check(vim.wo[vim.fn.bufwinid(c.buf)].winbar:find("queued", 1, true) == nil, "cancel: winbar queue badge gone")
lines = vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)
check(lines[#lines - 2] == "later one" and lines[#lines] == "later two", "cancel: queue moved to the draft: " .. vim.inspect(lines))

-- an error result (API / auth error) does not send the queue either
vim.cmd("HarnerAsk errored run")
local n_err = #started
vim.cmd("HarnerAsk after error")
started[n_err].on_done({ is_error = true })
check(#started == n_err and #c.queue == 0, "error result: queue not sent")
lines = vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)
check(lines[#lines] == "after error", "error result: queue moved to the draft")

-- Esc keeps the popup draft
keys("<leader>hh")
set({ "draft" })
keys("<Esc>")
check(vim.api.nvim_get_current_win() == edit_win, "Esc closed popup, back in editor")
keys("<leader>hh")
check(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "draft", "draft restored")
keys("<CR>")
check(#started == n_err + 1 and started[#started].prompt == "draft", "draft sent")
started[#started].on_done({})

-- :HarnerAsk with text sends directly
vim.cmd("HarnerAsk from command")
check(#started == n_err + 2 and started[#started].prompt == "from command", ":HarnerAsk text sends directly")
started[#started].on_done({})

-- toggle from the editor hides/shows the chat
keys("<leader>ht")
check(vim.fn.bufwinid(c.buf) == -1, "<leader>ht hid chat")
keys("<leader>ht")
check(vim.fn.bufwinid(c.buf) ~= -1, "<leader>ht showed chat")
check(vim.api.nvim_get_current_buf() == c.buf, "toggle focuses chat")

-- leaving the popup with <C-w>w dismisses it
vim.api.nvim_set_current_win(edit_win)
keys("<leader>hh")
local p2 = vim.api.nvim_get_current_win()
vim.cmd("wincmd w")
vim.wait(50, function() return false end)
check(not vim.api.nvim_win_is_valid(p2), "WinLeave closed popup")

-- new chat from the editor
vim.api.nvim_set_current_win(edit_win)
keys("<leader>hn")
check(chat.current ~= c.id, "<leader>hn created a new chat")
check(chat.chats[c.id] ~= nil, "the old chat is kept")
vim.api.nvim_set_current_win(edit_win)

-- visual selection: popup carries a reference, Claude reads the text via get_selection
keys("5GV7G")
check(vim.fn.mode() == "V", "in linewise visual mode")
keys("<leader>hh")
local p3 = vim.api.nvim_get_current_win()
check(vim.api.nvim_win_get_config(p3).relative == "editor", "visual <leader>hh opened popup")
check(vim.fn.mode() == "n", "visual mode left, got " .. vim.fn.mode())
local title = vim.api.nvim_win_get_config(p3).title
local title_text = title and title[1] and title[1][1] or tostring(title)
check(title_text:find("mcp.lua:5%-7") ~= nil, "title shows reference: " .. title_text)
set({ "what does this do?" })
keys("<CR>")
local sent = started[#started]
local relpath = vim.fn.fnamemodify(root .. "/lua/harner/mcp.lua", ":.")
check(sent and sent.prompt == "what does this do?\n\nSelection: " .. relpath .. " lines 5-7 (read it with get_selection)",
  "prompt ends with the reference line, got: " .. vim.inspect(sent and sent.prompt))
check(not sent.prompt:find("local M = {}", 1, true), "selected text itself is not pasted")
local res = require("harner.tools").call("get_selection", {})
local body = res.content[1].text
check(body:find("lines: 5%-7") ~= nil and body:find("local bridge_path", 1, true) ~= nil and not res.isError,
  "get_selection resolves the referenced lines: " .. body:gsub("\n", " | "))
sent.on_done({})

-- :'<,'>HarnerAsk text attaches the range as a reference too
vim.cmd("2,3HarnerAsk explain")
sent = started[#started]
check(sent.prompt == "explain\n\nSelection: " .. relpath .. " lines 2-3 (read it with get_selection)", ":range HarnerAsk attaches reference, got " .. vim.inspect(sent.prompt))
body = require("harner.tools").call("get_selection", {}).content[1].text
check(body:find("lines: 2%-3") ~= nil, "get_selection follows the range reference, not the old marks: " .. body:gsub("\n", " | "))
-- a queued reference still resolves after the user selected something else
local n_started = #started
vim.cmd("4,4HarnerAsk queued ref")
check(#started == n_started, "queued behind the running request")
keys("8GV9G<Esc>")
sent.on_done({})
sent = started[#started]
check(sent.prompt:find("lines? 4") ~= nil, "queued prompt sent with its reference")
body = require("harner.tools").call("get_selection", {}).content[1].text
check(body:find("lines: 4%-4") ~= nil, "get_selection reads the queued reference: " .. body:gsub("\n", " | "))
sent.on_done({})

-- normal-mode popup has no reference even after a visual one
keys("<leader>hh")
local p4 = vim.api.nvim_get_current_win()
local t4 = vim.api.nvim_win_get_config(p4).title
check((t4 and t4[1] and t4[1][1] or "") == " harner ", "plain popup title has no reference")
set({ "plain" })
keys("<CR>")
check(started[#started].prompt == "plain", "plain popup sends no reference")
started[#started].on_done({})

-- parse_ref inverts ref_line, so a reference survives a trip through the draft
local pm = require("harner.prompt")
local abs = root .. "/lua/harner/mcp.lua"
for _, r in ipairs({ { path = abs, first = 5, last = 7 }, { path = abs, first = 4, last = 4 } }) do
  local back = pm.parse_ref("question\n\n" .. pm.ref_line(r))
  check(back and back.path == abs and back.first == r.first and back.last == r.last,
    "parse_ref round trip " .. r.first .. "-" .. r.last .. ": " .. vim.inspect(back))
end
check(pm.parse_ref("no reference here") == nil, "parse_ref: nil without a Selection line")
check(pm.parse_ref(pm.ref_line({ path = "", first = 1, last = 2 })) == nil, "parse_ref: [No Name] gives nil")
-- a reference line sent from the chat buffer itself is honoured by get_selection
local cur = chat.chats[chat.current]
vim.api.nvim_buf_set_lines(cur.buf, -1, -1, false, { "again please", "", pm.ref_line({ path = abs, first = 9, last = 10 }) })
chat.send(cur.buf)
body = require("harner.tools").call("get_selection", {}).content[1].text
check(body:find("lines: 9%-10") ~= nil, "chat-buffer send parses its reference: " .. body:gsub("\n", " | "))
started[#started].on_done({})
-- a reference to a missing file or past the end is an error, not an empty range
cur.ref = { path = root .. "/no/such/file.lua", first = 1, last = 2 }
res = require("harner.tools").call("get_selection", {})
check(res.isError and res.content[1].text:find("no longer exist", 1, true), "missing file: " .. res.content[1].text)
check(vim.fn.bufnr(root .. "/no/such/file.lua") == -1, "missing file: no empty buffer left behind")
cur.ref = { path = abs, first = 100000, last = 100002 }
res = require("harner.tools").call("get_selection", {})
check(res.isError and res.content[1].text:find("no longer exist", 1, true), "past the end: " .. res.content[1].text)
t.finish()
