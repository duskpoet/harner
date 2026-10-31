-- Chat buffer: a markdown scratch buffer in a right-hand vertical split.
-- Everything below the last separator line is the pending input.
-- One chat is "current" per nvim instance; the input popup (prompt.lua) and
-- the <leader>h keymaps always talk to that one.

local M = {}

local SEP = string.rep("─", 40)

---@class HarnerChat
---@field buf integer
---@field session_id string
---@field started boolean
---@field run HarnerRun|nil
---@field origin_win integer|nil
---@field tool_line integer|nil 1-based line of the last tool note, amended when the input arrives

---@type table<integer, HarnerChat>
M.chats = {}
M.current = nil ---@type integer|nil
local counter = 0

local function uuid()
	local bytes = {}
	for i = 1, 16 do
		bytes[i] = math.random(0, 255)
	end
	bytes[7] = bytes[7] % 16 + 64 -- version 4
	bytes[9] = bytes[9] % 64 + 128 -- variant
	local hex = {}
	for i = 1, 16 do
		hex[i] = string.format("%02x", bytes[i])
	end
	local s = table.concat(hex)
	return s:sub(1, 8) .. "-" .. s:sub(9, 12) .. "-" .. s:sub(13, 16) .. "-" .. s:sub(17, 20) .. "-" .. s:sub(21, 32)
end

local function is_chat_buf(buf)
	return M.chats[buf] ~= nil
end

local function chat_win(chat)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == chat.buf then
			return win
		end
	end
	return nil
end

---A window worth remembering as the place the user came from: a real
---(non-floating) window showing an ordinary file buffer. Special buffers
---(NERDTree and other sidebars, terminals, quickfix, help, show_text windows)
---have a non-empty 'buftype' and are skipped so display tools never replace
---or split them.
local function usable_origin(win)
	if win == nil or win == 0 or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	if vim.api.nvim_win_get_config(win).relative ~= "" then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	return not is_chat_buf(buf) and vim.bo[buf].buftype == ""
end

---The window display tools should act on: a non-chat, non-floating window in
---the current tab. Prefers the window the user came from.
---@return integer
function M.target_win()
	local function usable(win)
		return usable_origin(win) and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
	end
	local chat = M.current and M.chats[M.current]
	if chat and usable(chat.origin_win) then
		return chat.origin_win
	end
	local cur = vim.api.nvim_get_current_win()
	if usable(cur) then
		return cur
	end
	local prev = vim.fn.win_getid(vim.fn.winnr("#"))
	if usable(prev) then
		return prev
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if usable(win) then
			return win
		end
	end
	-- only chat windows exist: make room on the left
	vim.cmd("topleft vnew")
	return vim.api.nvim_get_current_win()
end

local function set_winbar(chat, state)
	local win = chat_win(chat)
	if win then
		vim.wo[win].winbar = string.format("%%#Title# harner %%* %s · %s", chat.session_id:sub(1, 8), state)
	end
end

