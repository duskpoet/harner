-- Decision log: one JSON line per action that auto mode or the user decided
-- (rule, classifier, or the user's answer to a confirm), so we can see what
-- still asks and later feed the answers back to the classifier.
-- File: config.decisions.path, default stdpath("state")/harner/decisions.jsonl.

local M = {}

local function cfg()
	return require("harner").config.decisions or {}
end

---@return string
function M.path()
	return cfg().path or (vim.fn.stdpath("state") .. "/harner/decisions.jsonl")
end

---Append a decision. Never raises: logging must not break a tool call.
---@param e { tool: string, subject: string, how: "rule"|"classifier"|"user", answer: string|nil, note: string|nil }
function M.record(e)
	if cfg().enabled == false then
		return
	end
	pcall(function()
		local entry = vim.tbl_extend("force", { ts = os.time(), cwd = vim.fn.getcwd() }, e)
		local path = M.path()
		-- commands may carry tokens: private file (0600) in a private dir (0700)
		vim.fn.mkdir(vim.fs.dirname(path), "p", 448)
		local fd = assert(vim.uv.fs_open(path, "a", 384))
		vim.uv.fs_write(fd, vim.json.encode(entry) .. "\n")
		vim.uv.fs_close(fd)
	end)
end

---Every recorded decision, oldest first (unparsable lines skipped).
---@return table[]
function M.read()
	local out = {}
	local f = io.open(M.path(), "r")
	if not f then
		return out
	end
	for line in f:lines() do
		local ok, e = pcall(vim.json.decode, line)
		if ok and type(e) == "table" then
			out[#out + 1] = e
		end
	end
	f:close()
	return out
end

---Grouping key: tool plus the first two words of the command, or the
---directory of the (first) written path.
local function key(e)
	local s = tostring(e.subject or "")
	if e.tool == "bash" or e.tool == "run_command" then
		local w = vim.split(vim.trim(s), "%s+")
		return e.tool .. "  " .. table.concat({ w[1] or "", w[2] or "" }, " ")
	end
	local first = vim.split(s, "\n", { plain = true })[1] or ""
	return e.tool .. "  " .. vim.fn.fnamemodify(first, ":h")
end

---Markdown summary: what asked most and how it was answered.
---@return string
function M.summary()
	local list = M.read()
	local groups, total, asked = {}, #list, 0
	for _, e in ipairs(list) do
		local k = key(e)
		local g = groups[k] or { key = k, n = 0, rule = 0, classifier = 0, yes = 0, no = 0, last = "" }
		groups[k] = g
		g.n = g.n + 1
		if e.how == "user" then
			asked = asked + 1
			if e.answer == "no" then
				g.no = g.no + 1
			else
				g.yes = g.yes + 1
			end
		elseif e.how == "rule" or e.how == "classifier" then
			g[e.how] = g[e.how] + 1
		end
		g.last = tostring(e.subject or ""):gsub("\n", " ")
	end
	local rows = vim.tbl_values(groups)
	table.sort(rows, function(a, b)
		if a.yes + a.no ~= b.yes + b.no then
			return a.yes + a.no > b.yes + b.no
		end
		return a.n > b.n
	end)
	local out = {
		"# harner decisions",
		"",
		string.format("%d decisions, %d asked the user. Log: %s", total, asked, M.path()),
		"",
		"| asked | yes | no | rule | classifier | group | last |",
		"| ----- | --- | -- | ---- | ---------- | ----- | ---- |",
	}
	for _, g in ipairs(rows) do
		local last = #g.last > 60 and (g.last:sub(1, 57) .. "...") or g.last
		out[#out + 1] = string.format(
			"| %d | %d | %d | %d | %d | `%s` | `%s` |",
			g.yes + g.no,
			g.yes,
			g.no,
			g.rule,
			g.classifier,
			g.key,
			(last:gsub("|", "\\|"))
		)
	end
	return table.concat(out, "\n")
end

---Show the summary in a scratch split (`:HarnerDecisions`).
function M.show()
	vim.cmd("botright new")
	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(M.summary(), "\n", { plain = true }))
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
end

return M
