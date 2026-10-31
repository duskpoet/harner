-- Tool definitions and handlers executed inside the user's Neovim.
-- `list()` feeds MCP tools/list, `call()` serves tools/call.
--
-- Synchronous tools return a string from `handler(args)`. Tools that need the
-- main loop free (anything waiting on the user) set `async = true` and get a
-- `resolve(text, is_error)` callback instead; `call()` then answers with
-- `{ pending = id }` and the bridge polls `poll(id)` until the result lands.

local M = {}

local function text_result(text, is_error)
	return { content = { { type = "text", text = text } }, isError = is_error or false }
end

local function schema(props, required)
	return {
		type = "object",
		properties = (next(props) == nil) and vim.empty_dict() or props,
		required = required or {},
	}
end

local function target_win()
	return require("harner.chat").target_win()
end

local function buf_info(buf)
	return {
		bufnr = buf,
		name = vim.api.nvim_buf_get_name(buf),
		filetype = vim.bo[buf].filetype,
		modified = vim.bo[buf].modified,
		lines = vim.api.nvim_buf_line_count(buf),
	}
end

---@class HarnerTool
---@field description string
---@field inputSchema table
---@field async boolean|nil
---@field handler fun(args:table, resolve:fun(text:string, is_error:boolean|nil)|nil):string|nil

---@type table<string, HarnerTool>
M.tools = {}

M.tools.show_text = {
	description = "Display text to the user in an editor window. Use this for anything longer than a few lines: "
		.. "code snippets, diffs, generated files, tables, long explanations. Keep the chat reply itself short "
		.. "and refer to what you displayed.",
	inputSchema = schema({
		title = { type = "string", description = "Short title shown on the window" },
		content = { type = "string", description = "The text to display" },
		filetype = {
			type = "string",
			description = "Neovim filetype for highlighting, e.g. markdown, diff, lua, python. Defaults to markdown.",
		},
	}, { "content" }),
	handler = function(args)
		local cfg = require("harner").config.show_text
		local lines = vim.split(args.content or "", "\n", { plain = true })
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = args.filetype or "markdown"
		vim.bo[buf].modifiable = false
		local title = args.title or "harner"
		pcall(vim.api.nvim_buf_set_name, buf, string.format("harner://show/%d %s", buf, title))

		local win
		if cfg.mode == "float" then
			local width = math.min(math.floor(vim.o.columns * 0.8), math.max(40, cfg.float_width or 100))
			local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.8))
			win = vim.api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				row = math.floor((vim.o.lines - height) / 2) - 1,
				col = math.floor((vim.o.columns - width) / 2),
				style = "minimal",
				border = "rounded",
				title = " " .. title .. " ",
				title_pos = "center",
			})
		else
			local tw = target_win()
			vim.api.nvim_set_current_win(tw)
			vim.cmd(cfg.mode == "vsplit" and "vsplit" or "split")
			win = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(win, buf)
			vim.wo[win].winbar = "%#Title# " .. title:gsub("%%", "%%%%") .. " %*"
		end
		vim.wo[win].wrap = true
		vim.keymap.set("n", "q", "<cmd>close<CR>", { buffer = buf, nowait = true, desc = "Close harner window" })
		return string.format("Displayed %d lines titled %q to the user.", #lines, title)
	end,
}

local open_ns = vim.api.nvim_create_namespace("harner_open_file")

---Resolve a user/Claude supplied path against the cwd and make sure it exists.
---@param path string
---@return string|nil abs, string|nil err
local function resolve_path(path)
	if type(path) ~= "string" or path == "" then
		return nil, "path is required"
	end
	path = vim.fn.expand(path)
	if not vim.startswith(path, "/") then
		path = vim.fs.joinpath(vim.fn.getcwd(), path)
	end
	path = vim.fs.normalize(path)
	local st = vim.uv.fs_stat(path)
	if not st then
		return nil, "no such file: " .. path
	end
	if st.type == "directory" then
		return nil, "is a directory: " .. path
	end
	return path
end

