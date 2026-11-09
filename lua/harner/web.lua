-- nvim side of the harner host (host.lua): connects over the unix socket,
-- starting the host detached when nobody listens, and mirrors this nvim's
-- chats into it: metadata, transcript lines (nvim_buf_attach deltas) and the
-- questions waiting on the user. Answers, prompts and cancels coming back are
-- applied here, so a question can be answered from either side: whichever
-- answer arrives first wins and the other side closes.
--
-- Only loaded with `web.enabled`; chat.lua and tools.lua call into it through
-- package.loaded, so nothing runs when it is off. Losing the host only loses
-- the mirror: chats keep working and the next change reconnects.

local uv = vim.uv
local M = {}

local conn ---@type uv.uv_pipe_t|nil
local connecting = false
local waiting = {} ---@type fun(ok:boolean)[] start() callbacks until connected or given up
local attached = {} ---@type table<integer, integer> buf -> chat id
local open = {} ---@type table<integer, {msg: table, close: fun(choice:string, arg:any)}> by question id
local ask_seq = 0
-- set while an answer from the host is being applied (decision log `via`)
M.answering = false

local function cfg()
	return require("harner").config.web
end

---Directory of the socket: $XDG_RUNTIME_DIR/harner, else /tmp/harner-<uid>.
function M.socket_path()
	if cfg().socket then
		return cfg().socket
	end
	local base = os.getenv("XDG_RUNTIME_DIR")
	base = (base and base ~= "") and (base .. "/harner") or ("/tmp/harner-" .. uv.getuid())
	return base .. "/host.sock"
end

function M.connected()
	return conn ~= nil
end

local function send(obj)
	if conn and not conn:is_closing() then
		conn:write(vim.json.encode(obj) .. "\n")
	end
end

-- ---------------------------------------------------------------------------
-- Mirroring

local function chat_lines(c)
	if c.buf and vim.api.nvim_buf_is_valid(c.buf) and vim.api.nvim_buf_is_loaded(c.buf) then
		return vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)
	end
	return c.lines or { "" }
end

---Chat metadata changed (title, state, auto, running).
---@param c HarnerChat
function M.on_meta(c)
	send({
		type = "chat",
		chat = c.id,
		title = c.title or vim.NIL,
		state = c.state or vim.NIL,
		auto = c.auto == true,
		running = c.run ~= nil,
	})
end

---A chat got a (new) view buffer: send it whole and follow its changes.
---@param c HarnerChat
function M.on_buf(c)
	M.on_meta(c)
	send({ type = "lines", chat = c.id, first = 0, last = -1, lines = chat_lines(c) })
	local buf = c.buf
	if not buf or attached[buf] then
		return
	end
	attached[buf] = c.id
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, b, _, first, last_old, last_new)
			if conn then
				send({
					type = "lines",
					chat = attached[b],
					first = first,
					last = last_old,
					lines = vim.api.nvim_buf_get_lines(b, first, last_new, false),
				})
			end
		end,
		on_detach = function(_, b)
			attached[b] = nil
		end,
	})
end

