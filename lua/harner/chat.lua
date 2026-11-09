-- Chats: markdown transcripts shown in a right-hand vertical split.
-- Everything below the last separator line is the pending input.
--
-- An nvim holds any number of chats, each with its own Claude session and its
-- own run (runs may overlap). A chat outlives its buffer: closing the window
-- hides it, and `:bdelete` / `:bwipeout` only detach the view. The lines are
-- kept and the buffer is rebuilt when the chat is shown or written to again.
-- `M.current` is the chat the popup and the <leader>h keymaps talk to;
-- `:HarnerChats` switches it.

local M = {}

local SEP = string.rep("─", 40)

---@class HarnerChat
---@field id integer
---@field buf integer|nil view buffer, nil while detached
---@field lines string[]|nil transcript kept while detached
---@field stale_buf integer|nil detached buffer still to be wiped (its name is reused)
---@field session_id string
---@field started boolean
---@field title string|nil first line of the first prompt
---@field run HarnerRun|nil
---@field origin_win integer|nil
---@field tool_line integer|nil 1-based line of the last tool note, amended when the input arrives
---@field auto boolean auto mode (fewer confirms, see auto.lua)
---@field last_prompt string|nil the user's latest message (classifier context)
---@field state string|nil last winbar state
---@field grants table|nil `a` approvals (tools.lua)

---@type table<integer, HarnerChat>
M.chats = {}
M.current = nil ---@type integer|nil chat id
-- chat id an nvim tool call runs for (set by tools.call around handlers and
-- their callbacks); nil outside a call
M.ctx = nil ---@type integer|nil
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

---The chat a buffer shows, if any.
---@param buf integer
---@return HarnerChat|nil
function M.by_buf(buf)
	for _, c in pairs(M.chats) do
		if c.buf == buf then
			return c
		end
	end
	return nil
end

---The chat a tool call belongs to (`M.ctx`), else the current one.
---@return HarnerChat|nil
function M.active()
	return (M.ctx and M.chats[M.ctx]) or (M.current and M.chats[M.current]) or nil
end

local function loaded(chat)
	return chat.buf ~= nil and vim.api.nvim_buf_is_valid(chat.buf) and vim.api.nvim_buf_is_loaded(chat.buf)
end

local function chat_win(chat)
	if not loaded(chat) then
		return nil
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(win) == chat.buf then
			return win
		end
	end
	return nil
end

---Any window in the current tab showing a chat.
local function any_chat_win()
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_config(win).relative == "" and M.by_buf(vim.api.nvim_win_get_buf(win)) then
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
	return M.by_buf(buf) == nil and vim.bo[buf].buftype == ""
end

---The window display tools should act on: a non-chat, non-floating window in
---the current tab. Prefers the window the active chat's user came from.
---@return integer
function M.target_win()
	local function usable(win)
		return usable_origin(win) and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
	end
	local chat = M.active()
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

-- Many colorschemes (nord among them) leave WinBar alone, so it falls back to
-- nvim's near-black default. The chat bar uses its own groups linked to the
-- colorscheme's StatusLine; `default = true` lets users override them and
-- ColorScheme re-links them after `:hi clear`.
local function define_hl()
	vim.api.nvim_set_hl(0, "HarnerWinBar", { link = "StatusLine", default = true })
	vim.api.nvim_set_hl(0, "HarnerWinBarNC", { link = "StatusLineNC", default = true })
end
define_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("harner_chat_hl", { clear = true }),
	callback = define_hl,
})

local function set_winbar(chat, state)
	chat.state = state
	local web = package.loaded["harner.web"]
	if web then
		web.on_meta(chat)
	end
	local win = chat_win(chat)
	if win then
		local badge = chat.auto and " %#DiagnosticWarn#AUTO%*" or ""
		vim.wo[win].winhighlight = "WinBar:HarnerWinBar,WinBarNC:HarnerWinBarNC"
		vim.wo[win].winbar = string.format("%%#Title# harner #%d %%* %s%s", chat.id, state, badge)
	end
	local cfg = require("harner").config.title
	if cfg and cfg.enabled then
		local prefix = type(cfg.prefix) == "function" and cfg.prefix() or cfg.prefix or ""
		vim.o.title = true
		-- 'titlestring' is evaluated like 'statusline' when it contains '%'
		vim.o.titlestring = (prefix .. "harner " .. state):gsub("%%", "%%%%")
	end
