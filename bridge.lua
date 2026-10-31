-- MCP stdio server run as `nvim -l bridge.lua` by the claude CLI.
-- Forwards tools/list and tools/call to the parent Neovim over RPC.
-- Never use print() here: stdout is the MCP channel.
--
-- Async tools (ask_user, run_command) answer `{ pending = id }`; the bridge
-- then polls `tools.poll(id)` until the user has answered, so the parent's
-- main loop stays free for vim.ui.select / vim.ui.input.

local POLL_MS = 100
local POLL_TIMEOUT_MS = 10 * 60 * 1000

local function log(msg)
	io.stderr:write("[harner-bridge] " .. tostring(msg) .. "\n")
end

local addr = os.getenv("HARNER_NVIM") or os.getenv("NVIM")
if not addr or addr == "" then
	log("no HARNER_NVIM/NVIM address in environment")
	os.exit(1)
end

local ok, chan = pcall(vim.fn.sockconnect, "pipe", addr, { rpc = true })
if not ok or chan == 0 then
	log("cannot connect to nvim at " .. addr .. ": " .. tostring(chan))
	os.exit(1)
end

local function nvim_call(code, args)
	return vim.rpcrequest(chan, "nvim_exec_lua", code, args or {})
end

local function send(obj)
	io.stdout:write(vim.json.encode(obj), "\n")
	io.stdout:flush()
end

local function reply(id, result)
	send({ jsonrpc = "2.0", id = id, result = result })
end

local function reply_error(id, code, message)
	send({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

local function error_result(text)
	return { content = { { type = "text", text = text } }, isError = true }
end

local handlers = {}

handlers["initialize"] = function(params)
	return {
		protocolVersion = (params and params.protocolVersion) or "2025-06-18",
		capabilities = { tools = vim.empty_dict() },
		serverInfo = { name = "harner-nvim", version = "0.2.0" },
	}
end

handlers["ping"] = function()
	return vim.empty_dict()
end

handlers["tools/list"] = function()
	local tools = nvim_call("return require('harner.tools').list()")
	return { tools = tools }
end

---Wait for an async tool call to finish in the parent.
---@param id integer
local function wait_pending(id)
	local waited = 0
	while true do
		vim.uv.sleep(POLL_MS)
		waited = waited + POLL_MS
		local okp, got = pcall(nvim_call, "return require('harner.tools').poll(...)", { id })
		if not okp then
			return error_result("nvim rpc error while waiting: " .. tostring(got))
		end
		if got ~= nil and got ~= vim.NIL then
			return got
		end
		if waited >= POLL_TIMEOUT_MS then
			pcall(nvim_call, "require('harner.tools').cancel_pending(...)", { "timed out waiting for the user", id })
			return error_result("timed out waiting for the user to answer")
		end
	end
end

handlers["tools/call"] = function(params)
	local name = params and params.name
	local args = (params and params.arguments) or vim.empty_dict()
	local ok2, res = pcall(nvim_call, "return require('harner.tools').call(...)", { name, args })
	if not ok2 then
		return error_result("nvim rpc error: " .. tostring(res))
	end
	if type(res) == "table" and res.pending then
		return wait_pending(res.pending)
	end
	return res
end

for line in io.lines() do
	if line ~= "" then
		local okd, msg = pcall(vim.json.decode, line)
		if not okd or type(msg) ~= "table" then
			log("bad json: " .. line)
		else
			local method, id = msg.method, msg.id
			if method then
				local h = handlers[method]
				if h then
					local okh, result = pcall(h, msg.params)
					if id ~= nil then
						if okh then
							reply(id, result)
						else
							reply_error(id, -32603, tostring(result))
						end
					end
				elseif id ~= nil then
					-- notifications/* without a handler are silently ignored
					reply_error(id, -32601, "method not found: " .. method)
				end
			end
			-- responses to server-initiated requests: none are sent, ignore
		end
	end
end

pcall(vim.fn.chanclose, chan)
