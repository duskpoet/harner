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

---Write the MCP config JSON and return its path.
---@return string path
function M.write_config()
	local cfg = {
		mcpServers = {
			nvim = {
				type = "stdio",
				command = vim.v.progpath,
				args = { "-l", bridge_path },
				env = { HARNER_NVIM = M.server_address() },
			},
		},
	}
	local path = vim.fn.tempname() .. "-harner-mcp.json"
	local f = assert(io.open(path, "w"))
	f:write(vim.json.encode(cfg))
	f:close()
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

---@param cwd string
---@return string
function M.system_note(cwd)
	return table.concat({
		"You are answering inside the user's Neovim through the harner plugin; replies are rendered in a narrow chat split.",
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
		"After editing several files, save them with one save_file call listing them all in `paths` (the user confirms once), not one call per file.",
		"write_file (confirmed by the user) is for new files or complete rewrites only.",
		M.shell_note(),
		"When only discussing a change, show it with show_text (filetype diff or the language) instead of editing.",
		"Working directory: " .. cwd,
	}, " ")
end

return M
