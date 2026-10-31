-- Spawns `claude -p` and parses its stream-json output.

local M = {}

---@class HarnerRun
---@field proc vim.SystemObj|nil
---@field session_id string

---@param opts {prompt:string, session_id:string, resume:boolean, cwd:string,
---  on_text:fun(text:string), on_tool:fun(name:string), on_done:fun(result:table|nil),
---  on_error:fun(msg:string), on_tool_input:fun(name:string, input:table)|nil}
---@return HarnerRun
function M.start(opts)
	local config = require("harner").config
	local mcp = require("harner.mcp")

	if vim.fn.executable(config.claude_cmd) ~= 1 then
		-- report asynchronously so the caller has stored the run before on_done clears it
		vim.schedule(function()
			opts.on_error(
				("`%s` not found on PATH; install the Claude CLI or set claude_cmd in require('harner').setup()"):format(
					config.claude_cmd
				)
			)
			opts.on_done(nil)
		end)
		return { proc = nil, session_id = opts.session_id }
	end

	local mcp_path = mcp.write_config()

	local args = {
		config.claude_cmd,
		"-p",
		"--output-format",
		"stream-json",
		"--verbose",
		"--include-partial-messages",
		"--mcp-config",
		mcp_path,
		"--strict-mcp-config",
		"--tools",
		table.concat(config.builtin_tools, ","),
		"--allowedTools",
		table.concat(vim.list_extend(vim.deepcopy(config.builtin_tools), config.allowed_tools), ","),
		"--append-system-prompt",
		mcp.system_note(opts.cwd),
	}
	if opts.resume then
		vim.list_extend(args, { "--resume", opts.session_id })
	else
		vim.list_extend(args, { "--session-id", opts.session_id })
	end
	if config.model then
		vim.list_extend(args, { "--model", config.model })
	end
	vim.list_extend(args, config.extra_args or {})

	local pending = ""
	local got_stream = false
	local stderr = {}
	local result = nil
	-- tool_use blocks in flight, by content block index: their input streams
	-- as input_json_delta fragments and is complete at content_block_stop
	local blocks = {}

	local function tool_input(name, input)
		if opts.on_tool_input and type(input) == "table" then
			opts.on_tool_input(name, input)
		end
	end

	local function handle_event(ev)
		if ev.type == "stream_event" and ev.event then
			got_stream = true
			local e = ev.event
			if e.type == "content_block_delta" and e.delta then
				if e.delta.type == "text_delta" then
					opts.on_text(e.delta.text)
				elseif e.delta.type == "input_json_delta" and blocks[e.index] then
					blocks[e.index].json = blocks[e.index].json .. (e.delta.partial_json or "")
				end
			elseif e.type == "content_block_start" and e.content_block and e.content_block.type == "tool_use" then
				blocks[e.index] = { name = e.content_block.name, json = "" }
				opts.on_tool(e.content_block.name)
			elseif e.type == "content_block_stop" and blocks[e.index] then
				local b = blocks[e.index]
				blocks[e.index] = nil
				local ok, input = pcall(vim.json.decode, b.json ~= "" and b.json or "{}")
				if ok then
					tool_input(b.name, input)
				end
			end
		elseif ev.type == "assistant" and not got_stream and ev.message and ev.message.content then
			-- fallback when partial messages are not streamed
			for _, block in ipairs(ev.message.content) do
				if block.type == "text" then
					opts.on_text(block.text)
				elseif block.type == "tool_use" then
					opts.on_tool(block.name)
					tool_input(block.name, block.input)
				end
			end
		elseif ev.type == "result" or ev.duration_api_ms then
			result = ev
			if ev.is_error then
				opts.on_error(ev.result or (ev.errors and table.concat(ev.errors, "\n")) or "claude returned an error")
			end
		end
	end

	local function on_stdout(_, data)
		if not data then
			return
		end
		pending = pending .. data
		local lines = {}
		while true do
			local nl = pending:find("\n", 1, true)
			if not nl then
				break
			end
			table.insert(lines, pending:sub(1, nl - 1))
			pending = pending:sub(nl + 1)
		end
		if #lines == 0 then
			return
		end
		vim.schedule(function()
			for _, line in ipairs(lines) do
				if line ~= "" then
					local ok, ev = pcall(vim.json.decode, line)
					if ok and type(ev) == "table" then
						handle_event(ev)
					end
				end
			end
		end)
	end

	local proc = vim.system(args, {
		cwd = opts.cwd,
		stdin = opts.prompt,
		stdout = on_stdout,
		stderr = function(_, data)
			if data then
				table.insert(stderr, data)
			end
		end,
		env = { HARNER_NVIM = mcp.server_address() },
	}, function(obj)
		vim.schedule(function()
			os.remove(mcp_path)
			if obj.code ~= 0 and obj.signal == 0 and not result then
				local err = table.concat(stderr):gsub("%s+$", "")
				opts.on_error(("claude exited with code %d%s"):format(obj.code, err ~= "" and ("\n" .. err) or ""))
			end
			opts.on_done(result)
		end)
	end)

	return { proc = proc, session_id = opts.session_id }
end

---@param run HarnerRun
function M.cancel(run)
	if run and run.proc then
		run.proc:kill("sigterm")
	end
end

return M