end

---Redraw the winbar with its current state (after toggling auto mode).
---@param chat HarnerChat
function M.refresh_winbar(chat)
	set_winbar(chat, chat.state or (chat.run and "thinking…" or "idle"))
end

local attach_buf -- forward

---The chat's buffer, rebuilt from the kept lines when it was deleted.
---@param chat HarnerChat
---@return integer
local function buf_of(chat)
	if not loaded(chat) then
		attach_buf(chat)
	end
	return chat.buf --[[@as integer]]
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
	local buf = buf_of(chat)
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
	vim.api.nvim_buf_set_lines(buf_of(chat), -1, -1, false, lines)
	scroll_to_end(chat)
end

local function short_name(name)
	return (name:gsub("^mcp__(.-)__", "%1:"))
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
	elseif n == "nvim:edit_file" or n == "nvim:write_file" or n == "nvim:save_file" then
		local paths = {}
		if type(input.path) == "string" then
			paths[1] = input.path
		end
		if type(input.paths) == "table" then
			vim.list_extend(paths, input.paths)
		end
		s = #paths > 0 and table.concat(vim.tbl_map(function(p)
			return vim.fn.fnamemodify(tostring(p), ":t")
		end, paths), ", ") or nil
	elseif n == "nvim:ask_user" then
		s = input.question
	elseif n == "nvim:run_command" then
		s = input.cmd and (":" .. input.cmd) or nil
	elseif n == "nvim:bash" then
		s = type(input.command) == "string" and ("$ " .. input.command) or nil
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
	local buf = buf_of(chat)
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
	local buf = buf_of(chat)
	local line = chat.tool_line
	if not line or line > vim.api.nvim_buf_line_count(buf) then
		return
	end
	local cur = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
	local bare = tool_note(name)
	-- mark_auto may have got there first: keep its suffix
	local auto = cur and vim.startswith(cur, bare:sub(1, -2) .. " · auto (") and cur:sub(#bare) or nil
	if cur ~= bare and not auto then
		return
	end
	local summary = tool_summary(name, input)
	if summary then
		local note = tool_note(name, summary)
		if auto then
			note = note:sub(1, -2) .. auto
		end
		vim.api.nvim_buf_set_lines(buf, line - 1, line, false, { note })
	end
end

---Mark the transcript note of a call that auto mode let run without asking:
---`_→ nvim:bash · $ git log · auto (rule)_`. Searches back from the end for
---the call's note (amended or not yet), so parallel calls each get theirs.
---@param name string tool name without the mcp__nvim__ prefix
---@param input table the call's arguments
---@param how string "rule" or "classifier"
function M.mark_auto(name, input, how)
	local chat = M.active()
	if not chat then
		return
	end
	local buf = buf_of(chat)
	local full = "mcp__nvim__" .. name
	local wanted = { tool_note(full, tool_summary(full, input or {})), tool_note(full) }
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	for i = #lines, 1, -1 do
		if lines[i] == SEP then
			return
		end
		if lines[i] == wanted[1] or lines[i] == wanted[2] then
			local marked = lines[i]:sub(1, -2) .. " · auto (" .. how .. ")_"
			vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { marked })
			return
		end
	end
end

---Called by tools.call after an nvim tool finished (for async tools: once the
---user answered), so the winbar goes back to "thinking".
---@param _ string|nil tool name
---@param id integer|nil chat id, default the active chat
function M.on_tool_done(_, id)
	local chat = (id and M.chats[id]) or M.active()
	if chat and chat.run then
		set_winbar(chat, "thinking…")
	end
end

---True while the current chat has a request in flight.
function M.busy()
	local chat = M.current and M.chats[M.current]
	return chat ~= nil and chat.run ~= nil
end

