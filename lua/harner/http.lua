-- Minimal HTTP/1.1 server for the harner host (loaded by host.lua with
-- dofile, runs in uv callbacks: no nvim API). Serves the page from web/,
-- streams the host's events as SSE and takes answers, prompts and cancels.
--
-- It can approve shell commands, so every request is checked:
--   * a token, from `?token=` once (moved into an HttpOnly SameSite=Strict
--     cookie by a redirect) or that cookie; the cookie is bound to the name
--     the page was signed in under, so a rebinding hostile name has none.
--     Any Host header is accepted otherwise
--   * POSTs also need Origin == http://<Host> and a JSON content type
--     (cross-site forms can send neither)
--   * every response carries a strict CSP (scripts only from here, no
--     inline), nosniff, no framing, no-store
-- One request per connection (Connection: close), except /events.

local uv = vim.uv

local H = {}

local MAX_HEAD = 16 * 1024
local MAX_BODY = 1024 * 1024
local COOKIE = "harner_token"

local STATIC = {
	["/"] = { "index.html", "text/html; charset=utf-8" },
	["/app.js"] = { "app.js", "text/javascript; charset=utf-8" },
	["/app.css"] = { "app.css", "text/css; charset=utf-8" },
	["/marked.umd.js"] = { "marked.umd.js", "text/javascript; charset=utf-8" },
}

local SECURITY = {
	"Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; "
		.. "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
	"X-Content-Type-Options: nosniff",
	"X-Frame-Options: DENY",
	"Referrer-Policy: no-referrer",
	"Cache-Control: no-store",
}

local REASONS = {
	[200] = "OK",
	[303] = "See Other",
	[400] = "Bad Request",
	[401] = "Unauthorized",
	[403] = "Forbidden",
	[404] = "Not Found",
	[405] = "Method Not Allowed",
	[409] = "Conflict",
	[413] = "Payload Too Large",
	[415] = "Unsupported Media Type",
	[431] = "Request Header Fields Too Large",
}

local function read_file(path)
	local fd = uv.fs_open(path, "r", 0)
	if not fd then
		return nil
	end
	local stat = uv.fs_fstat(fd)
	local data = stat and uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	return data
end

---Constant-time string comparison (the token).
local function same(a, b)
	if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
		return false
	end
	local diff = 0
	for i = 1, #a do
		diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
	end
	return diff == 0
end

