-- Decorations for the chat transcript: aligned box tables, shaded code
-- blocks, tool notes / separators / errors in their own groups, underlined
-- URLs and `file.lua:12` references (followed with `gf`). Markdown itself is
-- highlighted by treesitter; with 'conceallevel' 2 its queries hide `**`,
-- backticks, fence lines and link targets.
--
-- Tables are the one thing that changes text: once a table's rows are
-- complete its cells are padded so the columns line up (same line count, so
-- line-based bookkeeping in chat.lua is unaffected); the pipes are then
-- overlaid with box-drawing characters.
local M = {}

local ns = vim.api.nvim_create_namespace("harner_render")
local SEP = string.rep("─", 40)
local DELAY_MS = 40

local function define_hl()
	local hl = function(name, link)
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
	hl("HarnerCodeBlock", "ColorColumn")
	hl("HarnerCodeLang", "Comment")
	hl("HarnerToolNote", "Comment")
	hl("HarnerSeparator", "WinSeparator")
	hl("HarnerError", "DiagnosticError")
	hl("HarnerTableBorder", "Comment")
	hl("HarnerTableHead", "Title")
	hl("HarnerUrl", "@markup.link.url")
	hl("HarnerFileRef", "Directory")
end
define_hl()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("harner_render_hl", { clear = true }),
	callback = define_hl,
})

local function cfg()
	local ok, harner = pcall(require, "harner")
	return ok and harner.config.render or {}
end

---Whether decorations are on (`config.render.enabled`, default true).
function M.enabled()
	return cfg().enabled ~= false
end

---Window options the chat window gets.
---@param win integer
function M.setup_win(win)
	if not M.enabled() then
		return
	end
	vim.wo[win].conceallevel = cfg().conceal == false and 0 or 2
	vim.wo[win].concealcursor = "" -- the cursor line shows the raw markdown
end

-- ── tables ──────────────────────────────────────────────────────────────

