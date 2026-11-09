local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
vim.o.columns = 160; vim.o.lines = 50
-- The host's HTTP server (http.lua) driven with raw requests: Host check,
-- token -> cookie redirect, CSP on every response, static files only from
-- the list, POST guards (Origin, content type, size), the answer / prompt
-- APIs and the SSE stream. :HarnerWeb's URL comes from the host's info.
local uv = vim.uv

local fake = vim.fn.tempname() .. "-fake-claude"
vim.fn.writefile({
  "#!/bin/sh", "cat >/dev/null",
  [[echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"pong"}}}']],
  [[echo '{"type":"result","is_error":false,"duration_api_ms":1,"total_cost_usd":0.001}']],
}, fake)
vim.fn.setfperm(fake, "rwxr-xr-x")

math.randomseed(uv.hrtime() % 2147483647)
local dir = vim.fn.tempname() .. "-web"
local port = 20000 + math.random(0, 20000)
require("harner").setup({
  claude_cmd = fake,
  auto = { enabled = false },
  web = { enabled = true, socket = dir .. "/host.sock", idle_exit = 1, port = port, token_file = dir .. "/token" },
})
local web = require("harner.web")
local chat = require("harner.chat")
local tools = require("harner.tools")

check(vim.wait(5000, function() return web.connected() and web.info ~= nil end, 20), "connected, info received")
local url = web.url()
local token = web.token()
check(url == ("http://127.0.0.1:%d/?token=%s"):format(port, token), "sign-in url: " .. tostring(url))
check(#token == 48 and bit.band(uv.fs_stat(dir .. "/token").mode, 511) == 384, "token is 48 hex chars in a 0600 file")

-- raw HTTP: returns status, headers (lowercased), body; `until_fn(data)` stops early (SSE)
local function request(raw, until_fn)
  local tcp = uv.new_tcp()
  local data, done = "", false
  tcp:connect("127.0.0.1", port, function(err)
    if err then done = true return end
    tcp:write(raw)
    tcp:read_start(function(_, chunk)
      if chunk then
        data = data .. chunk
        if until_fn and until_fn(data) then done = true end
      else
        done = true
      end
    end)
  end)
  vim.wait(3000, function() return done end, 5)
  if not tcp:is_closing() then tcp:close() end
  local head, body = data:match("^(.-)\r\n\r\n(.*)$")
  local status = tonumber((head or ""):match("^HTTP/1%.1 (%d+)"))
  local headers = {}
  for k, v in (head or ""):gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do headers[k:lower()] = v end
  return status, headers, body or "", data
end
local HOST = "127.0.0.1:" .. port
local function get(path, extra)
  return request(("GET %s HTTP/1.1\r\nHost: %s\r\n%s\r\n"):format(path, (extra and extra.host) or HOST, (extra and extra.headers) or ""))
end
local cookie = "Cookie: harner_token=" .. token .. "\r\n"
local function post(path, body, headers)
  headers = headers or ("Origin: http://" .. HOST .. "\r\nContent-Type: application/json\r\n" .. cookie)
  return request(("POST %s HTTP/1.1\r\nHost: %s\r\n%sContent-Length: %d\r\n\r\n%s"):format(path, HOST, headers, #body, body))
end

-- 1. who gets in
local s, h = get("/")
check(s == 401, "no token: 401 (" .. tostring(s) .. ")")
check(h["content-security-policy"] and h["content-security-policy"]:find("script-src 'self'", 1, true), "CSP even on errors")
s = get("/?token=" .. string.rep("0", 48))
check(s == 401, "wrong token: 401")
s, h = get("/?token=" .. token)
check(s == 303 and h.location == "/", "right token redirects to / (" .. tostring(s) .. ")")
check(h["set-cookie"] and h["set-cookie"]:find("harner_token=" .. token, 1, true) and h["set-cookie"]:find("HttpOnly", 1, true)
  and h["set-cookie"]:find("SameSite=Strict", 1, true), "token moved into an HttpOnly SameSite=Strict cookie")
local body
s, h, body = get("/", { headers = cookie })
check(s == 200 and body:find('src="/app.js"', 1, true) and h["content-type"]:find("text/html", 1, true), "page served with the cookie")
check(h["x-frame-options"] == "DENY" and h["x-content-type-options"] == "nosniff" and h["cache-control"] == "no-store", "security headers")
s = get("/", { host = "box.example.ts.net", headers = cookie })
check(s == 200, "any Host header with the cookie (no port: default 80 style)")
s = get("/", { host = "box.example.ts.net" })
check(s == 401, "any Host header without the cookie: 401")
s, h, body = get("/marked.umd.js", { headers = cookie })
check(s == 200 and h["content-type"]:find("javascript", 1, true) and body:find("marked v18", 1, true), "vendored marked served")
s = get("/../lua/harner/host.lua", { headers = cookie })
check(s == 404, "only listed static files")
s = get("/app.js", { headers = "Cookie: harner_token=" .. string.rep("a", 48) .. "\r\n" })
check(s == 401, "wrong cookie: 401")

-- 2. POST guards
local c = chat.ensure()
local prompt = vim.json.encode({ nvim = 1, chat = c.id, text = "ping" })
s = post("/api/prompt", prompt, "Content-Type: application/json\r\n" .. cookie)
check(s == 403, "POST without Origin refused")
s = post("/api/prompt", prompt, "Origin: http://evil.example\r\nContent-Type: application/json\r\n" .. cookie)
check(s == 403, "POST from another origin refused")
s = post("/api/prompt", prompt, "Origin: http://" .. HOST .. "\r\nContent-Type: text/plain\r\n" .. cookie)
check(s == 415, "POST without a JSON content type refused (no simple cross-site requests)")
s = post("/api/prompt", prompt, "Origin: http://" .. HOST .. "\r\nContent-Type: application/json\r\n")
check(s == 401, "POST without the cookie refused")
s = request(("POST /api/prompt HTTP/1.1\r\nHost: %s\r\nOrigin: http://%s\r\nContent-Type: application/json\r\n%sContent-Length: %d\r\n\r\n"):format(HOST, HOST, cookie, 2 * 1024 * 1024))
check(s == 413, "oversized body refused")
check(c.run == nil and chat.chats[c.id].title == nil, "none of those reached the chat")

-- 3. the API
s, _, body = post("/api/prompt", prompt)
check(s == 200 and vim.json.decode(body).ok == true, "prompt accepted: " .. tostring(body))
check(vim.wait(3000, function() return c.run ~= nil end, 10), "prompt started a run in nvim")
check(vim.wait(5000, function() return c.run == nil end, 20), "run finished")
check(table.concat(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), "\n"):find("pong", 1, true), "answer in the chat")
s, _, body = post("/api/prompt", vim.json.encode({ nvim = 1, chat = 999, text = "x" }))
check(s == 409 and vim.json.decode(body).error == "no such chat", "unknown chat: 409")

-- SSE: snapshot first, then live events
local sse_data
request(("GET /events HTTP/1.1\r\nHost: %s\r\n%s\r\n"):format(HOST, cookie), function(d)
  sse_data = d
  return d:find('"type":"snapshot"', 1, true) ~= nil
end)
check(sse_data and sse_data:find("text/event-stream", 1, true) and sse_data:find("pong", 1, true), "SSE starts with a snapshot holding the transcript")

local r = tools.call("ask_user", { question = "Pick", choices = { "a", "b" } }, c.id)
local stream = ""
local call
local tcp = uv.new_tcp()
tcp:connect("127.0.0.1", port, function()
  tcp:write(("GET /events HTTP/1.1\r\nHost: %s\r\n%s\r\n"):format(HOST, cookie))
  tcp:read_start(function(_, chunk) if chunk then stream = stream .. chunk end end)
end)
vim.wait(2000, function()
  call = tonumber(stream:match('"type":"pending".-"call":(%d+)') or stream:match('"call":(%d+).-"type":"pending"'))
  return call ~= nil
end, 10)
check(call ~= nil, "open question is in the stream")
s, _, body = post("/api/answer", vim.json.encode({ nvim = 1, call = call, choice = "item", arg = 9 }))
check(s == 409 and body:find("does not take", 1, true), "out-of-range item refused, not dropped: " .. tostring(body))
s, _, body = post("/api/answer", vim.json.encode({ nvim = 1, call = call, choice = "item", arg = 2 }))
check(s == 200, "answer accepted: " .. tostring(body))
s, _, body = post("/api/answer", vim.json.encode({ nvim = 1, call = call, choice = "item", arg = 1 }))
check(s == 409, "a double submit before nvim resolved it is refused: " .. tostring(body))
vim.wait(2000, function() return not tools.is_pending(r.pending) end, 10)
check(tools.poll(r.pending).content[1].text == "b", "the web's pick reached the tool")
check(vim.wait(2000, function() return stream:find('"type":"resolved"', 1, true) ~= nil end, 10), "resolved pushed to the open stream")
s, _, body = post("/api/answer", vim.json.encode({ nvim = 1, call = call, choice = "item", arg = 1 }))
check(s == 409, "second answer refused: " .. tostring(body))
tcp:close()

-- 4. a port in use is reported, not fatal
web.stop()
vim.wait(2500) -- idle exit
local blocker = uv.new_tcp()
blocker:bind("127.0.0.1", port)
blocker:listen(1, function() end)
web.info = nil
local ok, ok2
web.start(function(v) ok = v end)
web.start(function(v) ok2 = v end) -- while the first connect is in flight
vim.wait(5000, function() return ok ~= nil and ok2 ~= nil and web.info ~= nil end, 20)
check(ok2 == true, "a start() during the connect is called back too")
local u, err = web.url()
check(ok and u == nil and err and err:find("cannot listen", 1, true), "busy port reported: " .. tostring(err))
blocker:close()
web.stop()
vim.wait(2500)
vim.fn.delete(dir, "rf")
t.finish()
