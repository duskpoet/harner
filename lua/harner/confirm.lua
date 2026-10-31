-- Confirm float for actions Claude asks to take (run_command, bash,
-- write_file, save_file, and edit_file's save/drop question). Unlike
-- vim.ui.select, whose frontends put the prompt in a one-line title that gets
-- truncated, the full request is shown as wrapped body text so the user sees
-- exactly what they approve.
--
-- Keys: y / <CR> approve, a approve and stop asking for this kind of action
-- in the current chat, extra `choices` answer their own value, n / q / <Esc> /
-- <C-c> decline. Leaving the float declines too.

local M = {}

-- Own highlight groups so the float stands out even where NormalFloat and
-- FloatBorder match Normal. `default = true` lets colorschemes and users
-- override them; ColorScheme re-links them after `:hi clear`.
local function set_highlights()
	local links = {
		HarnerConfirmNormal = "NormalFloat",
		HarnerConfirmBorder = "DiagnosticInfo",
		HarnerConfirmTitle = "DiagnosticInfo",
		HarnerConfirmKey = "DiagnosticInfo",
		HarnerConfirmFooter = "Comment",
	}
	for group, link in pairs(links) do
		vim.api.nvim_set_hl(0, group, { link = link, default = true })
	end
end
set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("harner_confirm_hl", { clear = true }),
	callback = set_highlights,
})

---@class HarnerConfirmOpts
---@field title string short question, shown on the border
---@field body string[] what is being approved (full text, wrapped)
---@field filetype string|nil highlighting for the body
---@field yes string|nil label of the approve key (y / <CR>), e.g. "run"
---@field always string|nil label of the `a` key; omitted means no `a` choice
---@field choices {key:string, label:string, value:string}[]|nil extra keys,
---       each answering its `value` (used instead of or next to yes/always)

---Ask the user; `cb` gets "yes", "always", a choice's value or "no" exactly once.
---Returns the float's close function: calling it with "no" declines it.
---@param opts HarnerConfirmOpts
---@param cb fun(choice:string)
---@return fun(choice:string) close
function M.ask(opts, cb)
	local prev = vim.api.nvim_get_current_win()
	vim.cmd("stopinsert")
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.body)
	vim.bo[buf].modifiable = false
	if opts.filetype then
		vim.bo[buf].filetype = opts.filetype
	end

	local choices = {}
	if opts.yes then
		choices[#choices + 1] = { key = "y", label = opts.yes, value = "yes" }
	end
	if opts.always then
		choices[#choices + 1] = { key = "a", label = opts.always, value = "always" }
	end
	vim.list_extend(choices, opts.choices or {})
	-- Footer as highlighted chunks: keys stand out from their labels.
	local footer = { { " ", "HarnerConfirmFooter" } }
	local function add_key(key, label)
		if #footer > 1 then
			footer[#footer + 1] = { " · ", "HarnerConfirmFooter" }
		end
		footer[#footer + 1] = { key, "HarnerConfirmKey" }
		footer[#footer + 1] = { " " .. label, "HarnerConfirmFooter" }
	end
	for _, c in ipairs(choices) do
		add_key(c.key, c.label)
	end
	add_key("n", "skip")
	footer[#footer + 1] = { " ", "HarnerConfirmFooter" }
	local footer_text = table.concat(vim.tbl_map(function(c)
		return c[1]
	end, footer))

	local longest = vim.fn.strdisplaywidth(opts.title) + 4
	for _, l in ipairs(opts.body) do
		longest = math.max(longest, vim.fn.strdisplaywidth(l) + 2)
	end
	longest = math.max(longest, vim.fn.strdisplaywidth(footer_text) + 4)
	local width = math.max(20, math.min(longest, vim.o.columns - 8))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.floor(vim.o.lines * 0.3),
		col = math.floor((vim.o.columns - width) / 2),
		width = width,
		height = 1,
		style = "minimal",
		border = "rounded",
		title = { { " " .. opts.title .. " ", "HarnerConfirmTitle" } },
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
		zindex = 60,
	})
	vim.wo[win].winhighlight = "NormalFloat:HarnerConfirmNormal,FloatBorder:HarnerConfirmBorder"
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].breakindent = true
	local height = vim.api.nvim_win_text_height(win, {}).all
	vim.api.nvim_win_set_height(win, math.max(1, math.min(height, vim.o.lines - 8)))

	local done = false
	local function close(choice)
		if done then
			return
		end
		done = true
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
		if vim.api.nvim_win_is_valid(prev) and vim.api.nvim_get_current_win() ~= prev then
			pcall(vim.api.nvim_set_current_win, prev)
		end
		cb(choice)
	end

	local function map(lhs, choice)
		vim.keymap.set("n", lhs, function()
			close(choice)
		end, { buffer = buf, nowait = true })
	end
	for _, c in ipairs(choices) do
		map(c.key, c.value)
	end
	if opts.yes then
		map("<CR>", "yes")
	end
	for _, lhs in ipairs({ "n", "q", "<Esc>", "<C-c>" }) do
		map(lhs, "no")
	end
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(function()
				close("no")
			end)
		end,
	})
	return close
end

return M
