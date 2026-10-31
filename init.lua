-- harner: chat with `claude -p` from a Neovim split. Claude gets MCP tools that
-- read the editor and display content back in it.
--
-- One chat session per nvim instance. The <leader>h keymaps work from any
-- window: <leader>hh opens an input popup for the current chat (from visual
-- mode it attaches a reference to the selection that Claude reads itself),
-- <leader>ht toggles the chat split, <leader>hn starts a fresh session,
-- <leader>hx cancels the running request.

local M = {}

M.config = {
	claude_cmd = "claude",
	model = nil, ---@type string|nil
	width = 0.4, -- fraction of columns, or absolute columns if >= 1
	-- built-in Claude tools made available (read-only set)
	builtin_tools = { "Read", "Grep", "Glob", "WebFetch" },
	-- pre-approved tools; `mcp__nvim` allows every tool from the nvim MCP server
	allowed_tools = { "mcp__nvim" },
	extra_args = {}, ---@type string[]
	show_text = {
		mode = "split", ---@type "split"|"vsplit"|"float"
		float_width = 100,
	},
	-- the run_command tool: Ex commands Claude may run. `confirm` asks the user
	-- (vim.ui.select) before each command unless it starts with an `allow` entry
	-- (matched as whole words: "Git log" allows "Git log --oneline", not "Git logx").
	run_command = {
		confirm = true,
		allow = { "edit", "Telescope", "DiffviewOpen", "Git blame", "Git log", "Git diff" },
	},
	-- global normal-mode keymaps; set one to false to skip it
	keys = {
		group = "<leader>h", -- which-key group label, false to skip
		ask = "<leader>hh", -- input popup for the current chat (visual: attaches a selection reference)
		toggle = "<leader>ht", -- show/hide the chat split
		new = "<leader>hn", -- fresh chat (new Claude session)
		cancel = "<leader>hx", -- cancel the running request
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