local function last_sep_index(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i = #lines, 1, -1 do
		if lines[i] == SEP then
			return i, lines
		end
	end
	return nil, lines
end

local function scroll_to_end(chat)
	local win = chat_win(chat)
	if not win then
		return
	end
	local n = vim.api.nvim_buf_line_count(chat.buf)
	if win == vim.api.nvim_get_current_win() then
		local cur = vim.api.nvim_win_get_cursor(win)[1]
		if cur < n - 3 then
			return -- user scrolled up, leave them alone
		end
	end
	vim.api.nvim_win_set_cursor(win, { n, 0 })
end

local function append_text(chat, text)
	local buf = chat.buf
	local n = vim.api.nvim_buf_line_count(buf)
	local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
	local parts = vim.split(text, "\n", { plain = true })
	parts[1] = last .. parts[1]
	if last == "" and n >= 2 then
		-- text following a tool note starts its own paragraph
		local prev = vim.api.nvim_buf_get_lines(buf, n - 2, n - 1, false)[1] or ""
		if vim.startswith(prev, "_→ ") then
			table.insert(parts, 1, "")
		end
	end
	vim.api.nvim_buf_set_lines(buf, n - 1, n, false, parts)
	scroll_to_end(chat)
end

local function append_lines(chat, lines)
	vim.api.nvim_buf_set_lines(chat.buf, -1, -1, false, lines)
	scroll_to_end(chat)
end

local function short_name(name)
	return (name:gsub("^mcp__nvim__", "nvim:"))
end

---The italic note written into the transcript when Claude calls a tool.
---@param name string
---@param summary string|nil
local function tool_note(name, summary)
	local s = "_→ " .. short_name(name)
	if summary and summary ~= "" then
		s = s .. " · " .. summary
	end
	return s .. "_"
end

---One-line description of a tool call's input for the transcript note.
---@param name string
---@param input table
---@return string|nil
local function tool_summary(name, input)
	local n = short_name(name)
	local s
	if n == "nvim:show_text" then
		s = input.title
	elseif n == "nvim:open_file" then
		s = input.path and vim.fn.fnamemodify(input.path, ":t") or nil
		if s and input.line then
			s = s .. ":" .. input.line
			if input.end_line and input.end_line ~= input.line then
				s = s .. "-" .. input.end_line
			end
		end
	elseif n == "nvim:ask_user" then
		s = input.question
	elseif n == "nvim:run_command" then
		s = input.cmd and (":" .. input.cmd) or nil
	elseif n == "Read" or n == "Glob" or n == "Grep" then
		s = input.file_path or input.pattern
		if s and n ~= "Read" and input.path then
			s = s .. " in " .. input.path
		end
	elseif n == "WebFetch" then
		s = input.url
	end
	if type(s) ~= "string" then
		return nil
	end
	s = s:gsub("%s+", " ")
	if #s > 60 then
		s = s:sub(1, 57) .. "…"
	end
	return s
end

---Write the tool note for `name` at the end of the transcript.
local function note_tool(chat, name)
	local buf = chat.buf
	local n = vim.api.nvim_buf_line_count(buf)
	local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
	local note = tool_note(name)
	if last == "" then
		vim.api.nvim_buf_set_lines(buf, n - 1, n, false, { note, "" })
		chat.tool_line = n
		scroll_to_end(chat)
	else
		append_lines(chat, { "", note, "" })
		chat.tool_line = n + 2
	end
end

---Amend the last tool note with a summary of the call's input, once known.
local function amend_tool_note(chat, name, input)
	local line = chat.tool_line
	if not line or line > vim.api.nvim_buf_line_count(chat.buf) then
		return
	end
	local cur = vim.api.nvim_buf_get_lines(chat.buf, line - 1, line, false)[1]
	if cur ~= tool_note(name) then
		return
	end
	local summary = tool_summary(name, input)
	if summary then
		vim.api.nvim_buf_set_lines(chat.buf, line - 1, line, false, { tool_note(name, summary) })
	end
end

---Called by tools.call after an nvim tool finished (for async tools: once the
---user answered), so the winbar goes back to "thinking".
function M.on_tool_done(_)
	local chat = M.current and M.chats[M.current]
	if chat and chat.run then
		set_winbar(chat, "thinking…")
	end
end

---True while the current chat has a request in flight.
function M.busy()
	local chat = M.current and M.chats[M.current]
	return chat ~= nil and chat.run ~= nil
end

---Send the pending input of a chat buffer.
---@param buf integer|nil chat buffer, defaults to the current buffer
---@param opts { origin_win?: integer }|nil window the request came from
---@return boolean sent
function M.send(buf, opts)
	opts = opts or {}
	buf = buf or vim.api.nvim_get_current_buf()
	local chat = M.chats[buf]
	if not chat then
		return false
	end
	if chat.run then
		vim.notify("harner: still running, <C-c> to cancel", vim.log.levels.WARN)
		return false
	end
	local sep_idx, lines = last_sep_index(buf)
	local start = sep_idx and sep_idx or 0 -- lines after the separator (0-based start index)
	local input = {}
	for i = start + 1, #lines do
		input[#input + 1] = lines[i]
	end
	local prompt = vim.trim(table.concat(input, "\n"))
	if prompt == "" then
		return false
	end

	-- remember where the user was so display tools can target it
	local origin = opts.origin_win or vim.fn.win_getid(vim.fn.winnr("#"))
	if usable_origin(origin) then
		chat.origin_win = origin
	end
	M.current = buf

	local out = { "## You", "" }
	vim.list_extend(out, vim.split(prompt, "\n", { plain = true }))
	vim.list_extend(out, { "", "## Claude", "", "" })
	vim.api.nvim_buf_set_lines(buf, start, -1, false, out)
	vim.cmd("stopinsert")
	scroll_to_end(chat)
	set_winbar(chat, "thinking…")

	local runner = require("harner.runner")
	chat.run = runner.start({
		prompt = prompt,
		session_id = chat.session_id,
		resume = chat.started,
		cwd = vim.fn.getcwd(),
		on_text = function(text)
			if vim.api.nvim_buf_is_valid(buf) then
				append_text(chat, text)
			end
		end,
		on_tool = function(name)
			if vim.api.nvim_buf_is_valid(buf) then
				note_tool(chat, name)
				set_winbar(chat, "running " .. short_name(name))
			end
		end,
		on_tool_input = function(name, input)
			if vim.api.nvim_buf_is_valid(buf) then
				amend_tool_note(chat, name, input)
			end
		end,
		on_error = function(msg)
			if vim.api.nvim_buf_is_valid(buf) then
				append_lines(chat, { "", "> **error:** " .. msg:gsub("\n", "\n> ") })
			end
		end,
		on_done = function(result)
			chat.run = nil
			chat.started = true
			chat.tool_line = nil
			require("harner.tools").cancel_pending("the request finished before the user answered")
			if not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			local n = vim.api.nvim_buf_line_count(buf)
			local last = vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1] or ""
			append_lines(chat, last == "" and { SEP, "" } or { "", SEP, "" })
			local cost = result and result.total_cost_usd
			set_winbar(chat, cost and string.format("idle · $%.3f last", cost) or "idle")
			local win = chat_win(chat)
			if win and win == vim.api.nvim_get_current_win() then
				vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
			end
		end,
	})
	return true
end

function M.cancel(buf)
	buf = buf or M.current or vim.api.nvim_get_current_buf()
	local chat = M.chats[buf]
	if chat and chat.run then
		require("harner.tools").cancel_pending("cancelled by the user")
		require("harner.runner").cancel(chat.run)
		append_lines(chat, { "", "> cancelled" })
	end
end

local function create_chat()
	counter = counter + 1
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, "harner://chat/" .. counter)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

	local chat = { buf = buf, session_id = uuid(), started = false, run = nil, origin_win = nil }
	M.chats[buf] = chat

	local map = function(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, nowait = true })
	end
	map("n", "<CR>", function()
		M.send(buf)
	end, "harner: send")
	map("i", "<C-s>", function()
		M.send(buf)
	end, "harner: send")
	map("n", "<C-c>", function()
		M.cancel(buf)
	end, "harner: cancel")
	map("i", "<C-c>", function()
		M.cancel(buf)
	end, "harner: cancel")

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function()
			if chat.run then
				require("harner.runner").cancel(chat.run)
			end
			M.chats[buf] = nil
			if M.current == buf then
				M.current = nil
			end
		end,
	})
	return chat
