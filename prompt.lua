-- Floating input popup: ask the current chat something from any window
-- without opening the chat split first. <CR> sends, <S-CR> inserts a
-- newline, <Esc>/q/<C-c> close (the draft is kept for the next open).
--
-- Opened from visual mode it carries a *reference* to the selection (path and
-- line range), not the text: the reference is shown in the title and appended
-- to the prompt, and Claude reads the lines itself with get_selection.

local M = {}

---@class HarnerRef
---@field path string
---@field first integer
---@field last integer

local state = { win = nil, buf = nil, draft = nil, ref = nil }

local function cfg()
	return require("harner").config.prompt
end

local function is_open()
	return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

---Short label for a reference: `mcp.lua:12-20`.
---@param ref HarnerRef
local function ref_label(ref)
	local name = vim.fn.fnamemodify(ref.path, ":t")
	if name == "" then
		name = "[No Name]"
	end
	return ref.first == ref.last and string.format("%s:%d", name, ref.first)
		or string.format("%s:%d-%d", name, ref.first, ref.last)
end

---The line appended to the prompt so Claude knows what the question is about
---and how to fetch it. Path is relative to cwd when it lives under it.
---@param ref HarnerRef
---@return string
function M.ref_line(ref)
	local path = vim.fn.fnamemodify(ref.path, ":.")
	if path == "" then
		path = "[No Name]"
	end
	local range = ref.first == ref.last and ("line " .. ref.first) or ("lines " .. ref.first .. "-" .. ref.last)
	return string.format("Selection: %s %s (read it with get_selection)", path, range)
end

---Describe the visual selection of the current buffer as a reference. Leaves
---visual mode first so the '< and '> marks (which get_selection reads) are set.
---@return HarnerRef|nil
function M.selection_ref()
	if vim.fn.mode():match("^[vV\22]") then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
	end
	local buf = vim.api.nvim_get_current_buf()
	local first = vim.api.nvim_buf_get_mark(buf, "<")[1]
	local last = vim.api.nvim_buf_get_mark(buf, ">")[1]
	if first == 0 or last == 0 then
		return nil
	end
	return { path = vim.api.nvim_buf_get_name(buf), first = first, last = last }
end

---Window geometry: centred, a little above the middle, sized to the text.
local function layout()
	local c = cfg()
	local width = c.width < 1 and math.floor(vim.o.columns * c.width) or c.width
	width = math.max(20, math.min(width, vim.o.columns - 4))
	local height = c.min_height
	if is_open() then
		-- text height accounts for wrapped lines
		local h = vim.api.nvim_win_text_height(state.win, {}).all
		height = math.max(c.min_height, math.min(c.max_height, h))
	end
	local row = math.max(1, math.floor((vim.o.lines - height) / 2) - 3)
	local col = math.floor((vim.o.columns - width) / 2)
	return {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = c.border,
		title = state.ref and string.format(" harner · %s ", ref_label(state.ref)) or " harner ",
		title_pos = "left",
		footer = " <CR> send · <S-CR> newline · <Esc> close ",
		footer_pos = "right",
	}
end

local function resize()
	if is_open() then
		vim.api.nvim_win_set_config(state.win, layout())
	end
end

---Close the popup. The text stays in `state.draft` unless `discard` is set.
---@param discard boolean|nil
function M.close(discard)
	local win, buf = state.win, state.buf
	state.win, state.buf, state.ref = nil, nil, nil
	if buf and vim.api.nvim_buf_is_valid(buf) then
		if discard then
			state.draft = nil
		else
			local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
			state.draft = text ~= "" and text or nil
		end
	end
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		pcall(vim.api.nvim_buf_delete, buf, { force = true })
	end
end

---Open the popup (or focus it if already open).
---@param opts { text?: string, ref?: HarnerRef }|nil initial text (defaults to
---the kept draft) and an optional selection reference to attach
function M.open(opts)
	opts = opts or {}
	if is_open() then
		if opts.ref then
			state.ref = opts.ref
			resize()
		end
		vim.api.nvim_set_current_win(state.win)
		vim.cmd("startinsert!")
		return
	end
	local chat = require("harner.chat")
	local origin = vim.api.nvim_get_current_win()
	state.ref = opts.ref

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	state.buf = buf
	local text = opts.text or state.draft
	if text then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
	end

	local win = vim.api.nvim_open_win(buf, true, layout())
	state.win = win
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].cursorline = false
	resize()

	local function submit()
		local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local prompt = vim.trim(table.concat(lines, "\n"))
		if prompt == "" then
			return
		end
		if chat.busy() then
			vim.notify("harner: still running, <leader>hx to cancel", vim.log.levels.WARN)
			return
		end
		local ref = state.ref
		if ref then
			prompt = prompt .. "\n\n" .. M.ref_line(ref)
		end
		vim.cmd("stopinsert")
		M.close(true)
		if vim.api.nvim_win_is_valid(origin) then
			vim.api.nvim_set_current_win(origin)
		end
		chat.ask(prompt, origin)
	end

	local function map(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, nowait = true })
	end
	map("i", "<CR>", submit, "harner: send")
	map("n", "<CR>", submit, "harner: send")
	map("i", "<S-CR>", "<CR>", "harner: newline")
	map("i", "<C-CR>", "<CR>", "harner: newline")
	map("n", "<Esc>", M.close, "harner: close")
	map("n", "q", M.close, "harner: close")
	map("i", "<C-c>", function()
		vim.cmd("stopinsert")
		M.close()
	end, "harner: close")
	map("n", "<C-c>", M.close, "harner: close")

	local group = vim.api.nvim_create_augroup("harner_prompt_" .. buf, { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = group, buffer = buf, callback = resize })
	vim.api.nvim_create_autocmd("VimResized", { group = group, callback = resize })
	vim.api.nvim_create_autocmd("WinLeave", {
		group = group,
		buffer = buf,
		callback = function()
			-- leaving the float (e.g. <C-w>w) dismisses it; defer so the window
			-- switch finishes first
			vim.schedule(function()
				if state.win == win then
					M.close()
				end
			end)
		end,
	})

	vim.cmd("startinsert!")
end

function M.toggle()
	if is_open() then
		M.close()
	else
		M.open()
	end
end

return M
