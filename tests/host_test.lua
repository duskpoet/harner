local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
vim.o.columns = 160; vim.o.lines = 50
-- The host (host.lua, a real detached process) against this nvim (web.lua)
-- and a watcher connection standing in for the web server: spawn on demand,
-- transcript mirroring, questions answered from either side, prompt and
-- cancel from the watcher, snapshots of an exited nvim, idle exit, respawn.
local uv = vim.uv

local fake = vim.fn.tempname() .. "-fake-claude"
vim.fn.writefile({
  "#!/bin/sh",
  'p=$(cat)',
  'case "$p" in *slow*) sleep 5;; esac',
  [[echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"answer to: ]] .. [['"$(echo "$p" | head -1)"'"}}}']],
  [[echo '{"type":"result","is_error":false,"duration_api_ms":1,"total_cost_usd":0.001}']],
}, fake)
vim.fn.setfperm(fake, "rwxr-xr-x")

local dir = vim.fn.tempname() .. "-host"
local sock = dir .. "/host.sock"
require("harner").setup({
  claude_cmd = fake,
  auto = { enabled = false },
  web = { enabled = true, socket = sock, idle_exit = 1, port = 20000 + math.random(0, 20000), token_file = dir .. "/token" },
})
local web = require("harner.web")
local chat = require("harner.chat")
local tools = require("harner.tools")
local host = require("harner.host") -- only for splice()

check(vim.wait(5000, web.connected, 20), "nvim connected, host spawned on demand")
check(uv.fs_stat(sock) ~= nil, "socket created")
check(bit.band(uv.fs_stat(vim.fs.dirname(sock)).mode, 511) == 448, "socket dir is 0700")

-- watcher: collects events, mirrors chat lines like the web page will
local W = { events = {}, snap = nil, lines = {}, eof = false }
local function watcher()
  local w = { events = {}, snap = nil, lines = {}, eof = false, buf = "" }
  w.pipe = uv.new_pipe(false)
  w.pipe:connect(sock, function(err)
    assert(not err, err)
    w.pipe:write(vim.json.encode({ type = "watch" }) .. "\n")
    w.pipe:read_start(function(_, data)
      if not data then w.eof = true return end
      w.buf = w.buf .. data
      while true do
        local nl = w.buf:find("\n", 1, true)
        if not nl then break end
        local msg = vim.json.decode(w.buf:sub(1, nl - 1))
        w.buf = w.buf:sub(nl + 1)
        if msg.type == "snapshot" then
          w.snap = msg
          for _, nv in ipairs(msg.nvims) do
            for _, c in ipairs(nv.chats) do w.lines[nv.id .. ":" .. c.id] = c.lines end
          end
        else
          w.events[#w.events + 1] = msg
          if msg.type == "lines" then
            local k = msg.nvim .. ":" .. msg.chat
            w.lines[k] = host.splice(w.lines[k] or { "" }, msg.first, msg.last, msg.lines)
          end
        end
      end
    end)
  end)
  vim.wait(2000, function() return w.snap ~= nil end, 10)
  return w
end
local function send(w, obj) w.pipe:write(vim.json.encode(obj) .. "\n") end
local function find_event(w, pred)
  for _, e in ipairs(w.events) do if pred(e) then return e end end
end
local function wait_event(w, pred, ms)
  local found
  vim.wait(ms or 3000, function() found = find_event(w, pred) return found ~= nil end, 10)
  return found
end

W = watcher()
check(W.snap and #W.snap.nvims == 1 and W.snap.nvims[1].pid == uv.os_getpid(), "snapshot lists this nvim")
local me = W.snap.nvims[1].id

-- 1. a run is mirrored line by line
check(chat.ask("hello host"), "ask sent")
local c = chat.chats[chat.current]
check(vim.wait(5000, function() return c.run == nil end, 20), "run finished")
local key = me .. ":" .. c.id
check(wait_event(W, function(e) return e.type == "chat" and e.chat == c.id and e.title == "hello host" end), "chat metadata mirrored (title)")
vim.wait(500, function() return vim.deep_equal(W.lines[key], vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)) end, 10)
local mirrored = W.lines[key] or {}
check(vim.deep_equal(mirrored, vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)), "mirror equals the chat buffer:\n" .. table.concat(mirrored, "\n"))
check(table.concat(mirrored, "\n"):find("answer to: hello host", 1, true), "streamed text reached the mirror")

-- a wiped and rebuilt buffer resyncs whole
vim.cmd("bwipeout! " .. c.buf)
vim.wait(50)
chat.open(); vim.cmd("stopinsert")
vim.wait(500, function() return vim.deep_equal(W.lines[key], vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)) end, 10)
check(vim.deep_equal(W.lines[key], vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)), "mirror still right after the buffer was rebuilt")

-- 2. questions: answered from the watcher
local function floats()
  return #vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative ~= "" end, vim.api.nvim_list_wins())
