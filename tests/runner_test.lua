local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
vim.o.columns = 160; vim.o.lines = 50
-- Offline test of runner.lua + chat.lua against a fake `claude` script that
-- replays stream-json events: tool notes get their input summary, text
-- streams, the result line sets the winbar, and a missing binary is reported.
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
  { type = "stream_event", event = { type = "content_block_start", index = 4, content_block = { type = "tool_use", id = "t3", name = "mcp__linear-server__get_issue", input = {} } } },
  { type = "stream_event", event = { type = "content_block_stop", index = 4 } },
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
check(text:find("_→ linear-server:get_issue_", 1, true) ~= nil, "other servers' notes read server:tool")
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

-- extra MCP servers: merged into the config file (0600, removed after the
-- run), pre-approved in --allowedTools, named in the system note
local spy = vim.fn.tempname() .. "-spy-claude"
local out = vim.fn.tempname() .. "-spy"
vim.fn.writefile({
  "#!/bin/sh",
  "cat >/dev/null",
  'printf "%s\\n" "$@" > ' .. out .. ".args",
  'prev=""; for a in "$@"; do if [ "$prev" = "--mcp-config" ]; then cp "$a" ' .. out .. '.json; stat -c %a "$a" > ' .. out .. '.mode; echo "$a" > ' .. out .. ".path; fi; prev=\"$a\"; done",
  "echo '" .. vim.json.encode(events[#events]) .. "'",
}, spy)
vim.fn.setfperm(spy, "rwxr-xr-x")
local cfg = require("harner").config
cfg.claude_cmd = spy
cfg.mcp_servers = { linear = { type = "http", url = "https://mcp.linear.app/mcp", headers = { Authorization = "Bearer x" } } }
ask("with servers")
local args = vim.fn.readfile(out .. ".args")
local function after(flag)
  for i, a in ipairs(args) do
    if a == flag then return args[i + 1] end
  end
end
local json = vim.json.decode(table.concat(vim.fn.readfile(out .. ".json"), "\n"))
check(json.mcpServers.nvim ~= nil, "nvim server still in config")
check(json.mcpServers.linear and json.mcpServers.linear.url == "https://mcp.linear.app/mcp", "linear merged into config")
check(json.mcpServers.linear.headers.Authorization == "Bearer x", "headers kept")
check(vim.fn.readfile(out .. ".mode")[1] == "600", "config written 0600: " .. vim.fn.readfile(out .. ".mode")[1])
check(vim.fn.filereadable(vim.fn.readfile(out .. ".path")[1]) == 0, "config removed after the run")
local allowed = vim.split(after("--allowedTools") or "", ",")
check(vim.tbl_contains(allowed, "mcp__linear") and vim.tbl_contains(allowed, "mcp__nvim"), "allowedTools: " .. table.concat(allowed, ","))
check((after("--append-system-prompt") or ""):find("linear (tools mcp__linear__*)", 1, true) ~= nil, "system note names the server")

-- a server named nvim is refused, nothing spawned
os.remove(out .. ".args")
cfg.mcp_servers = { nvim = { type = "http", url = "https://example.com" } }
ask("clash")
text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
check(text:find("the name `nvim` is reserved", 1, true) ~= nil, "nvim clash reported")
check(vim.fn.filereadable(out .. ".args") == 0, "claude not started on a clash")
check(c.run == nil, "run cleared after clash")
cfg.mcp_servers = {}

for _, f in ipairs({ fake, spy, out .. ".args", out .. ".json", out .. ".mode", out .. ".path" }) do
  os.remove(f)
end
t.finish()