M.tools.open_file = {
	description = "Open a file in the editor and move the cursor to a line, optionally highlighting a line range. "
		.. "Use it to take the user to the code you are talking about instead of quoting it. "
		.. "Relative paths resolve against the working directory.",
	inputSchema = schema({
		path = { type = "string", description = "File path, absolute or relative to the working directory" },
		line = { type = "integer", description = "1-based line to put the cursor on (default 1)" },
		end_line = { type = "integer", description = "Last line of a range to highlight (default: line)" },
	}, { "path" }),
	handler = function(args)
		local path, err = resolve_path(args.path)
		if not path then
			error(err, 0)
		end
		local win = target_win()
		vim.api.nvim_set_current_win(win)
		local cur = vim.api.nvim_win_get_buf(win)
		local already = vim.api.nvim_buf_get_name(cur) == path
		if not already then
			if vim.bo[cur].modified then
				vim.cmd("split")
				win = vim.api.nvim_get_current_win()
			end
			vim.cmd("edit " .. vim.fn.fnameescape(path))
		end
		local buf = vim.api.nvim_win_get_buf(win)
		local total = vim.api.nvim_buf_line_count(buf)
		local first = math.max(1, math.min(tonumber(args.line) or 1, total))
		local last = math.max(first, math.min(tonumber(args.end_line) or first, total))
		vim.api.nvim_win_set_cursor(win, { first, 0 })
		vim.cmd("normal! zz")

		vim.api.nvim_buf_clear_namespace(buf, open_ns, 0, -1)
		vim.api.nvim_buf_set_extmark(buf, open_ns, first - 1, 0, {
			end_row = last,
			hl_group = "Visual",
			hl_eol = true,
			priority = 50,
		})
		local group = vim.api.nvim_create_augroup("harner_open_file_" .. buf, { clear = true })
		vim.api.nvim_create_autocmd("CursorMoved", {
			group = group,
			buffer = buf,
			callback = function()
				local l = vim.api.nvim_win_get_cursor(0)[1]
				if l < first or l > last then
					vim.api.nvim_buf_clear_namespace(buf, open_ns, 0, -1)
					return true -- delete this autocmd
				end
			end,
		})
		local rel = vim.fn.fnamemodify(path, ":.")
		return first == last and string.format("Opened %s at line %d.", rel, first)
			or string.format("Opened %s, highlighted lines %d-%d.", rel, first, last)
	end,
}

M.tools.get_current_buffer = {
	description = "Return the file path, filetype, cursor position and full contents of the buffer the user is "
		.. "working in (the window next to the chat).",
	inputSchema = schema({
		max_lines = { type = "integer", description = "Cap on returned lines (default 2000)" },
	}),
	handler = function(args)
		local win = target_win()
		local buf = vim.api.nvim_win_get_buf(win)
		local cursor = vim.api.nvim_win_get_cursor(win)
		local max = args.max_lines or 2000
		local total = vim.api.nvim_buf_line_count(buf)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, math.min(total, max), false)
		local info = buf_info(buf)
		local header = string.format(
			"path: %s\nfiletype: %s\ncursor: line %d col %d\nlines: %d%s\n---\n",
			info.name ~= "" and info.name or "[No Name]",
			info.filetype,
			cursor[1],
			cursor[2] + 1,
			total,
			total > max and (" (truncated to " .. max .. ")") or ""
		)
		return header .. table.concat(lines, "\n")
	end,
}

M.tools.get_selection = {
	description = "Return the user's last visual selection in the working buffer (marks '< and '>), with path and line range.",
	inputSchema = schema({}),
	handler = function()
		local win = target_win()
		local buf = vim.api.nvim_win_get_buf(win)
		local s = vim.api.nvim_buf_get_mark(buf, "<")
		local e = vim.api.nvim_buf_get_mark(buf, ">")
		if s[1] == 0 or e[1] == 0 then
			return "No visual selection in " .. vim.api.nvim_buf_get_name(buf)
		end
		local lines = vim.api.nvim_buf_get_lines(buf, s[1] - 1, e[1], false)
		return string.format(
			"path: %s\nlines: %d-%d\n---\n%s",
			vim.api.nvim_buf_get_name(buf),
			s[1],
			e[1],
			table.concat(lines, "\n")
		)
	end,
}