---Send the pending input of a chat.
---@param chat HarnerChat
---@param opts { origin_win?: integer }|nil
---@return boolean sent
local function send_chat(chat, opts)
	opts = opts or {}
	if chat.run then
		vim.notify("harner: still running, <C-c> to cancel", vim.log.levels.WARN)
		return false
	end
	local buf = buf_of(chat)
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
	M.current = chat.id
	chat.last_prompt = prompt -- context for the auto-mode classifier
	if not chat.title then
		chat.title = vim.split(prompt, "\n", { plain = true })[1]:sub(1, 60)
	end

	local out = { "## You", "" }
	vim.list_extend(out, vim.split(prompt, "\n", { plain = true }))
	vim.list_extend(out, { "", "## Claude", "", "" })
	vim.api.nvim_buf_set_lines(buf, start, -1, false, out)
	vim.cmd("stopinsert")
	scroll_to_end(chat)
	set_winbar(chat, "thinking…")

	local web = package.loaded["harner.web"]
	if web then
		web.ensure() -- the host may have gone away since the last run
	end
	local runner = require("harner.runner")
	chat.run = runner.start({
		prompt = prompt,
		session_id = chat.session_id,
		resume = chat.started,
		cwd = vim.fn.getcwd(),
		chat_id = chat.id,
		on_text = function(text)
			append_text(chat, text)
		end,
		on_tool = function(name)
			note_tool(chat, name)
			set_winbar(chat, "running " .. short_name(name))
		end,
		on_tool_input = function(name, input)
			amend_tool_note(chat, name, input)
		end,
		on_error = function(msg)
			append_lines(chat, { "", "> **error:** " .. msg:gsub("\n", "\n> ") })
		end,
		on_done = function(result)
			chat.run = nil
			chat.started = true
			chat.tool_line = nil
			require("harner.tools").cancel_chat("the request finished before the user answered", chat.id)
			buf = buf_of(chat)
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
	-- the winbar update above ran before chat.run was set: mirror running=true
	if web and chat.run then
		web.on_meta(chat)
	end
	return true
end

---Send the pending input of a chat buffer.
---@param buf integer|nil chat buffer, defaults to the current buffer
---@param opts { origin_win?: integer }|nil window the request came from
---@return boolean sent
function M.send(buf, opts)
	local chat = M.by_buf(buf or vim.api.nvim_get_current_buf())
	return chat ~= nil and send_chat(chat, opts)
end

---@param chat HarnerChat
local function cancel_chat(chat)
	if chat.run then
		require("harner.tools").cancel_chat("cancelled by the user", chat.id)
		require("harner.runner").cancel(chat.run)
		append_lines(chat, { "", "> cancelled" })
	end
end

---Cancel the run of a chat by id (the web UI).
---@param id integer
function M.cancel_id(id)
	local chat = M.chats[id]
	if chat then
		cancel_chat(chat)
	end
end

---Cancel the run of a chat buffer's chat, or of the current chat. When the
---current chat is idle (<leader>hx, :HarnerCancel) and exactly one other chat
---runs (a prompt from the web), that one is cancelled; with several running
---nothing is guessed.
---@param buf integer|nil
function M.cancel(buf)
	local chat = buf and M.by_buf(buf) or (M.current and M.chats[M.current])
	if not buf and not (chat and chat.run) then
		local running = vim.tbl_filter(function(c)
			return c.run ~= nil
		end, M.list())
		if #running > 1 then
			vim.notify("harner: several chats are running; pick one with :HarnerChats first", vim.log.levels.WARN)
			return
		end
		chat = running[1] or chat
	end
	if chat then
		cancel_chat(chat)
	end
end

---Keep the transcript when the chat's buffer is unloaded or wiped. The
---buffer itself is wiped later (not allowed inside its own autocmd) so a
---rebuilt one can take its name.
local function detach(chat, buf)
	if chat.buf ~= buf then
		return
	end
	chat.lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	chat.buf = nil
	chat.stale_buf = buf
	vim.schedule(function()
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end)
end

---Create the chat's view buffer from its kept lines.
---@param chat HarnerChat
attach_buf = function(chat)
	if chat.stale_buf and vim.api.nvim_buf_is_valid(chat.stale_buf) then
		pcall(vim.api.nvim_buf_delete, chat.stale_buf, { force = true })
	end
	chat.stale_buf = nil
	local buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, "harner://chat/" .. chat.id)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, chat.lines or { "" })
	chat.lines = nil
	chat.buf = buf

	local map = function(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, nowait = true })
	end
	local function send()
		send_chat(chat)
	end
	local function cancel()
		cancel_chat(chat)
	end
	map("n", "<CR>", send, "harner: send")
	map("i", "<C-s>", send, "harner: send")
	map("n", "<C-c>", cancel, "harner: cancel")
	map("i", "<C-c>", cancel, "harner: cancel")

	vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
		buffer = buf,
		callback = function()
			detach(chat, buf)
		end,
	})
	local web = package.loaded["harner.web"]
	if web then
		web.on_buf(chat)
	end
