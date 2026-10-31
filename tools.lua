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

---Resolve a user/Claude supplied path against the cwd. The file may not exist
---yet; a directory is an error.
---@param path string
---@return string|nil abs, string|nil err, table|nil stat
local function resolve_any_path(path)
	if type(path) ~= "string" or path == "" then
		return nil, "path is required"
	end
	-- normalize() expands ~ and $VAR; vim.fn.expand() would also interpret % # and wildcards
	path = vim.fs.normalize(path)
	if not vim.startswith(path, "/") then
		path = vim.fs.normalize(vim.fs.joinpath(vim.fn.getcwd(), path))
	end
	local st = vim.uv.fs_stat(path)
	if st and st.type == "directory" then
		return nil, "is a directory: " .. path
	end
	return path, nil, st
end

---Like resolve_any_path but the file must exist.
---@param path string
---@return string|nil abs, string|nil err
local function resolve_path(path)
	local abs, err, st = resolve_any_path(path)
	if not abs then
		return nil, err
	end
	if not st then
		return nil, "no such file: " .. abs
	end
	return abs
end

---Load (or find) the buffer for an existing file without showing it.
---@param path string
---@return integer buf
local function load_buf(path)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.bo[buf].buflisted = true
	return buf
end

---Show `buf` in the target window (splitting first when that window holds
---another modified buffer), centre the cursor on `first` and highlight
---`first`-`last` until the cursor leaves the range.
---@param buf integer
---@param first integer 1-based
---@param last integer 1-based
---@return integer first, integer last clamped to the buffer
local function show_range(buf, first, last)
	local win = target_win()
	vim.api.nvim_set_current_win(win)
	if vim.api.nvim_win_get_buf(win) ~= buf then
		if vim.bo[vim.api.nvim_win_get_buf(win)].modified then
			vim.cmd("split")
			win = vim.api.nvim_get_current_win()
		end
		vim.api.nvim_win_set_buf(win, buf)
	end
	local total = vim.api.nvim_buf_line_count(buf)
	first = math.max(1, math.min(first, total))
	last = math.max(first, math.min(last, total))
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
	return first, last
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
		local line = tonumber(args.line) or 1
		local first, last = show_range(load_buf(path), line, tonumber(args.end_line) or line)
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

-- ---------------------------------------------------------------------------
-- Editing: edit_file changes the buffer in place (unsaved, undoable); write_file
-- and save_file touch the disk and ask the user first.

---Split text into lines; a trailing newline does not produce an empty last line.
---@param s string
---@return string[]
local function content_lines(s)
	local lines = vim.split(s or "", "\n", { plain = true })
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end
	if #lines == 1 and lines[1] == "" then
		return {}
	end
	return lines
end

local function rel(path)
	return vim.fn.fnamemodify(path, ":.")
end

---The loaded buffer for `path`, if any. Names are compared exactly (bufnr()
---would treat the path as a pattern); nvim stores buffer names with symlinks
---resolved (/var -> /private/var on macOS), so the real path is accepted too.
---@param path string
---@return integer|nil
local function loaded_buf(path)
	local real = vim.uv.fs_realpath(path) or path
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			local name = vim.api.nvim_buf_get_name(buf)
			if name == path or name == real then
				return buf
			end
		end
	end
	return nil
end

---Ask the user before a disk write unless config.write_file.confirm is off.
---@param prompt string
---@param yes string label of the confirming choice
---@param cb fun(ok:boolean)
local function confirm(prompt, yes, cb)
	if not require("harner").config.write_file.confirm then
		cb(true)
		return
	end
	vim.ui.select({ yes, "skip" }, { prompt = prompt }, function(choice)
		cb(choice == yes)
	end)
end