local function url_decode(s)
	return (s:gsub("%+", " "):gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

local function close(client)
	if not client:is_closing() then
		client:close()
	end
end

---Write a whole response and close the connection.
local function respond(client, status, headers, body)
	body = body or ""
	local out = { "HTTP/1.1 " .. status .. " " .. (REASONS[status] or "") }
	vim.list_extend(out, SECURITY)
	vim.list_extend(out, headers or {})
	out[#out + 1] = "Content-Length: " .. #body
	out[#out + 1] = "Connection: close"
	if client:is_closing() then
		return
	end
	client:write(table.concat(out, "\r\n") .. "\r\n\r\n" .. body, function()
		if not client:is_closing() then
			client:shutdown(function()
				close(client)
			end)
		end
	end)
end

local function json(client, status, obj)
	respond(client, status, { "Content-Type: application/json" }, vim.json.encode(obj))
end

local function text(client, status, msg)
	respond(client, status, { "Content-Type: text/plain; charset=utf-8" }, msg .. "\n")
end

---Parse the head of a request. nil while incomplete; false on garbage.
local function parse_head(buf)
	local stop = buf:find("\r\n\r\n", 1, true)
	if not stop then
		return nil
	end
	local head = buf:sub(1, stop - 1)
	local method, target = head:match("^(%u+) (%S+) HTTP/1%.[01]\r?\n?")
	if not method then
		return false
	end
	local headers = {}
	for name, value in head:gmatch("\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
		headers[name:lower()] = value
	end
	local path, query = target:match("^([^?#]*)%??([^#]*)")
	local params = {}
	for k, v in (query or ""):gmatch("([^&=]+)=?([^&]*)") do
		params[url_decode(k)] = url_decode(v)
	end
	return { method = method, path = path, params = params, headers = headers, body_at = stop + 4 }
end

---@param host table the host module (snapshot, answer, prompt, cancel, sinks)
---@param o { host: string, port: integer, token: string, static: string }
---@return table|nil server, string|nil err
function H.start(host, o)
	local port = tonumber(o.port)

	local function authed(req)
		local cookie = (req.headers.cookie or ""):match(COOKIE .. "=([%w]+)")
		return same(cookie, o.token)
	end

	local function serve_events(client)
		local head = { "HTTP/1.1 200 OK" }
		vim.list_extend(head, SECURITY)
		vim.list_extend(head, { "Content-Type: text/event-stream", "Connection: keep-alive" })
		client:write(table.concat(head, "\r\n") .. "\r\n\r\nretry: 2000\n\n")
		local function sink(msg)
			if not client:is_closing() then
				client:write("data: " .. vim.json.encode(msg) .. "\n\n")
			end
		end
		sink(host.snapshot())
		host.sinks[sink] = true
		local ping = uv.new_timer()
		ping:start(20000, 20000, function()
			if client:is_closing() then
				return
			end
			client:write(": ping\n\n")
		end)
		local function gone()
			host.sinks[sink] = nil
			ping:stop()
			ping:close()
			close(client)
		end
		return gone
	end

	local function handle_post(client, req, body)
		local origin = req.headers.origin
		if not origin or origin:lower() ~= "http://" .. (req.headers.host or ""):lower() then
			return text(client, 403, "cross-origin request refused")
		end
		if not (req.headers["content-type"] or ""):lower():match("^application/json") then
			return text(client, 415, "send application/json")
		end
		local ok, msg = pcall(vim.json.decode, body)
		if not ok or type(msg) ~= "table" then
			return json(client, 400, { ok = false, error = "bad json" })
		end
		local arg = msg.arg ~= vim.NIL and msg.arg or nil
		local done, err
		if req.path == "/api/answer" then
			done, err = host.answer(msg.nvim, msg.call, msg.choice, arg)
		elseif req.path == "/api/prompt" then
			done, err = host.prompt(msg.nvim, msg.chat, msg.text)
		elseif req.path == "/api/cancel" then
			done, err = host.cancel(msg.nvim, msg.chat)
		else
			return text(client, 404, "not found")
		end
		if done then
			json(client, 200, { ok = true })
		else
			json(client, 409, { ok = false, error = err })
		end
	end

	---A complete request. Returns a cleanup function for streams.
	local function handle(client, req, body)
		if req.method == "GET" and req.path == "/" and req.params.token then
			if not same(req.params.token, o.token) then
				return text(client, 401, "wrong token: open the URL :HarnerWeb shows")
			end
			-- move the token out of the URL (history, screenshots) into a cookie
			return respond(client, 303, {
				"Location: /",
				string.format("Set-Cookie: %s=%s; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000", COOKIE, o.token),
			})
		end
		if not authed(req) then
			return text(client, 401, "not signed in: open the URL :HarnerWeb shows")
		end
		if req.method == "GET" then
			if req.path == "/events" then
				return serve_events(client)
			end
			local f = STATIC[req.path]
			local data = f and read_file(o.static .. "/" .. f[1])
			if not data then
				return text(client, 404, "not found")
			end
			return respond(client, 200, { "Content-Type: " .. f[2] }, data)
		elseif req.method == "POST" then
			return handle_post(client, req, body)
		end
		text(client, 405, "method not allowed")
	end

	local server = uv.new_tcp()
	local ok, err = server:bind(o.host, port)
	if not ok then
		server:close()
		return nil, err
	end
	ok, err = server:listen(64, function(lerr)
		if lerr then
			return
		end
		local client = uv.new_tcp()
		server:accept(client)
		local buf, req = "", nil
		local cleanup
		client:read_start(function(rerr, data)
			if rerr or not data then
				if cleanup then
					cleanup()
				end
				close(client)
				return
			end
			if req and req.done then
				return -- one request per connection
			end
			buf = buf .. data
			if not req then
				local parsed = parse_head(buf)
				if parsed == false then
					req = { done = true }
					return text(client, 400, "bad request")
				end
				if parsed == nil then
					if #buf > MAX_HEAD then
						req = { done = true }
						text(client, 431, "headers too large")
					end
					return
				end
				req = parsed
				if req.headers["transfer-encoding"] then
					req.done = true
					return text(client, 400, "chunked bodies are not supported")
				end
				req.length = tonumber(req.headers["content-length"] or "0") or 0
				if req.length > MAX_BODY then
					req.done = true
					return text(client, 413, "body too large")
				end
			end
			local body = buf:sub(req.body_at)
			if #body < req.length then
				return
			end
			req.done = true
			local okh, res = pcall(handle, client, req, body:sub(1, req.length))
			if not okh then
				text(client, 400, "error: " .. tostring(res))
			elseif type(res) == "function" then
				cleanup = res
			end
		end)
	end)
	if not ok then
		server:close()
		return nil, err
	end
	return server
end

return H