---Cells of a `| a | b |` row, nil when the line is not one. Pipes inside
---code spans and escaped pipes do not split.
---@param line string
---@return string[]|nil, string|nil indent
local function split_row(line)
	local indent, body = line:match("^(%s*)|(.*)|%s*$")
	if not body then
		return nil
	end
	-- `code`: length of the backtick run that opened the current span (a span
	-- closes only on a run of the same length, so ``a|b`` stays one cell)
	local cells, start, i, code = {}, 1, 1, nil
	while i <= #body do
		local c = body:sub(i, i)
		if c == "\\" and not code then
			i = i + 1
		elseif c == "`" then
			local run = #body:match("^`+", i)
			if not code then
				-- only an opener when a closing run of the same length follows
				local rest = body:sub(i + run)
				local closes = ("\0" .. rest .. "\0"):find("[^`]" .. string.rep("`", run) .. "[^`]")
				code = closes and run or nil
			elseif run == code then
				code = nil
			end
			i = i + run - 1
		elseif c == "|" and not code then
			cells[#cells + 1] = vim.trim(body:sub(start, i - 1))
			start = i + 1
		end
		i = i + 1
	end
	cells[#cells + 1] = vim.trim(body:sub(start))
	return cells, indent
end

---Alignments of a delimiter row (`|:--|--:|`), nil when it is not one.
---@param cells string[]
---@return string[]|nil
local function delimiter(cells)
	local aligns = {}
	for i, c in ipairs(cells) do
		if not c:match("^:?%-+:?$") then
			return nil
		end
		local l, r = c:sub(1, 1) == ":", c:sub(-1) == ":"
		aligns[i] = l and r and "center" or r and "right" or l and "left" or "none"
	end
	return aligns
end

---Display width of a cell as treesitter's conceal shows it (approximate:
---code spans, links, `**`/`__`/`~~` and single `*`/`_` emphasis; backslash
---escapes are highlighted, not concealed, so they count in full).
---@param cell string
local function visible_width(cell)
	if cfg().conceal == false then
		return vim.fn.strdisplaywidth(cell)
	end
	local codes = {}
	local s = cell:gsub("`([^`]*)`", function(inner)
		codes[#codes + 1] = inner
		return "\1" .. #codes .. "\2"
	end)
	s = s:gsub("!?%[([^%]]*)%]%b()", "%1")
	s = s:gsub("%*%*", ""):gsub("~~", ""):gsub("%f[%w_]__", ""):gsub("__%f[^%w_]", "")
	s = s:gsub("%f[%w*]%*([^%s*][^*]-)%*", "%1"):gsub("%f[%w_]_([^%s_][^_]-)_%f[^%w_]", "%1")
	s = s:gsub("\1(%d+)\2", function(n)
		return codes[tonumber(n)]
	end)
	return vim.fn.strdisplaywidth(s)
end

local function pad(cell, width, align)
	local gap = math.max(0, width - visible_width(cell))
	if align == "right" then
		return string.rep(" ", gap) .. cell
	elseif align == "center" then
		local left = math.floor(gap / 2)
		return string.rep(" ", left) .. cell .. string.rep(" ", gap - left)
	end
	return cell .. string.rep(" ", gap)
end

---Aligned lines for a parsed table plus the byte columns of each row's pipes.
---@param rows string[][] header, delimiter, body rows
---@param aligns string[]
---@param indent string
---@return string[] lines, integer[][] pipes, integer[] widths
local function layout(rows, aligns, indent)
	local ncol = 0
	for _, r in ipairs(rows) do
		ncol = math.max(ncol, #r)
	end
	local widths = {}
	for c = 1, ncol do
		local w = 1
		for i, r in ipairs(rows) do
			if i ~= 2 and r[c] then
				w = math.max(w, visible_width(r[c]))
			end
		end
		widths[c] = w
	end
	local lines, pipes = {}, {}
	for i, r in ipairs(rows) do
		local parts, cols, col = {}, {}, #indent
		cols[1] = col
		for c = 1, ncol do
			local a = aligns[c] or "none"
			local part
			if i == 2 then
				local w = widths[c]
				part = (a == "left" or a == "center") and ":" or "-"
				part = part .. string.rep("-", w) .. ((a == "right" or a == "center") and ":" or "-")
			else
				part = " " .. pad(r[c] or "", widths[c], a) .. " "
			end
			parts[c] = part
			col = col + 1 + #part
			cols[#cols + 1] = col
		end
		lines[i] = indent .. "|" .. table.concat(parts, "|") .. "|"
		pipes[i] = cols
	end
	return lines, pipes, widths
end

local function border(widths, l, m, r)
	local segs = {}
	for i, w in ipairs(widths) do
		segs[i] = string.rep("─", w + 2)
	end
	return l .. table.concat(segs, m) .. r
end

---Align and decorate the table on `lines[fi..li]`; `lines[1]` is buffer row `base`.
local function render_table(buf, base, fi, li, lines, aligns, indent)
	local rows = {}
	for i = fi, li do
		rows[#rows + 1] = split_row(lines[i])
	end
	local first, last = base + fi - 1, base + li - 1 -- 0-based buffer rows
	local out, pipes, widths = layout(rows, aligns, indent)
	for k, l in ipairs(out) do
		if lines[fi + k - 1] ~= l then
			vim.api.nvim_buf_set_lines(buf, first + k - 1, first + k, false, { l })
			lines[fi + k - 1] = l
		end
	end
	local mark = function(row, col, opts)
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
	end
	mark(first, 0, {
		virt_lines = { { { indent .. border(widths, "┌", "┬", "┐"), "HarnerTableBorder" } } },
		virt_lines_above = true,
	})
	mark(last, 0, {
		virt_lines = { { { indent .. border(widths, "└", "┴", "┘"), "HarnerTableBorder" } } },
	})
	for i, cols in ipairs(pipes) do
		local row = first + i - 1
		if i == 2 then
			mark(row, #indent, {
				virt_text = { { border(widths, "├", "┼", "┤"), "HarnerTableBorder" } },
				virt_text_pos = "overlay",
			})
		else
			for _, col in ipairs(cols) do
				mark(row, col, { virt_text = { { "│", "HarnerTableBorder" } }, virt_text_pos = "overlay" })
			end
			if i == 1 then
				mark(row, cols[1] + 1, { end_col = cols[#cols], hl_group = "HarnerTableHead", priority = 90 })
			end
		end
	end
end

-- ── inline references ───────────────────────────────────────────────────

local URL = "https?://[%w%-%._~:/%?#%[%]@!%$&'%(%)%*%+,;=%%]+"
local REF = "[%w_%-%./~]*[%w_]%.%a[%w]*:%d+%-?%d*"

---URL and `path:line` spans on a line: `{ s, e, kind, text }`, 1-based
---inclusive byte columns.
---@param line string
---@return table[]
function M.refs(line)
	local found = {}
	local init = 1
	while true do
		local s, e = line:find(URL, init)
		if not s then
			break
		end
		local url = line:sub(s, e)
		-- trailing punctuation belongs to the sentence (keep balanced parens)
		while url:match("[%.,;:!%?'\"%]]$") or (url:match("%)$") and select(2, url:gsub("%(", "")) < select(2, url:gsub("%)", ""))) do
			url = url:sub(1, -2)
		end
		e = s + #url - 1
		found[#found + 1] = { s = s, e = e, kind = "url", text = url }
		init = e + 1
	end
	local function in_url(s, e)
		for _, f in ipairs(found) do
			if s <= f.e and e >= f.s then
				return true
			end
		end
		return false
	end
	init = 1
	local urls = #found
	while true do
		local s, e = line:find("%f[%w_%-%./~]" .. REF, init)
		if not s then
			break
		end
		local text = line:sub(s, e):gsub("%-$", "")
		e = s + #text - 1
		if not in_url(s, e) then
			found[#found + 1] = { s = s, e = e, kind = "file", text = text }
		end
		init = e + 1
	end
	if #found > urls then
		table.sort(found, function(a, b)
			return a.s < b.s
		end)
	end
	return found
end

-- ── whole-buffer pass ───────────────────────────────────────────────────

---`done`: 0-based row after the last separator rendered; rows above it are
---finished exchanges whose decorations stay, so passes start there.
---@type table<integer, { limit: fun(): integer, done: integer, timer: uv.uv_timer_t|nil, pending: boolean|nil, failed: boolean|nil }>
local state = {}

---Re-render the decorations of `buf` from the last finished exchange on (the
---whole buffer after attach or a change above it). Tables are only aligned on
---lines `1..limit` (complete lines: not the input area, not the line still
---streaming).
---@param buf integer
function M.render(buf)
	local st = state[buf]
	if not st or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local base = st.done
	local lines = vim.api.nvim_buf_get_lines(buf, base, -1, false)
	local limit = math.min(st.limit() - base, #lines) -- relative to `lines`
	vim.api.nvim_buf_clear_namespace(buf, ns, base, -1)
	local mark = function(row, col, opts)
		pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
	end
	local tables = cfg().tables ~= false

	local fence, fence_start = nil, nil
	local delims = {} ---@type table<integer, true> fence lines (0-based rows)
	local sep = nil ---@type integer|nil row after the last finished separator
	local i = 1
	while i <= #lines do
		local line = lines[i]
		local row = base + i - 1
		local open = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
		if fence then
			if open and open:sub(1, 1) == fence:sub(1, 1) and #open >= #fence and line:match("^%s*[`~]+%s*$") then
				fence = nil
				delims[row] = true
			else
				mark(row, 0, { end_row = row + 1, hl_group = "HarnerCodeBlock", hl_eol = true, priority = 40 })
				if row == fence_start.row + 1 and fence_start.lang ~= "" then
					mark(row, 0, {
						virt_text = { { fence_start.lang .. " ", "HarnerCodeLang" } },
						virt_text_pos = "right_align",
					})
				end
			end
			i = i + 1
		elseif open then
			fence = open
			fence_start = { row = row, lang = vim.trim((line:gsub("^%s*[`~]+", ""))) }
			delims[row] = true
			i = i + 1
		else
			-- a table: header row, delimiter row, then rows while they parse
			local head, indent = split_row(line)
			local delim = head and i + 1 <= limit and split_row(lines[i + 1])
			local aligns = delim and delimiter(delim)
			if tables and aligns and i <= limit then
				local last = i + 1
				while last + 1 <= limit and split_row(lines[last + 1]) do
					last = last + 1
				end
				render_table(buf, base, i, last, lines, aligns, indent)
				i = last + 1
			else
				if line == SEP then
					mark(row, 0, { end_col = #line, hl_group = "HarnerSeparator" })
					if i <= limit then
						sep = row + 1
					end
				elseif vim.startswith(line, "_→ ") then
					mark(row, 0, { end_col = #line, hl_group = "HarnerToolNote", priority = 110 })
				elseif vim.startswith(line, "> **error:**") then
					mark(row, 0, { end_col = #line, hl_group = "HarnerError", priority = 110 })
				end
				i = i + 1
			end
		end
	end
	-- inline references (after the table pass, which may have re-padded lines)
	for n, line in ipairs(lines) do
		local row = base + n - 1
		if not delims[row] then
			for _, r in ipairs(M.refs(line)) do
				mark(row, r.s - 1, {
					end_col = r.e,
					hl_group = r.kind == "url" and "HarnerUrl" or "HarnerFileRef",
					priority = 120,
				})
			end
		end
	end
	if sep then
		st.done = sep
	end
end

---Re-render `buf` shortly. Throttled, not debounced: a pending render is
---left alone, so a steady stream still re-renders every DELAY_MS.
---@param buf integer
function M.schedule(buf)
	local st = state[buf]
	if not st or st.pending then
		return
	end
	if not st.timer then
		st.timer = vim.uv.new_timer()
	end
	st.pending = true
	st.timer:start(DELAY_MS, 0, function()
		vim.schedule(function()
			st.pending = false
			local ok, err = pcall(M.render, buf)
			if not ok and not st.failed then
				st.failed = true -- report once, not on every streamed chunk
				vim.notify("harner: render failed: " .. tostring(err), vim.log.levels.WARN)
			end
		end)
	end)
end

---Decorate a chat buffer and keep it decorated as it changes.
---@param buf integer
---@param limit fun(): integer last line (1-based) whose tables may be aligned
function M.attach(buf, limit)
	if not M.enabled() then
		return
	end
	state[buf] = { limit = limit, done = 0 }
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, _, _, first)
			local st = state[buf]
			if not st then
				return true
			end
			if first < st.done then
				st.done = 0 -- a finished exchange changed: full pass
			end
			M.schedule(buf)
		end,
		on_detach = function()
			local st = state[buf]
			if st and st.timer then
				st.timer:stop()
				st.timer:close()
			end
			state[buf] = nil
		end,
	})
	M.render(buf)
end

-- ── gf ──────────────────────────────────────────────────────────────────

---Follow the URL, markdown link or `file.lua:12` reference under the cursor:
---URLs open with vim.ui.open, files in the editor window next to the chat.
function M.follow()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2] + 1
	local target
	-- [text](dest): the destination is concealed, so the cursor sits on the text
	for s, dest, e in line:gmatch("()%[[^%]]*%]%(([^%)]+)%)()") do
		if col >= s and col < e then
			target = { kind = dest:match("^%a+://") and "url" or "file", text = dest }
		end
	end
	if not target then
		for _, r in ipairs(M.refs(line)) do
			if col >= r.s and col <= r.e then
				target = r
			end
		end
	end
	if not target then
		-- a plain path, like the built-in gf (but opened in the editor window)
		local ok, cfile = pcall(vim.fn.expand, "<cfile>") -- E446 when there is none
		if not ok or cfile == "" then
			vim.notify("harner: no link or file reference under the cursor", vim.log.levels.INFO)
			return
		end
		target = { kind = "file", text = cfile }
	end
	if target.kind == "url" then
		vim.ui.open(target.text)
		return
	end
	local path, a, b = target.text:match("^(.-):(%d+)%-?(%d*)$")
	path = path or target.text
	if not require("harner.tools").open_ref(path, tonumber(a), tonumber(b)) then
		vim.notify("harner: cannot find " .. path, vim.log.levels.WARN)
	end
end

return M
