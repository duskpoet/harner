local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local check = t.check
-- Transcript decorations (render.lua): table alignment + box overlays, code
-- block shading, tool note / separator groups, URL and path:line references,
-- gf following a reference. Offline, no runner involved.

require("harner").setup({})
local render = require("harner.render")
local chat = require("harner.chat")
local SEP = string.rep("─", 40)
local ns = vim.api.nvim_create_namespace("harner_render")

local c = chat.ensure()
local buf = c.buf
local function marks()
	return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
end
local function with_hl(group)
	return vim.tbl_filter(function(m)
		return m[4].hl_group == group
	end, marks())
end

-- 1. refs: URLs drop trailing punctuation, path:line refs outside URLs
local r = render.refs("see https://example.com/a_(b). and chat.lua:12-20, x.y")
check(#r == 2, "two refs, got " .. #r)
check(r[1].kind == "url" and r[1].text == "https://example.com/a_(b)", "url text: " .. tostring(r[1].text))
check(r[2].kind == "file" and r[2].text == "chat.lua:12-20", "file ref: " .. tostring(r[2] and r[2].text))
check(#render.refs("https://host.com:443/x") == 1, "port inside a URL is not a file ref")

-- 2. a finished exchange with a table, code block, tool note
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
	"## Claude",
	"",
	"_→ nvim:show_text · Hello_",
	"",
	"| name | **value** | n |",
	"|---|:-:|--:|",
	"| a | `x|y` | 1 |",
	"| longer name | b | 100 |",
	"",
	"```lua",
	"local x = 1",
	"```",
	"Open lua/harner/chat.lua:3 or https://neovim.io.",
	SEP,
	"| typed | by user |",
	"|---|---|",
})
render.render(buf)
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check(lines[5] == "| name        | **value** |   n |", "header padded: " .. lines[5])
-- widths follow what conceal shows: `**value**` and `x|y` take 5 and 3 columns
check(lines[6] == "|-------------|:-----:|----:|", "delimiter padded: " .. lines[6])
check(lines[7] == "| a           |  `x|y`  |   1 |", "code span keeps its pipe: " .. lines[7])
check(lines[8] == "| longer name |   b   | 100 |", "centered / right aligned: " .. lines[8])
check(lines[15] == "| typed | by user |", "input area left alone")
check(#lines == 16, "line count unchanged")

local top, bottom, overlay = false, false, 0
for _, m in ipairs(marks()) do
	local d = m[4]
	if d.virt_lines and d.virt_lines_above and m[2] == 4 then
		top = d.virt_lines[1][1][1]:sub(1, 3) == "┌"
	elseif d.virt_lines and m[2] == 7 then
		bottom = d.virt_lines[1][1][1]:sub(1, 3) == "└"
	elseif d.virt_text_pos == "overlay" then
		overlay = overlay + 1
	end
end
check(top and bottom, "top and bottom borders")
check(overlay == 4 * 3 + 1, "pipe overlays on 3 rows + delimiter, got " .. overlay)
check(#with_hl("HarnerTableHead") == 1, "header highlighted")
check(#with_hl("HarnerCodeBlock") == 1, "one code line shaded")
check(#with_hl("HarnerToolNote") == 1 and #with_hl("HarnerSeparator") == 1, "note and separator")
check(#with_hl("HarnerUrl") == 1 and #with_hl("HarnerFileRef") == 1, "url and file ref")

-- 2b. backslash escapes stay visible, so they count in the width
local esc = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(esc, 0, -1, false, { "| a \\| b | c |", "|---|---|", "| xxxxxx | d |", "" })
render.attach(esc, function()
	return 3
end)
local el = vim.api.nvim_buf_get_lines(esc, 0, 3, false)
check(el[1] == "| a \\| b | c |" and el[3] == "| xxxxxx | d |", "escaped pipe counted in full: " .. el[1])

-- 2b''. ``a|b`` is one cell; a lone backtick does not swallow the rest of the row
vim.api.nvim_buf_set_lines(esc, 0, -1, false, { "| ``a|b`` | c |", "|---|---|", "| it`s | d |", "" })
render.render(esc)
local bl = vim.api.nvim_buf_get_lines(esc, 0, 3, false)
-- (column width 4: `it`s`, while the span shows as `a|b`)
check(bl[1] == "| ``a|b``  | c |", "double-backtick span kept whole: " .. bl[1])
check(bl[3] == "| it`s | d |", "lone backtick: " .. bl[3])

-- 2b'. with conceal off the markup is visible, so it counts
require("harner").config.render.conceal = false
vim.api.nvim_buf_set_lines(esc, 0, -1, false, { "| **a** | b |", "|---|---|", "| xxxxx | d |", "" })
render.render(esc)
check(vim.api.nvim_buf_get_lines(esc, 2, 3, false)[1] == "| xxxxx | d |", "raw width without conceal")
require("harner").config.render.conceal = true

-- 2c. a steady stream of changes (every 10 ms) still gets rendered: throttled, not debounced
vim.api.nvim_buf_set_lines(esc, 0, -1, false, { "| a | b |", "|---|---|", "| long cell | c |", "" })
local rendered = false
for _ = 1, 15 do
	vim.api.nvim_buf_set_lines(esc, -1, -1, false, { "x" })
	vim.wait(10)
	rendered = rendered or vim.api.nvim_buf_get_lines(esc, 0, 1, false)[1] == "| a         | b |"
end
check(rendered, "rendered while changes kept coming")

-- 3. idempotent: a second pass changes nothing
render.render(buf)
check(vim.deep_equal(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false)), "second pass is a no-op")

-- 3b. later passes start after the last separator: marks above it are kept,
-- and an edit above it brings a full pass back
local before = #marks()
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "more https://x.org" })
render.render(buf)
check(#marks() == before + 1, "finished exchange kept, one new url mark: " .. before .. " → " .. #marks())
vim.api.nvim_buf_set_lines(buf, 4, 5, false, { "| name | **value** | nn |" })
render.render(buf)
check(vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1] == "| name        | **value** |  nn |", "edit above re-rendered")
check(#marks() == before + 1, "same marks after the full pass")

-- 4. while streaming, the last line is not touched
c.run = {}
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "| a | b |", "|---|---|", "| partial" })
render.render(buf)
check(vim.api.nvim_buf_get_lines(buf, -2, -1, false)[1] == "| partial", "streaming line untouched")
c.run = nil

-- 5. gf on a file reference opens it in the editor window
local file = vim.fn.tempname() .. ".lua"
vim.fn.writefile({ "one", "two", "three" }, file)
vim.cmd("enew")
local editor = vim.api.nvim_get_current_win()
chat.open()
local cw = vim.api.nvim_get_current_win()
check(vim.wo[cw].conceallevel == 2, "conceal on in the chat window")
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "see " .. file .. ":3 here" })
vim.api.nvim_win_set_cursor(cw, { vim.api.nvim_buf_line_count(buf), 6 })
check(vim.fn.maparg("gf", "n", false, true).buffer == 1, "gf mapped in the chat buffer")
render.follow()
check(vim.api.nvim_get_current_win() == editor, "opened in the editor window")
check(vim.api.nvim_buf_get_name(0) == file, "right file")
check(vim.api.nvim_win_get_cursor(0)[1] == 3, "right line")