M.tools.get_cursor = {
	description = "Return the cursor position and the surrounding lines of the working buffer.",
	inputSchema = schema({
		context = { type = "integer", description = "Lines of context above and below (default 10)" },
	}),
	handler = function(args)
		local win = target_win()
		local buf = vim.api.nvim_win_get_buf(win)
		local cursor = vim.api.nvim_win_get_cursor(win)
		local ctx = args.context or 10
		local first = math.max(0, cursor[1] - 1 - ctx)
		local last = math.min(vim.api.nvim_buf_line_count(buf), cursor[1] + ctx)
		local lines = vim.api.nvim_buf_get_lines(buf, first, last, false)
		for i, l in ipairs(lines) do
			local n = first + i
			lines[i] = string.format("%s%5d  %s", n == cursor[1] and ">" or " ", n, l)
		end
		return string.format(
			"path: %s\ncursor: line %d col %d\n---\n%s",
			vim.api.nvim_buf_get_name(buf),
			cursor[1],
			cursor[2] + 1,
			table.concat(lines, "\n")
		)
	end,
}

M.tools.list_buffers = {
	description = "List the files currently open in the editor.",
	inputSchema = schema({}),
	handler = function()
		local out = {}
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
				local info = buf_info(buf)
				table.insert(
					out,
					string.format(
						"%d  %s%s  [%s, %d lines]",
						info.bufnr,
						info.name ~= "" and info.name or "[No Name]",
						info.modified and " +" or "",
						info.filetype,
						info.lines
					)
				)
			end
		end
		return #out > 0 and table.concat(out, "\n") or "No listed buffers."
	end,
}

M.tools.get_diagnostics = {
	description = "Return LSP diagnostics for the working buffer (or all buffers).",
	inputSchema = schema({
		all = { type = "boolean", description = "Include every buffer, not just the working one" },
	}),
	handler = function(args)
		local buf = args.all and nil or vim.api.nvim_win_get_buf(target_win())
		local diags = vim.diagnostic.get(buf)
		if #diags == 0 then
			return "No diagnostics."
		end
		local sev = { "ERROR", "WARN", "INFO", "HINT" }
		local out = {}
		for _, d in ipairs(diags) do
			table.insert(
				out,
				string.format(
					"%s:%d:%d %s %s%s",
					vim.api.nvim_buf_get_name(d.bufnr),
					d.lnum + 1,
					d.col + 1,
					sev[d.severity] or "?",
					d.message:gsub("\n", " "),
					d.source and (" [" .. d.source .. "]") or ""
				)
			)
		end
		return table.concat(out, "\n")
	end,
}

M.tools.ask_user = {
	description = "Ask the user a question and wait for the answer. With `choices` the user picks one entry "
		.. "(the answer is the chosen text); without, they type a free-form reply. Use it when you need a "
		.. "decision before continuing, not for things you can read from the editor.",
	inputSchema = schema({
		question = { type = "string", description = "The question to show" },
		choices = {
			type = "array",
			items = { type = "string" },
			description = "Optional list of answers to pick from",
		},
	}, { "question" }),
	async = true,
	handler = function(args, resolve)
		local question = args.question
		if type(question) ~= "string" or question == "" then
			error("question is required", 0)
		end
		local choices = args.choices
		if type(choices) == "table" and #choices > 0 then
			vim.ui.select(choices, { prompt = question }, function(choice)
				if choice == nil then
					resolve("The user dismissed the question without answering.", true)
				else
					resolve(choice)
				end
			end)
		else
			vim.ui.input({ prompt = question .. " " }, function(text)
				if text == nil then
					resolve("The user dismissed the question without answering.", true)
				else
					resolve(text)
				end
			end)
		end
	end,
}

---True when `cmd` starts with one of the allow-listed commands (whole words).
---@param cmd string
local function run_allowed(cmd)
	local cfg = require("harner").config.run_command
	if not cfg.confirm then
		return true
	end
	for _, entry in ipairs(cfg.allow or {}) do
		if cmd == entry or vim.startswith(cmd, entry .. " ") then
			return true
		end
	end
	return false
end