---Byte offsets of every exact occurrence of `needle` in `text`.
local function find_all(text, needle)
	local hits, init = {}, 1
	while true do
		local s, e = text:find(needle, init, true)
		if not s then
			return hits
		end
		hits[#hits + 1] = { s, e }
		init = e + 1
	end
end

---Whole-line matches of `old` in `lines` after normalising each line with `norm`.
---@return integer[] start indices (1-based)
local function find_line_matches(lines, old, norm)
	local normed = vim.tbl_map(norm, old)
	local hits = {}
	for i = 1, #lines - #old + 1 do
		local ok = true
		for j = 1, #old do
			if norm(lines[i + j - 1]) ~= normed[j] then
				ok = false
				break
			end
		end
		if ok then
			hits[#hits + 1] = i
		end
	end
	return hits
end

local function leading_ws(line)
	return line:match("^[ \t]*")
end

---Re-indent `new` so it fits where `old` matched after indentation-insensitive
---matching: the first matched file line sets the base, further levels follow
---the file's style (tabs, or `sw` spaces per level).
---@param new string[] replacement lines (Claude's indentation)
---@param old string[] old_str lines (Claude's indentation)
---@param matched string[] the file lines that matched
---@param sw integer
---@return string[]
local function reindent(new, old, matched, sw)
	local function width(ws)
		local w = 0
		for c in ws:gmatch(".") do
			w = w + (c == "\t" and sw or 1)
		end
		return w
	end
	local function first_nonblank(ls)
		for _, l in ipairs(ls) do
			if l:match("%S") then
				return l
			end
		end
		return ls[1] or ""
	end
	local file_base = leading_ws(first_nonblank(matched))
	local use_tabs = file_base:find("\t") ~= nil
	if file_base == "" then
		for _, l in ipairs(matched) do
			if leading_ws(l):find("\t") then
				use_tabs = true
			end
		end
	end
	local old_base_w = width(leading_ws(first_nonblank(old)))
	-- Claude's indent unit: smallest positive difference between indent widths
	local widths, unit = {}, nil
	for _, l in ipairs(old) do
		if l:match("%S") then
			widths[#widths + 1] = width(leading_ws(l))
		end
	end
	for _, l in ipairs(new) do
		if l:match("%S") then
			widths[#widths + 1] = width(leading_ws(l))
		end
	end
	table.sort(widths)
	for i = 2, #widths do
		local d = widths[i] - widths[i - 1]
		if d > 0 and (unit == nil or d < unit) then
			unit = d
		end
	end
	unit = unit or sw
	local base_levels = use_tabs and #file_base or math.floor(width(file_base) / sw)
	local out = {}
	for i, l in ipairs(new) do
		if not l:match("%S") then
			out[i] = ""
		else
			local ws = leading_ws(l)
			local levels = base_levels + math.floor((width(ws) - old_base_w) / unit + 0.5)
			levels = math.max(0, levels)
			local indent = use_tabs and string.rep("\t", levels) or string.rep(" ", levels * sw)
			out[i] = indent .. l:sub(#ws + 1)
		end
	end
	return out
end

---Row/col (0-based) of a byte offset in `text` given line start offsets.
local function offset_to_pos(starts, off)
	local lo, hi = 1, #starts
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if starts[mid] <= off then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo - 1, off - starts[lo]
end

M.tools.edit_file = {
	description = "Replace text in a file: `old_str` must match exactly once (copy it verbatim from the file, with "
		.. "enough surrounding lines to be unique) and is replaced by `new_str`. Set `replace_all` to change every "
		.. "occurrence. The change is applied to the editor buffer immediately and left unsaved so the user can "
		.. "review and undo it; call save_file to write it to disk when asked to. Prefer several small edits over "
		.. "rewriting a file; use write_file only for new files or complete rewrites.",
	inputSchema = schema({
		path = { type = "string", description = "File path, absolute or relative to the working directory" },
		old_str = { type = "string", description = "Exact text to replace" },
		new_str = { type = "string", description = "Replacement text" },
		replace_all = { type = "boolean", description = "Replace every occurrence instead of requiring exactly one" },
	}, { "path", "old_str", "new_str" }),
	handler = function(args)
		local path, err = resolve_path(args.path)
		if not path then
			error(err, 0)
		end
		local old, new = args.old_str, args.new_str
		if type(old) ~= "string" or old == "" then
			error("old_str is required", 0)
		end
		if type(new) ~= "string" then
			error("new_str is required", 0)
		end
		if old == new then
			error("old_str and new_str are identical", 0)
		end
		local buf = load_buf(path)
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local text = table.concat(lines, "\n")
		local name = rel(path)

		-- 1. exact substring match
		local hits = find_all(text, old)
		if #hits > 1 and not args.replace_all then
			error(
				string.format(
					"old_str matches %d places in %s; include more surrounding lines so it is unique, or set replace_all",
					#hits,
					name
				),
				0
			)
		end
		if #hits > 0 then
			local starts, off = {}, 1
			for i, l in ipairs(lines) do
				starts[i] = off
				off = off + #l + 1
			end
			local new_lines = vim.split(new, "\n", { plain = true })
			local first_row
			for i = #hits, 1, -1 do
				local srow, scol = offset_to_pos(starts, hits[i][1])
				local erow, ecol = offset_to_pos(starts, hits[i][2] + 1)
				vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, new_lines)
				first_row = srow
			end
			local n = #new_lines
			if n > 1 and new_lines[n] == "" then
				n = n - 1 -- new_str ended with a newline
			end
			local first, last = show_range(buf, first_row + 1, first_row + n)
			return string.format(
				"Edited %s: replaced %d occurrence%s (now lines %d-%d, shown in the editor). The buffer is "
					.. "modified but not saved; the user can review it, or call save_file to write it.",
				name,
				#hits,
				#hits == 1 and "" or "s",
				first,
				last
			)
		end

		-- 2. whole-line match ignoring trailing, then all leading/trailing whitespace
		-- (not for whitespace-only old_str: it would match every blank line)
		local old_lines = content_lines(old)
		local new_lines = content_lines(new)
		local levels = vim.trim(old) == "" and {} or {
			{ "trailing whitespace", function(l)
				return (l:gsub("[ \t]+$", ""))
			end, false },
			{ "indentation", vim.trim, true },
		}
		for _, lvl in ipairs(levels) do
			local label, norm, fix_indent = lvl[1], lvl[2], lvl[3]
			local starts = find_line_matches(lines, old_lines, norm)
			if #starts > 1 and not args.replace_all then
				error(
					string.format(
						"old_str matches %d places in %s (ignoring %s); include more surrounding lines so it is unique",
						#starts,
						name,
						label
					),
					0
				)
			end
			if #starts > 0 then
				local sw = vim.bo[buf].shiftwidth
				if sw == 0 then
					sw = vim.bo[buf].tabstop
				end
				local first
				for i = #starts, 1, -1 do
					local s = starts[i]
					local repl = new_lines
					if fix_indent then
						local matched = vim.list_slice(lines, s, s + #old_lines - 1)
						repl = reindent(new_lines, old_lines, matched, sw)
					end
					vim.api.nvim_buf_set_lines(buf, s - 1, s - 1 + #old_lines, false, repl)
					first = s
				end
				local last
				first, last = show_range(buf, first, first + #new_lines - 1)
				return string.format(
					"Edited %s: replaced %d occurrence%s (now lines %d-%d, shown in the editor; old_str matched only "
						.. "after ignoring %s, re-read the file before further edits). The buffer is modified but not "
						.. "saved; the user can review it, or call save_file to write it.",
					name,
					#starts,
					#starts == 1 and "" or "s",
					first,
					last,
					label
				)
			end
		end
		error(
			string.format(
				"old_str was not found in %s. The file may have changed: read it again and copy the text exactly.",
				name
			),
			0
		)
	end,
}

---Save a loaded buffer to its file.
---@param buf integer
---@return string|nil err
local function write_buf(buf)
	local ok, e = pcall(vim.api.nvim_buf_call, buf, function()
		vim.cmd("silent write")
	end)
	return (not ok) and tostring(e) or nil
end

---Write `lines` to `path`, through the buffer when one is loaded so it stays in sync.
---@return string|nil err
local function write_lines(path, lines)
	local buf = loaded_buf(path)
	if buf then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		return write_buf(buf)
	end
	if vim.fn.writefile(lines, path) ~= 0 then
		return "writefile failed for " .. path
	end
	return nil
end

M.tools.write_file = {
	description = "Create a file or replace its whole contents; the user confirms the write first. Use it for new "
		.. "files or complete rewrites, and edit_file for changes to existing files.",
	inputSchema = schema({
		path = { type = "string", description = "File path, absolute or relative to the working directory" },
		content = { type = "string", description = "The full file contents" },
		create_dirs = { type = "boolean", description = "Create missing parent directories" },
	}, { "path", "content" }),
	async = true,
	handler = function(args, resolve)
		local path, err, st = resolve_any_path(args.path)
		if not path then
			error(err, 0)
		end
		if type(args.content) ~= "string" then
			error("content is required", 0)
		end
		local dir = vim.fs.dirname(path)
		if not vim.uv.fs_stat(dir) then
			if not args.create_dirs then
				error("directory does not exist: " .. dir .. " (set create_dirs to create it)", 0)
			end
		end
		local lines = content_lines(args.content)
		local name = rel(path)
		local what
		if st then
			local buf = loaded_buf(path)
			local old_n = buf and vim.api.nvim_buf_line_count(buf) or #vim.fn.readfile(path)
			what = string.format("replaces %d lines with %d", old_n, #lines)
			if buf and vim.bo[buf].modified then
				what = what .. ", discarding unsaved changes in the buffer"
			end
		else
			what = string.format("new file, %d lines", #lines)
		end
		confirm(string.format("harner: Claude wants to write %s (%s)", name, what), "write", function(ok)
			if not ok then
				resolve("The user declined to write " .. name .. ".", true)
				return
			end
			local ok2, werr = pcall(function()
				if not vim.uv.fs_stat(dir) then
					vim.fn.mkdir(dir, "p")
				end
				return write_lines(path, lines)
			end)
			if not ok2 or werr then
				resolve("Writing " .. name .. " failed: " .. tostring(werr), true)
			else
				resolve(string.format("Wrote %s (%d lines).", name, #lines))
			end
		end)
	end,
}

M.tools.save_file = {
	description = "Save a buffer with unsaved changes (for example after edit_file) to disk; the user confirms first.",
	inputSchema = schema({
		path = { type = "string", description = "File path, absolute or relative to the working directory" },
	}, { "path" }),
	async = true,
	handler = function(args, resolve)
		local path, err = resolve_any_path(args.path)
		if not path then
			error(err, 0)
		end
		local name = rel(path)
		local buf = loaded_buf(path)
		if not buf then
			error(name .. " is not open in the editor", 0)
		end
		if not vim.bo[buf].modified then
			resolve(name .. " has no unsaved changes.")
			return
		end
		confirm("harner: Claude wants to save " .. name, "save", function(ok)
			if not ok then
				resolve("The user declined to save " .. name .. ".", true)
				return
			end
			local werr = write_buf(buf)
			if werr then
				resolve("Saving " .. name .. " failed: " .. werr, true)
			else
				resolve(string.format("Saved %s (%d lines).", name, vim.api.nvim_buf_line_count(buf)))
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
