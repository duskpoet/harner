vim.opt.rtp:prepend(vim.fn.expand("~/.config/nvim"))
vim.o.columns = 160; vim.o.lines = 50
-- Offline test of runner.lua + chat.lua against a fake `claude` script that
-- replays stream-json events: tool notes get their input summary, text
-- streams, the result line sets the winbar, and a missing binary is reported.
local fails = 0
local function check(cond, msg) if not cond then fails = fails + 1 end; io.stderr:write((cond and "ok   " or "FAIL ") .. msg .. "\n") end

local fake = vim.fn.tempname() .. "-fake-claude"
local events = {
  { type = "system", subtype = "init" },
  { type = "stream_event", event = { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } } },
  { type = "stream_event", event = { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "Let me look. " } } },
  { type = "stream_event", event = { type = "content_block_stop", index = 0 } },
  { type = "stream_event", event = { type = "content_block_start", index = 1, content_block = { type = "tool_use", id = "t1", name = "mcp__nvim__open_file", input = {} } } },
  { type = "stream_event", event = { type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = '{"path": "lua/har' } } },
  { type = "stream_event", event = { type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = 'ner/mcp.lua", "line": 12, "end_line": 20}' } } },
  { type = "stream_event", event = { type = "content_block_stop", index = 1 } },
  { type = "stream_event", event = { type = "content_block_start", index = 2, content_block = { type = "tool_use", id = "t2", name = "Read", input = {} } } },
  { type = "stream_event", event = { type = "content_block_delta", index = 2, delta = { type = "input_json_delta", partial_json = '{"file_path": "/x/y.lua"}' } } },
  { type = "stream_event", event = { type = "content_block_stop", index = 2 } },
  { type = "stream_event", event = { type = "content_block_start", index = 3, content_block = { type = "text", text = "" } } },
  { type = "stream_event", event = { type = "content_block_delta", index = 3, delta = { type = "text_delta", text = "Done." } } },
  { type = "result", subtype = "success", is_error = false, duration_api_ms = 10, total_cost_usd = 0.0123, result = "Done." },
}
local lines = { "#!/bin/sh", "cat >/dev/null" }
for _, e in ipairs(events) do
  lines[#lines + 1] = "echo '" .. vim.json.encode(e):gsub("'", "'\\''") .. "'"
end
vim.fn.writefile(lines, fake)
vim.fn.setfperm(fake, "rwxr-xr-x")

require("harner").setup({ claude_cmd = fake })
local chat = require("harner.chat")
chat.open()
local buf = chat.current
local c = chat.chats[buf]
local function ask(text)
  local n = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { text })
  check(chat.send(buf), "send accepted")
  check(vim.wait(5000, function() return c.run == nil end, 20), "run finished")
end

ask("hello")
local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
check(text:find("Let me look. ", 1, true) ~= nil, "text delta streamed")
check(text:find("_→ nvim:open_file · mcp.lua:12-20_", 1, true) ~= nil, "open_file note amended with path:range")
check(text:find("_→ Read · /x/y.lua_", 1, true) ~= nil, "Read note amended with file_path")
check(text:find("Done.", 1, true) ~= nil, "final text present")
check(not text:find("error", 1, true), "no error in transcript:\n" .. text)
local win = vim.fn.bufwinid(buf)
check(vim.wo[win].winbar:find("idle · $0.012", 1, true) ~= nil, "winbar shows idle + cost: " .. vim.wo[win].winbar)
check(c.started == true, "session marked started")

-- missing binary: error line + run cleared, no process started
require("harner").config.claude_cmd = "/nonexistent/claude-binary"
ask("again")
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
check(text:find("> **error:** `/nonexistent/claude-binary` not found on PATH", 1, true) ~= nil, "missing claude reported in transcript")
check(c.run == nil, "run cleared after missing-binary error")

os.remove(fake)
io.stderr:write(fails == 0 and "ALL OK\n" or (fails .. " FAILED\n"))
vim.cmd("qa!")