---Run an Ex command in the target window.
---@return string text, boolean is_error
local function exec_command(cmd)
	-- nvim_win_call passes through a single return value only
	local r = vim.api.nvim_win_call(target_win(), function()
		return { pcall(vim.api.nvim_exec2, cmd, { output = true }) }
	end)
	local ok, res = r[1], r[2]
	if not ok then
		local msg = tostring(res):gsub("^.-nvim_exec2%(%), line %d+: ", "")
		return "`:" .. cmd .. "` failed: " .. msg, true
	end
	local out = vim.trim(res.output or "")
	return out ~= "" and out or ("Ran `:" .. cmd .. "` (no output)."), false
end

M.tools.run_command = {
	description = "Run a Neovim Ex command (without the leading colon) in the user's working window and return its "
		.. "output. Unless the command is on the user's allow-list they are asked to confirm it first. Good for "
		.. "editor actions (:Git blame, :Telescope, :copen), not a shell: there is no Bash here.",
	inputSchema = schema({
		cmd = { type = "string", description = "Ex command, e.g. `Git blame` or `set list?`" },
	}, { "cmd" }),
	async = true,
	handler = function(args, resolve)
		local cmd = vim.trim(type(args.cmd) == "string" and args.cmd or "")
		cmd = cmd:gsub("^:+", "")
		if cmd == "" then
			error("cmd is required", 0)
		end
		local function run()
			local ok, out, is_error = pcall(exec_command, cmd)
			if not ok then
				resolve("`:" .. cmd .. "` failed: " .. tostring(out), true)
			else
				resolve(out, is_error)
			end
		end
		if run_allowed(cmd) then
			run()
			return
		end
		vim.ui.select({ "run", "skip" }, { prompt = "harner: Claude wants to run `:" .. cmd .. "`" }, function(choice)
			if choice == "run" then
				run()
			else
				resolve("The user declined to run `:" .. cmd .. "`.", true)
			end
		end)
	end,
}

---MCP tools/list payload
function M.list()
	local out = {}
	for name, t in pairs(M.tools) do
		table.insert(out, { name = name, description = t.description, inputSchema = t.inputSchema })
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

-- Results of async tools waiting for the bridge to collect them.
-- false = still running, table = finished result.
---@type table<integer, table|false>
local pending = {}
local pending_seq = 0

local function tool_done(name)
	pcall(require("harner.chat").on_tool_done, name)
end

---MCP tools/call payload, or `{ pending = id }` for an async tool.
---@param name string
---@param args table
function M.call(name, args)
	local t = M.tools[name]
	if not t then
		return text_result("unknown tool: " .. tostring(name), true)
	end
	if t.async then
		pending_seq = pending_seq + 1
		local id = pending_seq
		pending[id] = false
		local function resolve(text, is_error)
			if pending[id] == false then
				pending[id] = text_result(tostring(text), is_error)
				tool_done(name)
			end
		end
		local ok, err = pcall(t.handler, args or {}, resolve)
		if not ok then
			pending[id] = nil
			return text_result("tool " .. name .. " failed: " .. tostring(err), true)
		end
		return { pending = id }
	end
	local ok, res = pcall(t.handler, args or {})
	if not ok then
		return text_result("tool " .. name .. " failed: " .. tostring(res), true)
	end
	tool_done(name)
	return text_result(tostring(res))
end

---Bridge polling: the finished result of an async call, or nil while it runs.
---@param id integer
---@return table|nil
function M.poll(id)
	local res = pending[id]
	if res == nil then
		return text_result("pending tool call " .. tostring(id) .. " was cancelled", true)
	end
	if res == false then
		return nil
	end
	pending[id] = nil
	return res
end

---Resolve every (or one) pending async call with an error. Used when the run
---is cancelled or finished so the bridge stops waiting.
---@param reason string
---@param id integer|nil
function M.cancel_pending(reason, id)
	local ids = id and { id } or vim.tbl_keys(pending)
	for _, k in ipairs(ids) do
		if pending[k] == false then
			pending[k] = text_result(reason, true)
		end
	end
end

---Number of async calls still waiting (for tests and the winbar).
function M.pending_count()
	local n = 0
	for _, v in pairs(pending) do
		if v == false then
			n = n + 1
		end
	end
	return n
end

return M
