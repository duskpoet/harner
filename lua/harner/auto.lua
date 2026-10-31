-- Auto mode: fewer confirms. Per chat (`chat.auto`, default
-- config.auto.enabled, toggled with <leader>ha / :HarnerAuto). With it on,
-- a confirmable action that the user's own allow-lists and grants do not
-- cover is checked in order:
--   1. static rules (writes inside cwd, a built-in read-only bash list plus
--      config.auto.allow) -> runs without asking
--   2. bash / run_command only: a classifier (`claude -p` on a small model)
--      -> ALLOW runs, ASK opens the normal confirm with its reason
--   3. anything else asks as usual.
-- The classifier never denies on its own; errors and timeouts ask.

local M = {}

local function cfg()
	return require("harner").config.auto
end

local function current_chat()
	local chat = require("harner.chat")
	return chat.current and chat.chats[chat.current]
end

---True when the current chat runs in auto mode.
function M.enabled()
	local c = current_chat()
	if c then
		return c.auto == true
	end
	return cfg().enabled == true
end

---Flip auto mode for the current chat (created if needed).
function M.toggle()
	local chat = require("harner.chat")
	local c = chat.ensure()
	c.auto = not c.auto
	chat.refresh_winbar(c)
	vim.notify("harner: auto mode " .. (c.auto and "on" or "off"))
	return c.auto
end

-- ---------------------------------------------------------------------------
-- Writes

-- Files that run code when nvim (exrc), lazy.nvim or direnv load them.
local CODE_FILES = { [".nvim.lua"] = true, [".nvimrc"] = true, [".exrc"] = true, [".lazy.lua"] = true, [".envrc"] = true }

