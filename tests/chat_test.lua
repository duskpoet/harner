vim.opt.rtp:prepend(vim.fn.expand("~/.config/nvim"))
vim.o.columns = 160; vim.o.lines = 50
require("harner").setup()
vim.cmd("edit " .. vim.fn.expand("~/.config/nvim/lua/harner/mcp.lua"))
vim.api.nvim_win_set_cursor(0, { 12, 0 })
local chat = require("harner.chat")
chat.open()
local buf = chat.current
local c = chat.chats[buf]
local function ask(text)
  local n = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { text })
  chat.send(buf)
  local ok = vim.wait(180000, function() return c.run == nil end, 100)
  io.stderr:write(ok and "" or "TIMEOUT\n")
end
ask("Call show_text to display a 3-line Lua hello-world (filetype lua, title Hello). Then reply with exactly one word: done.")
ask("What is the name of the file I have open and what is on the line my cursor is on? One sentence.")
-- async tools through the real bridge: vim.ui.select is stubbed (headless has no UI)
vim.ui.select = function(items, opts, cb) io.stderr:write("ui.select: " .. opts.prompt .. " " .. vim.inspect(items) .. "\n"); vim.defer_fn(function() cb("green") end, 200) end
ask("Call ask_user with the question 'Which colour?' and the choices red and green. Then call open_file on mcp.lua at the line where M.server_address is defined. Finally reply with only the colour the user picked.")

io.stderr:write("=== CHAT BUFFER ===\n" .. table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n")
io.stderr:write("=== WINDOWS ===\n")
for _, w in ipairs(vim.api.nvim_list_wins()) do
  local b = vim.api.nvim_win_get_buf(w)
  io.stderr:write(string.format("win %d  %s  ft=%s  winbar=%s\n", w, vim.api.nvim_buf_get_name(b), vim.bo[b].filetype, vim.wo[w].winbar))
  if vim.api.nvim_buf_get_name(b):match("harner://show") then
    io.stderr:write("  content: " .. vim.inspect(vim.api.nvim_buf_get_lines(b, 0, -1, false)) .. "\n")
  end
end
io.stderr:write("session " .. c.session_id .. " started=" .. tostring(c.started) .. "\n")
vim.cmd("qa!")
