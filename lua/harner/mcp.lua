-- Builds the per-run --mcp-config file and the system note that tells Claude
-- about the editor tools.

local M = {}

local bridge_path = debug.getinfo(1, "S").source:sub(2):gsub("mcp%.lua$", "bridge.lua")

---Make sure this nvim has an RPC address the bridge can connect to.
---@return string
function M.server_address()
	local addr = vim.v.servername
	if addr == nil or addr == "" then
		addr = vim.fn.serverstart()
	end
	return addr
end

---Names of the user's extra MCP servers (`config.mcp_servers`), sorted.
---@return string[]
function M.extra_servers()
	local names = vim.tbl_keys(require("harner").config.mcp_servers or {})
	table.sort(names)
	return names
end

---Tool prefix of a claude.ai connector: "Grafana Cloud" -> mcp__claude_ai_Grafana_Cloud.
---@param name string
---@return string
function M.connector_prefix(name)
	return "mcp__claude_ai_" .. name:gsub("[^%w_-]", "_")
end

---The configured claude.ai connectors (`config.connectors`).
---@return string[]
function M.connectors()
	return require("harner").config.connectors or {}
end

---Server names from every `.mcp.json` between `cwd` and `/`. claude -p has no
---trust prompt, so it would start them (and run their commands) unasked; the
---runner denies them by name. nil means deny by name is not safe (a file that
---does not parse, or a name shared with `nvim` / `config.mcp_servers`, which a
---name deny would also block): the runner falls back to --strict-mcp-config.
---@param cwd string
---@return string[]|nil
function M.project_servers(cwd)
	local own = require("harner").config.mcp_servers or {}
	local names, seen = {}, {}
	for _, path in ipairs(vim.fs.find(".mcp.json", { upward = true, path = cwd, type = "file", limit = math.huge })) do
		local ok, decoded = pcall(function()
			return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
		end)
		if not ok or type(decoded) ~= "table" then
			return nil
		end
		local servers = decoded.mcpServers
		if servers ~= nil and type(servers) ~= "table" then
			return nil
		end
		for name in pairs(servers or {}) do
			if name == "nvim" or own[name] ~= nil then
				return nil
			end
			if not seen[name] then
				seen[name] = true
				names[#names + 1] = name
			end
		end
	end
	table.sort(names)
	return names
end

---Write the MCP config JSON (nvim plus `config.mcp_servers`) and return its
---path. The file may hold API keys, so it is created 0600; the runner deletes
---it when the run ends. Errors when a user server is named `nvim`.
---@param chat_id integer|nil the chat the run belongs to (HARNER_CHAT for the bridge)
---@return string path
function M.write_config(chat_id)
	local env = { HARNER_NVIM = M.server_address() }
	if chat_id then
		env.HARNER_CHAT = tostring(chat_id)
	end
	local servers = {
		nvim = {
			type = "stdio",
			command = vim.v.progpath,
			args = { "-l", bridge_path },
			env = env,
			-- exempt from ToolSearch deferral: the editor tools are used every turn
			alwaysLoad = true,
		},
	}
	local extra = require("harner").config.mcp_servers or {}
	for _, name in ipairs(M.extra_servers()) do
		if name == "nvim" then
			error("mcp_servers: the name `nvim` is reserved for harner's own server; rename it", 0)
		end
		servers[name] = extra[name]
	end
	local path = vim.fn.tempname() .. "-harner-mcp.json"
	local fd = assert(vim.uv.fs_open(path, "w", tonumber("600", 8)))
	assert(vim.uv.fs_write(fd, vim.json.encode({ mcpServers = servers })))
	vim.uv.fs_close(fd)
	return path
end

---What the system note says about the shell: how to use the bash tool, or,
---when it is off, to flag shell-dependent work (skills included) up front.
---@return string
function M.shell_note()
	if require("harner").config.bash.enabled then
		return "mcp__nvim__bash runs shell commands in the working directory (the user confirms each one unless it is "
			.. "allow-listed); use it wherever a task or skill calls for a shell (git, gh, builds, tests), one focused "
			.. "command per call, and keep reading and editing files to Read/Grep/Glob and edit_file."
	end
	return "There is no shell in this session (harner's bash tool is disabled). Before starting a task or skill "
		.. "that needs shell commands (git, gh, builds, tests), say so up front and list which steps you cannot do, "
		.. "rather than stopping partway through; the user can enable it with `bash = { enabled = true }` in "
		.. "require('harner').setup()."
end

---MCP servers and tools approved beyond nvim, as `{ label, rule }`: `rule` goes
---into --allowedTools, `label` into the system note. Covers `config.mcp_servers`,
---`config.connectors` and MCP entries of `config.allowed_tools` (a server or a
---single tool), so the note and the real permissions cannot drift apart.
---@return {label:string, rule:string}[]
function M.approved()
	local list = {}
	for _, name in ipairs(M.extra_servers()) do
		list[#list + 1] = { label = ("%s (tools mcp__%s__*)"):format(name, name), rule = "mcp__" .. name }
	end
	for _, name in ipairs(M.connectors()) do
		local prefix = M.connector_prefix(name)
		list[#list + 1] = { label = ("%s (tools %s__*)"):format(name, prefix), rule = prefix }
	end
	for _, tool in ipairs(require("harner").config.allowed_tools or {}) do
		if tool:match("^mcp__") and tool ~= "mcp__nvim" and not tool:match("^mcp__nvim__") then
			list[#list + 1] = { label = tool, rule = tool }
		end
	end
	return list
end

---What the system note says about MCP servers beyond nvim: the approved ones
---(`approved()`), and that any other server's tools are denied (claude loads
---every configured server, harner approves only these).
---@return string
function M.servers_note()
	local list = vim.tbl_map(function(entry)
		return entry.label
	end, M.approved())
	local deny = "Tools of any other MCP server you may see are not approved here and every call to them is denied, so do not use them."
	if #list == 0 then
		return "Of the MCP servers, only mcp__nvim__ is approved. " .. deny
	end
	return "The user also connected these MCP servers, whose tools are pre-approved: "
		.. table.concat(list, ", ")
		.. ". "
		.. deny
end

---@param cwd string
---@return string
function M.system_note(cwd)
	return table.concat({
		"You are answering inside the user's Neovim through the harner plugin; replies are rendered in a narrow chat split.",
		"Markdown is rendered there (tables aligned with borders, code blocks shaded, URLs and path:line references",
		"clickable), so use tables for tabular data but keep them to a few narrow columns.",
		"Tools prefixed mcp__nvim__ give you the editor: get_current_buffer, get_cursor, get_selection, list_buffers,",
		"get_diagnostics to read what the user is looking at; show_text to display content to them; open_file to jump",
		"the editor to a file and line range; ask_user to ask a question and wait for the answer; run_command to run an",
		"Ex command (the user confirms it unless it is on their allow-list); edit_file, write_file and save_file to change files.",
		"When the user says 'this', 'here', 'the selection' or similar, read the editor first instead of guessing.",
		"A prompt may end with a 'Selection: <path> lines N-M' line: that is a reference, not the text; call get_selection to read those lines before answering.",
		"Use show_text for anything longer than a few lines (code, diffs, generated files, tables) and keep the chat reply brief.",
		"When you point at code, prefer open_file over quoting it. Use ask_user only for decisions you cannot make from the editor.",
		"To change a file, read it first, then call edit_file with old_str copied exactly from the file (enough lines to be unique) and new_str.",
		"The number of tokens used to edit files is best minimized, all else being equal. Therefore, when it will not affect the end result, try to surgically edit a file rather than rewrite the entire thing.",
		"edit_file changes the editor buffer without saving; the user reviews and saves, or call save_file when they ask for the change to be written.",
		"After editing several files, save them with one save_file call listing them all in `paths` (at most one confirm), not one call per file.",
		"write_file and save_file write to disk at once, usually without asking the user (only paths outside the working directory, under .git/ or .claude/, or files that run code when loaded ask first), so only write what the user asked for. write_file is for new files or complete rewrites only.",
		M.shell_note(),
		M.servers_note(),
		"When only discussing a change, show it with show_text (filetype diff or the language) instead of editing.",
		"Working directory: " .. cwd,
	}, " ")
end

return M
