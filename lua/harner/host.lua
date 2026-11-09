-- harner host: one per user, run detached as
--   nvim -l host.lua '<json options>'   (see the bottom of this file)
-- Every nvim with `web.enabled` connects over the unix socket and mirrors its
-- chats here (metadata, transcript lines, pending questions). Watchers (the
-- HTTP server's SSE streams, socket watchers in tests) read that state and
-- send answers, prompts and cancels back to the owning nvim. The host keeps no claude processes: runs
-- live in their nvim. When an nvim goes away its chats stay as read-only
-- snapshots until the host exits, which it does `idle_seconds` after the
-- last nvim disconnected.
--
-- Protocol: one JSON object per line, both directions.
--   nvim -> host: hello{pid,cwd} chat{chat,title,state,auto,running}
--                 lines{chat,first,last,lines} (0-based, end-exclusive, -1 = end)
--                 pending{call,chat,title,body,note,keys,items,input} resolved{call,by}
--   host -> nvim: answer{call,choice,arg} prompt{chat,text} cancel{chat}
--   watcher -> host: watch  answer{nvim,call,choice,arg}  prompt{nvim,chat,text}  cancel{nvim,chat}
--   host -> watcher: snapshot{nvims}, then every nvim message with `nvim` added,
--                    gone{nvim}, error{message}
-- Never print(): stdout is not connected. Runs in uv callbacks only, so no
-- nvim API calls (vim.json and vim.uv are fine).

local uv = vim.uv

local M = {}

---@class HarnerHostChat
---@field id integer
---@field title string|nil
---@field state string|nil
---@field auto boolean|nil
---@field running boolean|nil
---@field lines string[]

---@class HarnerHostNvim
---@field id integer
---@field pid integer|nil
---@field cwd string|nil
---@field gone boolean
---@field chats table<integer, HarnerHostChat>
---@field pending table<integer, table> open questions by call id
---@field conn uv.uv_pipe_t|nil

---@type table<integer, HarnerHostNvim>
M.nvims = {}
---@type table<uv.uv_pipe_t, true>
M.watchers = {}
-- extra event sinks (the HTTP server's SSE streams), set of fun(msg)
---@type table<fun(msg:table), true>
M.sinks = {}
-- what the HTTP server ended up doing, told to every nvim on hello
M.info = { type = "info", url = vim.NIL, error = vim.NIL }

local seq = 0
local server ---@type uv.uv_pipe_t
local idle_timer ---@type uv.uv_timer_t
local opts = { socket = nil, idle = 300, log = nil }
M.stopped = false

local function log(msg)
	if not opts.log then
		return
	end
	local fd = uv.fs_open(opts.log, "a", 384)
	if fd then
		uv.fs_write(fd, os.date("%H:%M:%S ") .. tostring(msg) .. "\n")
		uv.fs_close(fd)
	end
end

local function write(conn, obj)
	if conn and not conn:is_closing() then
		conn:write(vim.json.encode(obj) .. "\n")
	end
end

---Send an event to every watcher and sink.
function M.broadcast(obj)
	for w in pairs(M.watchers) do
		write(w, obj)
	end
	for sink in pairs(M.sinks) do
		pcall(sink, obj)
	end
end

local function line_reader(on_msg)
	local buf = ""
	return function(data)
		buf = buf .. data
		while true do
			local nl = buf:find("\n", 1, true)
			if not nl then
				return
			end
			local line = buf:sub(1, nl - 1)
			buf = buf:sub(nl + 1)
			if line ~= "" then
				local ok, msg = pcall(vim.json.decode, line)
				if ok and type(msg) == "table" then
					local okh, err = pcall(on_msg, msg)
					if not okh then
						log("handler error: " .. tostring(err))
					end
				end
			end
		end
	end
end

---Replace lines [first, last) of `t` (0-based, -1 = end) with `new`.
---@return string[]
function M.splice(t, first, last, new)
	local n = #t
	first = math.max(0, math.min(first < 0 and n or first, n))
	last = last < 0 and n or math.min(last, n)
	if last < first then
		last = first
	end
	local out = {}
	for i = 1, first do
		out[#out + 1] = t[i]
	end
	for _, l in ipairs(new) do
		out[#out + 1] = l
	end
	for i = last + 1, n do
		out[#out + 1] = t[i]
	end
	return out
end

local function chat_of(nv, id)
	id = tonumber(id)
	if not id then
		return nil
	end
	local c = nv.chats[id]
	if not c then
		c = { id = id, lines = { "" } }
		nv.chats[id] = c
	end
	return c
end

-- ---------------------------------------------------------------------------
-- Idle exit

local function live_count()
	local n = 0
	for _, nv in pairs(M.nvims) do
		if not nv.gone then
			n = n + 1
		end
	end
	return n
end

function M.stop()
	if M.stopped then
		return
	end
	M.stopped = true
	log("stopping")
	if server and not server:is_closing() then
		server:close()
	end
	if opts.socket then
		uv.fs_unlink(opts.socket)
	end
	if M.on_stop then
		pcall(M.on_stop)
	end
end

local function check_idle()
	if live_count() > 0 then
		idle_timer:stop()
	elseif not idle_timer:is_active() then
		idle_timer:start(opts.idle * 1000, 0, function()
			if live_count() == 0 then
				M.stop()
			end
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Snapshot (watchers, the web page)

---The whole state, chats as arrays sorted by id.
function M.snapshot()
	local nvims = {}
	for _, nv in pairs(M.nvims) do
		local chats = {}
		for _, c in pairs(nv.chats) do
			chats[#chats + 1] = c
		end
		table.sort(chats, function(a, b)
			return a.id < b.id
		end)
		local pending = {}
		for _, p in pairs(nv.pending) do
			pending[#pending + 1] = p
		end
		table.sort(pending, function(a, b)
			return a.call < b.call
		end)
		nvims[#nvims + 1] = { id = nv.id, pid = nv.pid, cwd = nv.cwd, gone = nv.gone, chats = chats, pending = pending }
	end
	table.sort(nvims, function(a, b)
		return a.id < b.id
	end)
	return { type = "snapshot", nvims = nvims }
end

-- ---------------------------------------------------------------------------
-- Commands towards an nvim (socket watchers and the HTTP API)

---@return string|nil err
local function live(nvim_id)
	local nv = M.nvims[tonumber(nvim_id) or -1]
	if not nv then
		return nil, "no such nvim"
	end
	if nv.gone then
		return nil, "that nvim has exited; its chats are read-only"
	end
	return nv
end

---Answer an open question. `arg` is the item index or the typed text.
---@return boolean ok, string|nil err
function M.answer(nvim_id, call, choice, arg)
	local nv, err = live(nvim_id)
	if not nv then
		return false, err
	end
	call = tonumber(call)
	local q = call and nv.pending[call]
	if not q then
		return false, "that question was already answered"
	end
	if type(choice) ~= "string" then
		return false, "choice is required"
	end
	-- the same checks web.apply_answer makes in nvim, so a rejected answer is
	-- an error here instead of a silent drop there
	local valid = false
	if choice == "item" then
		valid = type(q.items) == "table" and type(arg) == "number" and q.items[arg] ~= nil
	elseif choice == "text" then
		valid = q.input == true and type(arg) == "string"
	else
		for _, k in ipairs(type(q.keys) == "table" and q.keys or {}) do
			valid = valid or k.value == choice
		end
		arg = nil
	end
	if not valid then
		return false, "that question does not take this answer"
	end
	-- forwarded: a second submit before nvim's `resolved` is refused
	nv.pending[call] = nil
	write(nv.conn, { type = "answer", call = call, choice = choice, arg = arg })
	return true
end

---Send a prompt to a chat of a live nvim.
function M.prompt(nvim_id, chat, text)
	local nv, err = live(nvim_id)
	if not nv then
		return false, err
	end
	local c = nv.chats[tonumber(chat) or -1]
	if not c then
		return false, "no such chat"
	end
	-- nvim would refuse it with a warning only it shows
	if c.running then
		return false, "that chat is still running"
	end
	if type(text) ~= "string" or vim.trim(text) == "" then
		return false, "text is required"
	end
	write(nv.conn, { type = "prompt", chat = tonumber(chat), text = text })
	return true
end

function M.cancel(nvim_id, chat)
	local nv, err = live(nvim_id)
	if not nv then
		return false, err
	end
	write(nv.conn, { type = "cancel", chat = tonumber(chat) })
	return true
end

-- ---------------------------------------------------------------------------
-- Connections

local function on_nvim_msg(nv, msg)
	local t = msg.type
	if t == "hello" then
		nv.pid, nv.cwd = msg.pid, msg.cwd
		-- a reconnecting nvim resends everything
		nv.chats, nv.pending = {}, {}
	elseif t == "chat" then
		local c = chat_of(nv, msg.chat)
		if not c then
			return
		end
		for _, k in ipairs({ "title", "state", "auto", "running" }) do
			if msg[k] ~= nil then
				c[k] = msg[k] ~= vim.NIL and msg[k] or nil
			end
		end
	elseif t == "lines" then
		local c = chat_of(nv, msg.chat)
		if not c or type(msg.lines) ~= "table" then
			return
		end
		c.lines = M.splice(c.lines, tonumber(msg.first) or 0, tonumber(msg.last) or -1, msg.lines)
	elseif t == "pending" then
		local call = tonumber(msg.call)
		if not call then
			return
		end
		msg.call = call
		nv.pending[call] = msg
	elseif t == "resolved" then
		nv.pending[tonumber(msg.call) or -1] = nil
	else
		return
	end
	msg.nvim = nv.id
	M.broadcast(msg)
end

local function on_watcher_msg(conn, msg)
	local ok, err
	if msg.type == "answer" then
		ok, err = M.answer(msg.nvim, msg.call, msg.choice, msg.arg)
	elseif msg.type == "prompt" then
		ok, err = M.prompt(msg.nvim, msg.chat, msg.text)
	elseif msg.type == "cancel" then
		ok, err = M.cancel(msg.nvim, msg.chat)
	else
		return
	end
	if not ok then
		write(conn, { type = "error", message = err })
	end
end

local function on_connection(err)
	if err then
		log("accept error: " .. err)
		return
	end
	local conn = uv.new_pipe(false)
	server:accept(conn)
	local nv ---@type HarnerHostNvim|nil
	local watcher = false
	local read = line_reader(function(msg)
		if watcher then
			on_watcher_msg(conn, msg)
		elseif nv then
			on_nvim_msg(nv, msg)
		elseif msg.type == "watch" then
			watcher = true
			M.watchers[conn] = true
			write(conn, M.snapshot())
		elseif msg.type == "hello" then
			seq = seq + 1
			nv = { id = seq, gone = false, chats = {}, pending = {}, conn = conn }
			M.nvims[seq] = nv
			log("nvim " .. seq .. " connected (pid " .. tostring(msg.pid) .. ")")
			check_idle()
			write(conn, M.info)
			on_nvim_msg(nv, msg)
		end
	end)
	conn:read_start(function(rerr, data)
		if data then
			read(data)
			return
		end
		-- EOF or error: the peer is gone
		if rerr then
			log("read error: " .. rerr)
		end
		if not conn:is_closing() then
			conn:close()
		end
		if watcher then
			M.watchers[conn] = nil
		elseif nv then
			nv.gone, nv.conn, nv.pending = true, nil, {}
			for _, c in pairs(nv.chats) do
				c.running = false
			end
			log("nvim " .. nv.id .. " gone")
			M.broadcast({ type = "gone", nvim = nv.id })
			check_idle()
		end
	end)
end

---Bind the socket. Returns false when another host already serves it.
---@return boolean ok, string|nil err
function M.listen(o)
	opts = vim.tbl_extend("force", opts, o)
	-- a live host answers a connect: leave it be; a stale socket file is removed
	if uv.fs_stat(opts.socket) then
		local probe = uv.new_pipe(false)
		local alive = nil
		probe:connect(opts.socket, function(cerr)
			alive = cerr == nil
		end)
		while alive == nil do
			uv.run("once")
		end
		probe:close()
		if alive then
			return false, "another host is running"
		end
		uv.fs_unlink(opts.socket)
	end
	server = uv.new_pipe(false)
	local ok, err = server:bind(opts.socket)
	if not ok then
		return false, err
	end
	uv.fs_chmod(opts.socket, 384) -- 0600
	server:listen(16, on_connection)
	idle_timer = uv.new_timer()
	check_idle()
	log("listening on " .. opts.socket)
	return true
end

---Start the HTTP server (http.lua next to this file). Failure is kept in
---M.info for the nvims (:HarnerWeb shows it); the socket side keeps working.
---@param o { host: string, port: integer, token_file: string, static: string }
function M.serve_http(o)
	local fd = uv.fs_open(o.token_file, "r", 0)
	local token = fd and uv.fs_read(fd, 256, 0)
	if fd then
		uv.fs_close(fd)
	end
	token = token and token:match("^%s*(%w+)")
	if not token or #token < 32 then
		M.info.error = "no usable token in " .. o.token_file
		return
	end
	local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$")
	local http = dofile(here .. "/http.lua")
	local server, err = http.start(M, {
		host = o.host,
		port = o.port,
		token = token,
		static = o.static,
	})
	if not server then
		M.info.error = ("cannot listen on %s:%s: %s"):format(o.host, tostring(o.port), tostring(err))
		log(M.info.error)
		return
	end
	local shown = o.host:find(":", 1, true) and ("[" .. o.host .. "]") or o.host
	M.info.url = ("http://%s:%d/"):format(shown, o.port)
	log("http on " .. M.info.url)
end

-- Run as a script: `nvim -l host.lua '<json options>'` with socket, idle, log
-- and http = { host, port, token_file, static }.
if arg and type(arg[0]) == "string" and arg[0]:match("host%.lua$") and arg[1] then
	local okj, o = pcall(vim.json.decode, arg[1])
	if not okj or type(o) ~= "table" then
		os.exit(1)
	end
	local ok, err = M.listen({ socket = o.socket, idle = tonumber(o.idle) or 300, log = o.log })
	if not ok then
		log("not starting: " .. tostring(err))
		os.exit(0)
	end
	if type(o.http) == "table" then
		M.serve_http(o.http)
	end
	while not M.stopped do
		uv.run("once")
	end
	os.exit(0)
end

return M