---Real path of `path`, resolving symlinks through its nearest existing ancestor
---(the file, or directories create_dirs would make, may not exist yet).
local function real(path)
	path = vim.fs.normalize(path)
	local rest = {}
	local p = path
	while p and p ~= "" do
		local r = vim.uv.fs_realpath(p)
		if r then
			for i = #rest, 1, -1 do
				r = r .. "/" .. rest[i]
			end
			return vim.fs.normalize(r)
		end
		local parent = vim.fs.dirname(p)
		if parent == p then
			break
		end
		rest[#rest + 1] = vim.fs.basename(p)
		p = parent
	end
	return path
end

---Path of `path` relative to the real cwd, or nil when it is outside.
local function inside_cwd(path)
	local root = real(vim.fn.getcwd())
	local abs = path
	if not abs:match("^/") then
		abs = vim.fn.getcwd() .. "/" .. abs
	end
	-- collapse . and .. before resolving
	abs = vim.fn.simplify(abs)
	local r = real(abs)
	if r == root then
		return nil
	end
	if vim.startswith(r, root .. "/") then
		return r:sub(#root + 2)
	end
	return nil
end

---Why a write to `path` must still be confirmed, or nil when auto may write it.
---@param path string absolute path
---@return string|nil
function M.write_blocker(path)
	local relp = inside_cwd(path)
	if not relp then
		return "outside the working directory"
	end
	for _, part in ipairs(vim.split(relp, "/", { plain = true })) do
		if part == ".git" then
			return "inside .git/"
		end
		-- project settings: hooks there run commands on the next claude run
		if part == ".claude" then
			return "configures Claude itself"
		end
	end
	if CODE_FILES[vim.fs.basename(relp)] then
		return "runs code when loaded"
	end
	return nil
end

---True when auto mode may write every path without asking.
---@param paths string[]
function M.writes_ok(paths)
	if #paths == 0 then
		return false
	end
	for _, p in ipairs(paths) do
		if M.write_blocker(p) then
			return false
		end
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Bash rules

---Command words after the program prefix.
local function words(cmd)
	return vim.split(vim.trim(cmd), "%s+")
end

local function no_output_flag(args)
	for _, a in ipairs(args) do
		if a:match("^%-%-output") then
			return false
		end
	end
	return true
end

local function no_pre(args)
	for _, a in ipairs(args) do
		if a:match("^%-%-pre") then
			return false
		end
	end
	return true
end

local BRANCH_READ = {
	["-a"] = true,
	["-r"] = true,
	["-v"] = true,
	["-vv"] = true,
	["--all"] = true,
	["--remotes"] = true,
	["--list"] = true,
	["--show-current"] = true,
	["--verbose"] = true,
}
local function branch_read(args)
	for _, a in ipairs(args) do
		if not BRANCH_READ[a] then
			return false
		end
	end
	return true
end

---Every non-flag argument is a path inside cwd (no quoting or ~ to second-guess).
local function paths_inside(args)
	for _, a in ipairs(args) do
		if a:find("[\"'~]") then
			return false
		end
		if not a:match("^%-") and not inside_cwd(a) then
			return false
		end
	end
	return true
end

-- Built-in read-only commands: prefix (whole words) and a check on the rest.
local BUILTIN = {
	{ "git status" },
	{ "git log", no_output_flag },
	{ "git diff", no_output_flag },
	{ "git show", no_output_flag },
	{ "git blame" },
	{ "git branch", branch_read },
	{ "ls" },
	{ "pwd" },
	{ "rg", no_pre },
	{ "wc", paths_inside },
	{ "cat", paths_inside },
	{ "head", paths_inside },
	{ "tail", paths_inside },
}

local function prefix_match(cmd, entry)
	return cmd == entry or vim.startswith(cmd, entry .. " ")
end

---True when `cmd` starts with one of `list` as whole words ("Git log"
---matches "Git log --oneline", not "Git logx"). Shared with the allow-lists
---in tools.lua.
---@param cmd string
---@param list string[]|nil
function M.matches_any(cmd, list)
	for _, entry in ipairs(list or {}) do
		if prefix_match(cmd, entry) then
			return true
		end
	end
	return false
end

---True when a shell command contains operators that could chain, redirect or
---substitute another command onto an allowed prefix.
---@param cmd string
function M.has_operators(cmd)
	return cmd:find("[;&|<>$`\\\n(){}]") ~= nil
end

---True when a bash command matches the auto rules: no shell operators and a
---built-in read-only command or a config.auto.allow entry.
---@param cmd string
function M.bash_ok(cmd)
	if M.has_operators(cmd) then
		return false
	end
	cmd = vim.trim(cmd)
	for _, e in ipairs(BUILTIN) do
		if prefix_match(cmd, e[1]) then
			local args = words(cmd:sub(#e[1] + 1))
			if args[1] == "" then
				table.remove(args, 1)
			end
			if not e[2] or e[2](args) then
				return true
			end
		end
	end
	return M.matches_any(cmd, cfg().allow)
end

-- ---------------------------------------------------------------------------
-- Classifier

local SYSTEM = [[You review actions an AI coding assistant wants to take in the user's editor and decide whether they may run without asking the user.
Answer ALLOW only when the action is read-only, or a routine and easily reversible development step inside the project (build, test, lint, format check, local git operations that do not discard work) and it fits what the user asked for.
Answer ASK when it could delete or overwrite data, discard uncommitted work, reach remote systems (push, publish, deploy, send messages, write through an API), change system or global configuration, install software, escalate privileges, read or expose secrets, run code downloaded from the network, or when it does not fit the user's request.
Reply with exactly one line: `ALLOW` or `ASK: <short reason>`.]]

---Parse the classifier reply.
---@param text string
---@return boolean allow, string|nil reason
function M.parse(text)
	for line in (text or ""):gmatch("[^\n]+") do
		line = vim.trim(line):gsub("^[`*]+", "")
		if line ~= "" then
			if line:match("^ALLOW") then
				return true, nil
			end
			local reason = line:match("^ASK:?%s*(.*)")
			if reason then
				reason = vim.trim(reason:gsub("[`*]+$", ""))
				return false, reason ~= "" and reason or "the classifier wants you to decide"
			end
			return false, "the classifier gave no verdict"
		end
	end
	return false, "the classifier gave no verdict"
end

---Ask the classifier about an action.
---@param action { kind: string, command: string, description: string|nil }
---@param cb fun(allow: boolean, reason: string|nil) called on the main loop
---@return vim.SystemObj|nil proc the classifier process, for killing it on cancel
function M.classify(action, cb)
	local conf = require("harner").config
	local c = current_chat()
	local lines = {
		"Kind: " .. action.kind,
		"Working directory: " .. vim.fn.getcwd(),
		"Command:",
		action.command,
	}
	if action.description and action.description ~= "" then
		vim.list_extend(lines, { "", "Assistant's description: " .. action.description })
	end
	if c and c.last_prompt then
		vim.list_extend(lines, { "", "The user's latest message:", c.last_prompt })
	end
	local argv = {
		conf.claude_cmd,
		"-p",
		"--model",
		cfg().model or "haiku",
		"--output-format",
		"text",
		"--tools",
		"",
		"--strict-mcp-config",
		"--no-session-persistence",
		"--system-prompt",
		SYSTEM,
	}
	local done = false
	local function finish(allow, reason)
		if done then
			return
		end
		done = true
		cb(allow, reason)
	end
	local timeout = (cfg().timeout or 15) * 1000
	local ok, proc = pcall(vim.system, argv, {
		stdin = table.concat(lines, "\n"),
		text = true,
		cwd = vim.fn.getcwd(),
	}, function(r)
		vim.schedule(function()
			if r.code ~= 0 then
				finish(false, "the classifier failed (exit " .. r.code .. ")")
			else
				finish(M.parse(r.stdout))
			end
		end)
	end)
	if not ok then
		vim.schedule(function()
			finish(false, "the classifier could not start")
		end)
		return
	end
	vim.defer_fn(function()
		if not done then
			pcall(proc.kill, proc, "sigterm")
			finish(false, "the classifier timed out")
		end
	end, timeout)
	return proc
end

return M
