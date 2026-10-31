local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local root, check = t.root, t.check
-- bash tool: opt-in listing, allow-list vs shell operators, confirm / decline /
-- per-chat grant, output format (stderr, exit code, truncation), timeout and
-- cancel killing the process group, system note. Offline; calls tools.call /
-- poll directly (the bridge round trip is covered by bridge_test).
local harner = require("harner")
harner.setup({})
local tools = require("harner.tools")
local mcp = require("harner.mcp")
vim.cmd("cd " .. vim.fn.fnameescape(root))

local prompts, answer = {}, "yes"
require("harner.confirm").ask = function(opts, cb)
  prompts[#prompts + 1] = table.concat(opts.body, "\n")
  vim.defer_fn(function() cb(answer) end, 20)
  return function(choice) cb(choice) end
end

local function names()
  return vim.tbl_map(function(x) return x.name end, tools.list())
end

---Call a tool and wait for its result; returns text, is_error.
local function call(args, wait_ms)
  local r = tools.call("bash", args)
  if r.pending then
    local id, res = r.pending, nil
    vim.wait(wait_ms or 5000, function()
      res = tools.poll(id)
      return res ~= nil
    end, 10)
    r = res or { content = { { text = "<no result>" } }, isError = true }
  end
  return r.content[1].text, r.isError
end

-- disabled by default: not listed, not callable, note says to flag it up front
check(not vim.tbl_contains(names(), "bash"), "bash not listed by default")
local txt, err = call({ command = "echo hi" })
check(err and txt:find("disabled", 1, true), "disabled bash refuses: " .. txt)
check(mcp.system_note("/x"):find("say so up front", 1, true), "note warns about missing shell")

harner.config.bash.enabled = true
harner.config.bash.allow = { "echo", "git status" }
check(vim.tbl_contains(names(), "bash"), "bash listed when enabled")
check(mcp.system_note("/x"):find("mcp__nvim__bash", 1, true), "note describes bash when enabled")

-- allow-listed: runs without asking, in the cwd
txt, err = call({ command = "echo hello" })
check(txt == "hello" and not err, "allow-listed echo: " .. txt)
check(#prompts == 0, "allow-listed command did not ask")

-- operators defeat the allow-list
txt, err = call({ command = "echo a; pwd", description = "two things" })
check(#prompts == 1 and prompts[1]:find("^# two things\necho a; pwd"), "chained command asked: " .. (prompts[1] or ""))
check(txt == "a\n" .. root and not err, "confirmed command ran in cwd: " .. txt)
txt = call({ command = "echo $HOME" })
check(#prompts == 2, "variable expansion asked")

-- stderr and exit code
answer = "yes"
txt, err = call({ command = "printf out; printf oops >&2; exit 3" })
check(err and txt == "out\n[stderr]\noops\n[exit code 3]", "stderr + exit code: " .. txt)

-- editors fail fast instead of waiting for a TTY until the timeout
txt, err = call({ command = "git var GIT_EDITOR" })
check(txt == "false" and not err, "git sees the editor as false: " .. txt)

-- decline
answer = "no"
txt, err = call({ command = "touch should-not-exist" })
check(err and txt:find("declined", 1, true), "declined: " .. txt)
check(not vim.uv.fs_stat(root .. "/should-not-exist"), "declined command did not run")

-- always: granted for exactly this command
answer = "always"
local n = #prompts
call({ command = "true && echo granted" })
answer = "no"
txt, err = call({ command = "true && echo granted" })
check(#prompts == n + 1 and txt == "granted" and not err, "grant skips the second confirm: " .. txt)
txt, err = call({ command = "true && echo other" })
check(err and #prompts == n + 2, "grant does not cover another command")
tools.reset_grants()

-- empty output, truncation
answer = "yes"
txt = call({ command = "true" })
check(txt == "(no output, exit code 0)", "no output: " .. txt)
harner.config.bash.max_output = 100
txt = call({ command = "head -c 1000 /dev/zero | tr '\\0' x" })
check(#txt < 140 and txt:find("bytes cut", 1, true) and txt:sub(1, 5) == "xxxxx", "truncated: " .. #txt)
harner.config.bash.max_output = 30000

-- The touch runs in a background subshell, a separate process in the shell's
-- group: killing only the shell would leave it to touch the marker, so these
-- prove the whole group dies.
local bg = "(sleep %d; touch %s) & wait"

-- timeout kills the whole group; the touch would come at 2 s
local marker = vim.fn.tempname()
local t0 = vim.uv.hrtime()
txt, err = call({ command = bg:format(2, marker), timeout = 1 }, 6000)
check(err and txt:find("timed out after 1 s", 1, true), "timeout: " .. txt)
check((vim.uv.hrtime() - t0) / 1e9 < 2, "timeout returned promptly")
vim.wait(1500)
check(not vim.uv.fs_stat(marker), "timeout killed the background child")

-- cancel kills a running command; the touch would come at 1 s
local cancel_marker = vim.fn.tempname()
local r = tools.call("bash", { command = bg:format(1, cancel_marker) })
check(r.pending ~= nil, "running command is pending")
vim.wait(200)
tools.cancel_pending("cancelled by the user")
local res = tools.poll(r.pending)
check(res and res.isError and res.content[1].text:find("cancelled", 1, true), "cancel resolves the call")
vim.wait(1300)
check(not vim.uv.fs_stat(cancel_marker), "cancel killed the background child")
check(tools.pending_count() == 0, "nothing left pending")

-- quitting nvim kills running commands (they are detached and would survive)
local leave_marker = vim.fn.tempname()
r = tools.call("bash", { command = bg:format(1, leave_marker) })
check(r.pending ~= nil, "command before VimLeavePre is pending")
vim.wait(200)
vim.api.nvim_exec_autocmds("VimLeavePre", {})
vim.wait(1500)
check(not vim.uv.fs_stat(leave_marker), "VimLeavePre killed the running command")
res = tools.poll(r.pending)
check(res and res.isError, "killed command resolves with an error")

-- commands ignoring SIGTERM (the ignore is inherited by the subshell and
-- sleep) get SIGKILL: without it each of these would reach its touch
local stubborn = "trap '' TERM; " .. bg
local m_timeout, m_cancel, m_exit = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()

-- timeout: TERM at 1 s, KILL 2 s later, touch would come at 4 s
t0 = vim.uv.hrtime()
txt, err = call({ command = stubborn:format(4, m_timeout), timeout = 1 }, 6000)
check(err and txt:find("timed out after 1 s", 1, true), "stubborn timeout: " .. txt)
check((vim.uv.hrtime() - t0) / 1e9 < 3.9, "stubborn timeout resolved before the touch")
vim.wait(1500)
check(not vim.uv.fs_stat(m_timeout), "stubborn command killed after timeout")

-- cancel: KILL 2 s after the cancel, touch would come at 3 s
r = tools.call("bash", { command = stubborn:format(3, m_cancel) })
vim.wait(200)
tools.cancel_pending("cancelled by the user")
tools.poll(r.pending)
vim.wait(3300)
check(not vim.uv.fs_stat(m_cancel), "stubborn command killed after cancel")

-- exit: no timers, so KILL follows within VimLeavePre itself
r = tools.call("bash", { command = stubborn:format(1, m_exit) })
vim.wait(200)
t0 = vim.uv.hrtime()
vim.api.nvim_exec_autocmds("VimLeavePre", {})
check((vim.uv.hrtime() - t0) / 1e9 < 0.5, "VimLeavePre returns quickly")
vim.wait(1500)
check(not vim.uv.fs_stat(m_exit), "stubborn command killed on VimLeavePre")
tools.poll(r.pending)

t.finish()