end
local r = tools.call("ask_user", { question = "Which one?", choices = { "red", "green" } }, c.id)
local p = wait_event(W, function(e) return e.type == "pending" and e.title == "Claude asks" and e.items ~= vim.NIL end)
check(p and p.chat == c.id and p.body[1] == "Which one?" and p.items[2] == "green", "pending question mirrored with items")
check(floats() == 1, "float open in nvim at the same time")
send(W, { type = "answer", nvim = me, call = p.call, choice = "item", arg = 2 })
check(vim.wait(2000, function() return not tools.is_pending(r.pending) end, 10), "answer from the watcher resolved the call")
check(tools.poll(r.pending).content[1].text == "green" and floats() == 0, "picked item returned, float closed")
check(wait_event(W, function(e) return e.type == "resolved" and e.call == p.call and e.by == "web" end), "resolved event says by web")

r = tools.call("ask_user", { question = "Name?" }, c.id)
p = wait_event(W, function(e) return e.type == "pending" and e.input == true end)
check(p ~= nil, "free-text question mirrored as input")
send(W, { type = "answer", nvim = me, call = p.call, choice = "always", arg = "x" })
check(wait_event(W, function(e) return e.type == "error" and e.message:find("does not take", 1, true) end), "the host refuses an answer the question doesn't offer")
check(tools.is_pending(r.pending) and floats() == 1, "and the question stays open")
send(W, { type = "answer", nvim = me, call = p.call, choice = "text", arg = "Ada" })
vim.wait(2000, function() return not tools.is_pending(r.pending) end, 10)
check(tools.poll(r.pending).content[1].text == "Ada", "typed answer from the watcher")

-- answered in nvim first: the watcher's late answer is refused by the host
local function keys(s) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "x", false) end
r = tools.call("run_command", { cmd = "echo 'x'" }, c.id)
p = wait_event(W, function(e) return e.type == "pending" and e.title:find("wants to run", 1, true) end)
check(p and vim.tbl_contains(vim.tbl_map(function(k) return k.value end, p.keys), "always"), "confirm keys mirrored (yes/always/no)")
keys("y")
check(wait_event(W, function(e) return e.type == "resolved" and e.call == p.call and e.by == "nvim" end), "resolved by nvim")
send(W, { type = "answer", nvim = me, call = p.call, choice = "no" })
check(wait_event(W, function(e) return e.type == "error" and e.message:find("already answered", 1, true) end), "late answer refused")
check(tools.poll(r.pending).content[1].text == "x", "nvim's answer stood")

-- 3. prompt and cancel from the watcher
send(W, { type = "prompt", nvim = me, chat = c.id, text = "from the web" })
check(vim.wait(3000, function() return c.run ~= nil end, 10), "prompt from the watcher started a run")
check(vim.wait(5000, function() return c.run == nil end, 20), "and it finished")
check(table.concat(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), "\n"):find("answer to: from the web", 1, true), "its answer is in the chat")
send(W, { type = "prompt", nvim = me, chat = c.id, text = "slow one" })
vim.wait(3000, function() return c.run ~= nil end, 10)
check(wait_event(W, function(e) return e.type == "chat" and e.chat == c.id and e.running == true end), "running=true mirrored")
send(W, { type = "prompt", nvim = me, chat = c.id, text = "too soon" })
check(wait_event(W, function(e) return e.type == "error" and e.message:find("still running", 1, true) end), "prompt to a running chat refused by the host")
send(W, { type = "cancel", nvim = me, chat = c.id })
check(vim.wait(2000, function() return c.run == nil end, 10), "cancel from the watcher stopped the run")
check(wait_event(W, function(e) return e.type == "chat" and e.chat == c.id and e.running == false end), "running=false mirrored")

-- 4. this nvim leaves: snapshot kept read-only, then the idle host exits
local final = vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)
web.stop()
check(wait_event(W, function(e) return e.type == "gone" and e.nvim == me end), "gone event")
local W2 = watcher()
local nv = W2.snap and W2.snap.nvims[1]
check(nv and nv.gone == true and nv.chats[1] and vim.deep_equal(nv.chats[1].lines, final), "snapshot of the exited nvim kept")
send(W2, { type = "prompt", nvim = me, chat = c.id, text = "hi" })
check(wait_event(W2, function(e) return e.type == "error" and e.message:find("exited", 1, true) end), "prompt to an exited nvim refused")
check(vim.wait(4000, function() return W.eof and W2.eof end, 50), "host exited after idle_exit")
check(uv.fs_stat(sock) == nil, "socket removed")

-- 5. the next start spawns a fresh host and resyncs
local ok
web.start(function(v) ok = v end)
check(vim.wait(5000, function() return ok ~= nil end, 20) and ok, "reconnected to a respawned host")
local W3 = watcher()
local n3 = W3.snap and W3.snap.nvims[1]
check(n3 and n3.chats[1] and vim.deep_equal(n3.chats[1].lines, final), "resync sent the chats again")
web.stop()
vim.wait(3000, function() return W3.eof end, 50)
vim.fn.delete(dir, "rf")
t.finish()
