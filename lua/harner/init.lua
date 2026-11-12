-- harner: chat with `claude -p` from a Neovim split. Claude gets MCP tools that
-- read the editor and display content back in it.
--
-- Any number of chats per nvim instance, kept until nvim exits (closing or
-- deleting a chat buffer only hides it). The <leader>h keymaps work from any
-- window: <leader>hh opens an input popup for the current chat (from visual
-- mode it attaches a reference to the selection that Claude reads itself),
-- <leader>ht toggles the chat split, <leader>hn starts a fresh session,
-- <leader>hl picks another chat, <leader>hx cancels the running request.

local M = {}

M.config = {
	claude_cmd = "claude",
	model = nil, ---@type string|nil
	width = 0.4, -- fraction of columns, or absolute columns if >= 1
	-- built-in Claude tools made available (read-only set). ToolSearch defers
	-- MCP tool schemas; without it every loaded server's schemas sit in context.
	builtin_tools = { "Read", "Grep", "Glob", "WebFetch", "ToolSearch" },
	-- pre-approved tools; `mcp__nvim` allows every tool from the nvim MCP server
	allowed_tools = { "mcp__nvim" },
	extra_args = {}, ---@type string[]
	-- extra MCP servers merged next to `nvim` (Claude's mcpServers format), e.g.
	-- linear = { type = "http", url = "https://mcp.linear.app/mcp" }. Each one's
	-- tools are pre-approved (mcp__<name>). OAuth servers work after a `/mcp`
	-- login in interactive claude under the same name and URL; `nvim` is reserved.
	mcp_servers = {}, ---@type table<string, table>
	-- claude.ai connectors to pre-approve, by name as `claude mcp list` shows it
	-- without the "claude.ai " prefix, e.g. { "Grafana Cloud" }. Whatever claude
	-- loads (connectors, `claude mcp add`, plugins) is visible, but only nvim,
	-- mcp_servers, allowed_tools and these are approved; the rest is denied.
	connectors = {}, ---@type string[]
	show_text = {
		mode = "split", ---@type "split"|"vsplit"|"float"
		float_width = 100,
	},
	-- terminal title: mirror the chat state ("thinking…", "running Grep", "idle")
	-- into 'titlestring' so the terminal tab shows what Claude is doing. Works
	-- through ssh/dtach since nvim emits a plain OSC 2. `prefix` is a string or
	-- a function returning one, e.g. to show the dt session the editor runs in:
	--   prefix = function() return vim.env.DT_NAME and ("dt @ " .. vim.env.DT_NAME .. " · ") or "" end
	-- `format(state, chat)` replaces the whole title (prefix is then ignored), e.g.
	--   format = function(state) return "ℌ " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":t") .. " | " .. state end
	title = {
		enabled = false,
		prefix = "", ---@type string|fun(): string
		format = nil, ---@type fun(state: string, chat: table): string|nil
	},
	-- chat transcript decorations: aligned box tables, shaded code blocks,
	-- highlighted URLs and `file.lua:12` references (`gf` follows them), and
	-- 'conceallevel' 2 so markdown markup (`**`, backticks, link targets) hides
	-- off the cursor line. Colours: HarnerCodeBlock, HarnerTableBorder,
	-- HarnerTableHead, HarnerUrl, HarnerFileRef, HarnerToolNote, ...
	render = {
		enabled = true,
		conceal = true,
		tables = true,
	},
	-- the run_command tool: Ex commands Claude may run. `confirm` asks the user
	-- (a confirm float) before each command unless it starts with an `allow` entry
	-- (matched as whole words: "Git log" allows "Git log --oneline", not "Git logx").
	run_command = {
		confirm = true,
		allow = { "edit", "Telescope", "DiffviewOpen", "Git blame", "Git log", "Git diff" },
	},
	-- disk writes (write_file and save_file): by default they go straight to
	-- disk, except outside the working directory, under .git/ or .claude/, and
	-- files that run code when loaded (.nvim.lua, .envrc, ...), which always
	-- ask. `confirm = true` asks for every write while auto mode is off.
	-- edit_file never asks: it changes the buffer, unsaved and undoable.
	write_file = {
		confirm = false,
	},
	-- the bash tool: shell commands Claude may run in the working directory.
	-- Off unless enabled. `confirm` asks before each command unless it starts
	-- with an `allow` entry (whole words) and contains no shell operators
	-- (; & | < > $ ` \ ( ) { } or a newline), e.g. allow = { "git status", "gh pr view" }.
	-- Arguments are not checked: list specific read-only subcommands, never a
	-- bare program ("git" lets `git -c alias.x='!cmd' x` run anything) or one
	-- that writes through options (`git diff --output=FILE`) or runs scripts.
	bash = {
		enabled = false,
		confirm = true,
		allow = {}, ---@type string[]
		shell = "bash", -- run as `<shell> -c <command>`
		timeout = 120, -- seconds, when Claude gives none (Claude may ask for up to 540)
		max_output = 30000, -- bytes returned to Claude; the middle is cut beyond that
	},
	-- auto mode: fewer confirms, per chat (<leader>ha / :HarnerAuto toggles it,
	-- a new chat starts at `enabled`). With it on, writes inside the working
	-- directory (not .git/, .claude/ or files that run code when loaded, like
	-- .nvim.lua; only matters with write_file.confirm = true) and built-in read-only bash commands (git status/log/diff/show/blame,
	-- ls, rg, ...) plus `allow` run without asking; other bash and run_command
	-- calls go to a classifier (`claude -p --model <model>`) that either lets
	-- them run or hands them to the normal confirm with its reason. Writes the
	-- rules flag (outside cwd, .git/, .claude/) go to the classifier too, except
	-- files that run code or grant permissions (.nvim.lua, .envrc, .git/hooks/,
	-- .git/config, .claude/settings*.json), which always ask.
	auto = {
		enabled = true,
		allow = {}, ---@type string[] extra bash prefixes (whole words, no shell operators)
		model = "haiku",
		timeout = 15, -- seconds for the classifier; on timeout the user is asked
	},
	-- log of what auto mode and the user decided (:HarnerDecisions summarises it)
	decisions = {
		enabled = true,
		path = nil, ---@type string|nil default stdpath("state")/harner/decisions.jsonl
	},
	-- global normal-mode keymaps; set one to false to skip it
	keys = {
		group = "<leader>h", -- which-key group label, false to skip
		ask = "<leader>hh", -- input popup for the current chat (visual: attaches a selection reference)
		toggle = "<leader>ht", -- show/hide the chat split
		new = "<leader>hn", -- fresh chat (new Claude session)
		cancel = "<leader>hx", -- cancel the running request
		auto = "<leader>ha", -- toggle auto mode for the current chat
		list = "<leader>hl", -- pick one of this nvim's chats (:HarnerChats)
	},
	-- the input popup (<leader>hh / :HarnerAsk)
	prompt = {
		width = 0.6, -- fraction of columns, or absolute columns if >= 1
		min_height = 1,
		max_height = 10,
		border = "rounded",
		open_chat = true, -- open the chat split (unfocused) when sending from the popup
	},
}

---@param opts table|nil
function M.setup(opts)
	if vim.fn.has("nvim-0.10") == 0 then
		vim.notify("harner requires Neovim 0.10 or newer", vim.log.levels.ERROR)
		return
	end
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})
	math.randomseed(vim.uv.hrtime() % 2147483647)

	local chat = function()
		return require("harner.chat")
	end
	local prompt = function()
		return require("harner.prompt")
	end

	vim.api.nvim_create_user_command("Harner", function()
		chat().toggle()
	end, { desc = "Toggle harner chat" })
	vim.api.nvim_create_user_command("HarnerNew", function()
		chat().new()
	end, { desc = "New harner chat (fresh Claude session)" })
	vim.api.nvim_create_user_command("HarnerCancel", function()
		chat().cancel()
	end, { desc = "Cancel the running harner request" })
	vim.api.nvim_create_user_command("HarnerChats", function()
		chat().pick()
	end, { desc = "Pick a harner chat to show" })
	vim.api.nvim_create_user_command("HarnerAuto", function()
		require("harner.auto").toggle()
	end, { desc = "Toggle harner auto mode for the current chat" })
	vim.api.nvim_create_user_command("HarnerDecisions", function()
		require("harner.decisions").show()
	end, { desc = "Summarise what harner asked and how it was answered" })
	vim.api.nvim_create_user_command("HarnerAsk", function(cmd)
		local ref = nil
		if cmd.range > 0 then
			ref = { path = vim.api.nvim_buf_get_name(0), first = cmd.line1, last = cmd.line2 }
		end
		if cmd.args ~= "" then
			local text = cmd.args
			if ref then
				text = text .. "\n\n" .. prompt().ref_line(ref)
			end
			chat().ask(text)
		else
			prompt().open({ ref = ref })
		end
	end, { nargs = "*", range = true, desc = "Ask the harner chat (popup when no text is given; a range is attached as a reference)" })

	local keys = M.config.keys or {}
	local function map(lhs, rhs, desc)
		if lhs and lhs ~= "" then
			vim.keymap.set("n", lhs, rhs, { desc = desc })
		end
	end
	-- bash commands run detached (own session) and would outlive nvim
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("harner", { clear = true }),
		callback = function()
			local tools = package.loaded["harner.tools"]
			if tools then
				tools.kill_running(nil, true)
			end
		end,
	})

	map(keys.ask, function()
		prompt().open()
	end, "Harner: ask (input popup)")
	if keys.ask and keys.ask ~= "" then
		vim.keymap.set("x", keys.ask, function()
			prompt().open({ ref = prompt().selection_ref() })
		end, { desc = "Harner: ask about the selection" })
	end
	map(keys.toggle, function()
		chat().toggle()
	end, "Harner: toggle chat")
	map(keys.new, function()
		chat().new()
	end, "Harner: new chat")
	map(keys.cancel, function()
		chat().cancel()
	end, "Harner: cancel request")
	map(keys.auto, function()
		require("harner.auto").toggle()
	end, "Harner: toggle auto mode")
	map(keys.list, function()
		chat().pick()
	end, "Harner: pick a chat")
	if keys.group and keys.group ~= "" then
		local ok, wk = pcall(require, "which-key")
		if ok and wk.add then
			wk.add({ { keys.group, group = "harner" } })
		end
	end
end

M.toggle = function()
	require("harner.chat").toggle()
end
M.new = function()
	require("harner.chat").new()
end
M.ask = function(text)
	if text and text ~= "" then
		return require("harner.chat").ask(text)
	end
	require("harner.prompt").open()
end

return M