---Keys a question accepts, as {key,label,value}: the float's own (confirm.keys) plus "no".
local function question_keys(opts)
	local keys = {}
	for _, k in ipairs(require("harner.confirm").keys(opts)) do
		keys[#keys + 1] = { key = k.key, label = k.label, value = k.value }
	end
	keys[#keys + 1] = { key = "n", label = "skip", value = "no" }
	return keys
end

---A confirm / question float opened (tools.lua's ask wrapper).
---@param cid integer|nil chat id
---@param opts table confirm opts (title, body, note, yes, always, choices, items, input)
---@param close fun(choice:string, arg:any) answers the float
---@return integer id, to pass to on_resolved
function M.on_pending(cid, opts, close)
	ask_seq = ask_seq + 1
	local msg = {
		type = "pending",
		call = ask_seq,
		chat = cid or vim.NIL,
		title = opts.title,
		body = opts.body,
		note = opts.note or vim.NIL,
		keys = question_keys(opts),
		items = opts.items or vim.NIL,
		input = opts.input == true,
	}
	open[ask_seq] = { msg = msg, close = close }
	send(msg)
	return ask_seq
end

---The question was answered (here or from the host) or cancelled.
function M.on_resolved(id)
	if open[id] then
		open[id] = nil
		send({ type = "resolved", call = id, by = M.answering and "web" or "nvim" })
	end
end

-- ---------------------------------------------------------------------------
-- Messages from the host (scheduled onto the main loop)

---Apply an answer from the host. Checks it against what the question offers.
---@return boolean ok, string|nil err
function M.apply_answer(id, choice, arg)
	local q = open[id]
	if not q then
		return false, "already answered"
	end
	local m = q.msg
	local valid = false
	if choice == "item" then
		valid = m.items ~= vim.NIL and type(arg) == "number" and m.items[arg] ~= nil
	elseif choice == "text" then
		valid = m.input and type(arg) == "string"
	else
		for _, k in ipairs(m.keys) do
			valid = valid or k.value == choice
		end
		arg = nil
	end
	if not valid then
		return false, "invalid answer"
	end
	M.answering = true
	local ok, err = pcall(q.close, choice, arg)
	M.answering = false
	if not ok then
		return false, tostring(err)
	end
	vim.notify("harner: answered from the web (" .. choice .. ")")
	return true
end

local function on_host_msg(msg)
	local chat = require("harner.chat")
	if msg.type == "answer" then
		M.apply_answer(tonumber(msg.call), msg.choice, msg.arg ~= vim.NIL and msg.arg or nil)
	elseif msg.type == "prompt" and type(msg.text) == "string" then
		local c = chat.chats[tonumber(msg.chat) or -1]
		if c then
			chat.ask(msg.text, c.origin_win, c.id)
		end
	elseif msg.type == "cancel" then
		chat.cancel_id(tonumber(msg.chat) or -1)
	elseif msg.type == "info" then
		M.info = {
			url = msg.url ~= vim.NIL and msg.url or nil,
			error = msg.error ~= vim.NIL and msg.error or nil,
		}
	end
end

---The sign-in URL (with the token), or nil and why not.
---@return string|nil url, string|nil err
function M.url()
	if not M.info then
		return nil, "not connected to the host yet"
	end
	if not M.info.url then
		return nil, M.info.error or "the host runs no web server"
	end
	return M.info.url .. "?token=" .. M.token()
end

---:HarnerWeb — connect if needed, then show the sign-in URL (also put in
---the + and " registers).
function M.show_url()
	if not cfg().enabled then
		vim.notify("harner: the web UI is off; set web = { enabled = true } in setup()", vim.log.levels.WARN)
		return
	end
	M.start(function(ok)
		if not ok then
			return
		end
		vim.wait(2000, function()
			return M.info ~= nil
		end, 20)
		local url, err = M.url()
		if not url then
			vim.notify("harner web: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		pcall(vim.fn.setreg, "+", url)
		vim.fn.setreg('"', url)
		vim.notify("harner web (copied): " .. url)
	end)
end

-- ---------------------------------------------------------------------------
-- Connection

local function host_script()
	return vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "host.lua")
end

---Path of the web token: stdpath("state")/harner/web-token (0600).
function M.token_path()
	return cfg().token_file or vim.fs.joinpath(vim.fn.stdpath("state"), "harner", "web-token")
end

---The web token, created on first use (48 hex chars from the OS RNG).
---@return string
function M.token()
	local path = M.token_path()
	local f = io.open(path, "r")
	local tok = f and f:read("*l")
	if f then
		f:close()
	end
	if tok and #tok >= 32 then
		return tok
	end
	tok = (uv.random(24):gsub(".", function(ch)
		return string.format("%02x", ch:byte())
	end))
	vim.fn.mkdir(vim.fs.dirname(path), "p", tonumber("700", 8))
	local fd = assert(uv.fs_open(path, "w", tonumber("600", 8)))
	uv.fs_write(fd, tok .. "\n")
	uv.fs_close(fd)
	return tok
end

-- what the host's HTTP server reported (url or error), from its `info`
M.info = nil ---@type { url: string|nil, error: string|nil }|nil

---Start the host detached (no stdio), so it outlives this nvim.
function M.spawn()
	local path = M.socket_path()
	vim.fn.mkdir(vim.fs.dirname(path), "p", tonumber("700", 8))
	M.token() -- the host reads it
	local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(host_script())))
	local opts = {
		socket = path,
		idle = cfg().idle_exit or 300,
		log = vim.fs.joinpath(vim.fn.stdpath("log"), "harner-host.log"),
		http = {
			host = cfg().host,
			port = cfg().port,
			token_file = M.token_path(),
			static = vim.fs.joinpath(root, "web"),
		},
	}
	local handle = uv.spawn(vim.v.progpath, {
		args = { "-l", host_script(), vim.json.encode(opts) },
		detached = true,
		stdio = { nil, nil, nil },
	}, function() end)
	if handle then
		handle:unref()
	end
	return handle ~= nil
end

---Send this nvim's whole state (after (re)connecting).
local function resync()
	send({ type = "hello", pid = uv.os_getpid(), cwd = vim.fn.getcwd() })
	for _, c in ipairs(require("harner.chat").list()) do
		M.on_meta(c)
		send({ type = "lines", chat = c.id, first = 0, last = -1, lines = chat_lines(c) })
	end
	for _, q in pairs(open) do
		send(q.msg)
	end
end

local function on_connected(pipe)
	conn = pipe
	connecting = false
	local buf = ""
	pipe:read_start(function(_, data)
		if data then
			buf = buf .. data
			local msgs = {}
			while true do
				local nl = buf:find("\n", 1, true)
				if not nl then
					break
				end
				local ok, msg = pcall(vim.json.decode, buf:sub(1, nl - 1))
				buf = buf:sub(nl + 1)
				if ok and type(msg) == "table" then
					msgs[#msgs + 1] = msg
				end
			end
			if #msgs > 0 then
				vim.schedule(function()
					for _, m in ipairs(msgs) do
						pcall(on_host_msg, m)
					end
				end)
			end
			return
		end
		-- host gone: drop the mirror; the next start() reconnects or respawns
		if not pipe:is_closing() then
			pipe:close()
		end
		vim.schedule(function()
			if conn == pipe then
				conn = nil
			end
		end)
	end)
	resync()
end

---Connect to the host, spawning it when nothing listens. Asynchronous;
---`done(ok)` runs on the main loop once connected or given up.
---@param done fun(ok:boolean)|nil
function M.start(done)
	done = done or function() end
	if conn then
		return done(true)
	end
	waiting[#waiting + 1] = done
	if connecting then
		return
	end
	connecting = true
	local function finish(ok)
		local cbs = waiting
		waiting = {}
		for _, cb in ipairs(cbs) do
			pcall(cb, ok)
		end
	end
	local path = M.socket_path()
	local tries = 0
	local function attempt()
		local pipe = uv.new_pipe(false)
		pipe:connect(path, function(err)
			vim.schedule(function()
				if not err then
					on_connected(pipe)
					return finish(true)
				end
				pipe:close()
				tries = tries + 1
				if tries == 1 then
					M.spawn()
				end
				if tries > 50 then
					connecting = false
					vim.notify("harner: cannot reach the web host at " .. path, vim.log.levels.WARN)
					return finish(false)
				end
				vim.defer_fn(attempt, 100)
			end)
		end)
	end
	attempt()
end

---Reconnect if the host went away (called before a run starts).
function M.ensure()
	if not conn and not connecting then
		M.start()
	end
end

function M.stop()
	if conn and not conn:is_closing() then
		conn:close()
	end
	conn = nil
end

return M