end

---The current chat, created on first use.
---@return HarnerChat
function M.ensure()
	local chat = M.current and M.chats[M.current]
	if not chat then
		chat = create_chat()
		M.current = chat.buf
	end
	return chat
end

---Show the chat in a right-hand split (or focus the existing window).
---@param chat HarnerChat
---@param focus boolean|nil move the cursor into the chat window (default true)
local function open_win(chat, focus)
	if focus == nil then
		focus = true
	end
	local existing = chat_win(chat)
	if existing then
		if focus then
			vim.api.nvim_set_current_win(existing)
		end
		return existing
	end
	local origin = vim.api.nvim_get_current_win()
	if usable_origin(origin) then
		chat.origin_win = origin
	end
	local width = require("harner").config.width
	if width < 1 then
		width = math.floor(vim.o.columns * width)
	end
	vim.cmd("botright vsplit")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, chat.buf)
	vim.api.nvim_win_set_width(win, width)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixwidth = true
	set_winbar(chat, chat.run and "thinking…" or "idle")
	vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(chat.buf), 0 })
	M.current = chat.buf
	if not focus and vim.api.nvim_win_is_valid(origin) then
		vim.api.nvim_set_current_win(origin)
	end
	return win
end

---Open (or focus) the current chat, creating one if needed.
function M.open()
	open_win(M.ensure(), true)
	vim.cmd("startinsert!")
end

---Send `prompt` to the current chat without typing into the chat buffer.
---Used by the input popup and :HarnerAsk. Replaces any draft below the
---separator. Opens the chat window (unfocused) if it is hidden so the answer
---is visible.
---@param prompt string
---@param origin_win integer|nil window the question is about
---@return boolean sent
function M.ask(prompt, origin_win)
	prompt = vim.trim(prompt or "")
	if prompt == "" then
		return false
	end
	local chat = M.ensure()
	if chat.run then
		vim.notify("harner: still running, <leader>hx to cancel", vim.log.levels.WARN)
		return false
	end
	local sep_idx = last_sep_index(chat.buf)
	vim.api.nvim_buf_set_lines(chat.buf, sep_idx or 0, -1, false, vim.split(prompt, "\n", { plain = true }))
	if require("harner").config.prompt.open_chat then
		open_win(chat, false)
	end
	return M.send(chat.buf, { origin_win = origin_win or vim.api.nvim_get_current_win() })
end

---Start a fresh chat buffer with a new session.
function M.new()
	local chat = create_chat()
	local old = M.current and M.chats[M.current]
	local win = old and chat_win(old)
	if win then
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_win_set_buf(win, chat.buf)
		M.current = chat.buf
		set_winbar(chat, "idle")
	else
		M.current = chat.buf
		open_win(chat)
	end
	vim.cmd("startinsert!")
end

---Toggle the chat window.
function M.toggle()
	local chat = M.current and M.chats[M.current]
	local win = chat and chat_win(chat)
	if win then
		vim.api.nvim_win_close(win, false)
	else
		M.open()
	end
end

return M