-- 5b. gf on a plain path (no :line) opens it too
vim.cmd("enew") -- move the editor window off the file first
vim.api.nvim_set_current_win(cw)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "plain " .. file })
vim.api.nvim_win_set_cursor(cw, { vim.api.nvim_buf_line_count(buf), 8 })
render.follow()
check(vim.api.nvim_get_current_win() ~= cw and vim.api.nvim_buf_get_name(0) == file, "plain path opened")

-- 6. open_ref searches below cwd for a bare tail or partial path
local tools = require("harner.tools")
check(tools.open_ref("render.lua", 2), "tail found below cwd")
check(vim.endswith(vim.api.nvim_buf_get_name(0), "lua/harner/render.lua"), "right file for the tail")
check(tools.open_ref("harner/chat.lua", 1) and vim.endswith(vim.api.nvim_buf_get_name(0), "lua/harner/chat.lua"), "partial path")
check(not tools.open_ref("localhost.localdomain", 8080), "false positive: nothing found")
-- heavy directories are not searched
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/node_modules/pkg", "p")
vim.fn.writefile({ "x" }, tmp .. "/node_modules/pkg/hidden.lua")
local cwd = vim.fn.getcwd()
vim.cmd.cd(tmp)
check(not tools.open_ref("hidden.lua", 1), "node_modules skipped")
vim.cmd.cd(cwd)

t.finish()