end

local function create_chat()
	counter = counter + 1
	local chat = {
		id = counter,
		session_id = uuid(),
		started = false,
		run = nil,
		origin_win = nil,
		auto = require("harner").config.auto.enabled == true,
	}
	M.chats[chat.id] = chat
	attach_buf(chat)
	return chat
end

---The current chat, created on first use.
---@return HarnerChat
function M.ensure()
	local chat = M.current and M.chats[M.current]
	if not chat then
		chat = create_chat()
		M.current = chat.id
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
	local buf = buf_of(chat)
	local existing = chat_win(chat)
	if existing then
		if focus then
			vim.api.nvim_set_current_win(existing)
		end
		M.current = chat.id
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
	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_width(win, width)
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].winfixwidth = true
	M.refresh_winbar(chat)
	vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
	M.current = chat.id
	if not focus and vim.api.nvim_win_is_valid(origin) then
		vim.api.nvim_set_current_win(origin)
	end
	return win
end

---Make `chat` current and show it: in the window already showing a chat,
---else in a new split.
---@param chat HarnerChat
---@param focus boolean|nil default true
local function show(chat, focus)
	local win = chat_win(chat) or any_chat_win()
	if not win then
		return open_win(chat, focus)
	end
	vim.api.nvim_win_set_buf(win, buf_of(chat))
	M.current = chat.id
	M.refresh_winbar(chat)
	if focus ~= false then
		vim.api.nvim_set_current_win(win)
	end
	return win
end

---Open (or focus) the current chat, creating one if needed.
function M.open()
	open_win(M.ensure(), true)
	vim.cmd("startinsert!")
end

---Send `prompt` to the current chat (or chat `id`) without typing into the
---chat buffer. Used by the input popup, :HarnerAsk and the web UI. Replaces
---any draft below the separator. Opens the chat window (unfocused) if it is
---hidden so the answer is visible.
---@param prompt string
---@param origin_win integer|nil window the question is about
---@param id integer|nil chat id, default the current chat
---@return boolean sent
function M.ask(prompt, origin_win, id)
	prompt = vim.trim(prompt or "")
	if prompt == "" then
		return false
	end
	local chat = id and M.chats[id] or M.ensure()
	if chat.run then
		vim.notify("harner: still running, <leader>hx to cancel", vim.log.levels.WARN)
		return false
	end
	local buf = buf_of(chat)
	local sep_idx = last_sep_index(buf)
	vim.api.nvim_buf_set_lines(buf, sep_idx or 0, -1, false, vim.split(prompt, "\n", { plain = true }))
	origin_win = origin_win or vim.api.nvim_get_current_win()
	-- a prompt for another chat (the web UI) while a chat is on screen runs in
	-- the background: no second split, the current chat stays current
	local background = id ~= nil and id ~= M.current and any_chat_win() ~= nil
	if require("harner").config.prompt.open_chat and not background then
		open_win(chat, false)
	end
	local prev = M.current
	local sent = send_chat(chat, { origin_win = origin_win })
	if background then
		M.current = prev
	end
	return sent
end

---Start a fresh chat with a new session; the old ones stay (`:HarnerChats`).
function M.new()
	local chat = create_chat()
	show(chat, true)
	set_winbar(chat, "idle")
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

---Chats sorted by id, for the picker and the web mirror.
---@return HarnerChat[]
function M.list()
	local out = vim.tbl_values(M.chats)
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

---One line per chat for the picker.
---@param chat HarnerChat
function M.label(chat)
	local state = chat.run and (chat.state or "thinking…") or "idle"
	return string.format(
		"#%d%s  %s  [%s]",
		chat.id,
		chat.id == M.current and "*" or "",
		chat.title or "(empty)",
		state
	)
end

---Pick a chat and show it (`:HarnerChats`).
function M.pick()
	local items = M.list()
	if #items == 0 then
		vim.notify("harner: no chats yet")
		return
	end
	vim.ui.select(items, { prompt = "harner chats", format_item = M.label }, function(chat)
		if chat and M.chats[chat.id] then
			show(chat, true)
		end
	end)
end

M.show = show

return M
