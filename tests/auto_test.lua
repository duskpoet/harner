local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
local root, check = t.root, t.check
-- auto mode: toggle + winbar badge + reset on a new chat, the static rules
-- (writes, bash list), the classifier (allow / ask / timeout / cancel)
-- against a fake `claude` script, transcript note marks. Offline.
local harner = require("harner")
harner.setup({})
harner.config.bash.enabled = true
local tools = require("harner.tools")
local chat = require("harner.chat")
local auto = require("harner.auto")

vim.notify = function() end -- toggle's message would garble the check output
local prompts, notes, answer = {}, {}, "no"
require("harner.confirm").ask = function(opts, cb)
  prompts[#prompts + 1] = table.concat(opts.body, "\n")
  notes[#notes + 1] = opts.note or ""
  vim.defer_fn(function() cb(answer) end, 20)
  return function(choice) cb(choice) end
end

-- fake classifier: records argv and stdin, replies with $dir/reply, sleeps if asked
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local fake = dir .. "/claude"
vim.fn.writefile({
  "#!/bin/sh",
  'printf "%s\\n" "$@" > ' .. dir .. "/argv",
  "cat > " .. dir .. "/stdin",
  "[ -f " .. dir .. "/sleep ] && sleep 3",
  "touch " .. dir .. "/finished",
  "cat " .. dir .. "/reply",
}, fake)
vim.fn.setfperm(fake, "rwxr-xr-x")
harner.config.claude_cmd = fake
local function reply(s) vim.fn.writefile({ s }, dir .. "/reply") end
local function classified() return vim.uv.fs_stat(dir .. "/stdin") ~= nil end
local function reset_classified() os.remove(dir .. "/stdin") end

local function call(name, args, wait_ms)
  local r = tools.call(name, args)
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

---Put a tool note into the transcript the way the runner would.
local function note(line)
  local c = chat.ensure()
  vim.api.nvim_buf_set_lines(c.buf, -1, -1, false, { line, "" })
end
local function has_line(line)
  local c = chat.ensure()
  return vim.tbl_contains(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), line)
end

-- toggle, badge, default
vim.cmd("cd " .. vim.fn.fnameescape(root))
local c = chat.ensure()
check(c.auto == false and not auto.enabled(), "auto off by default")
chat.toggle()
auto.toggle()
check(c.auto == true and auto.enabled(), "toggle turns it on")
local win = vim.fn.bufwinid(c.buf)
check(win ~= -1 and vim.wo[win].winbar:find("AUTO", 1, true), "winbar badge: " .. vim.wo[win].winbar)
c.last_prompt = "show me the recent history"

-- static bash rules
for _, cmd in ipairs({ "git status", "git log -5 --oneline", "git diff HEAD~1", "git branch -a", "ls -la", "rg foo lua",
  "cat lua/harner/auto.lua", "head -n 5 README.md", "pwd" }) do
  check(auto.bash_ok(cmd), "rule allows " .. cmd)
end
for _, cmd in ipairs({ "git log | head", "git diff --output=/tmp/x", "git branch -D main", "git branch new",
  "cat /etc/passwd", "cat ../x", "cat '/etc/passwd'", "cat ~/.ssh/id_rsa", "rg --pre sh x", "git push", "lsof",
  "rm -rf x" }) do
  check(not auto.bash_ok(cmd), "rule refuses " .. cmd)
end
harner.config.auto.allow = { "make test" }
check(auto.bash_ok("make test") and not auto.bash_ok("make install"), "config.auto.allow extends the list")
check(not auto.bash_ok("make test; rm x"), "operators still refused for config entries")

-- write rules (cwd = a temp project)
local proj = vim.fn.tempname()
vim.fn.mkdir(proj .. "/sub", "p")
vim.fn.mkdir(proj .. "/.git", "p")
vim.cmd("cd " .. vim.fn.fnameescape(proj))
check(auto.write_blocker(proj .. "/a.txt") == nil, "write inside cwd allowed")
check(auto.write_blocker(proj .. "/new/dir/b.txt") == nil, "write into new dirs inside cwd allowed")
check(auto.write_blocker(proj .. "/../x.txt") ~= nil, "write via .. outside refused")
check(auto.write_blocker("/tmp/elsewhere.txt") ~= nil, "write outside cwd refused")
check(auto.write_blocker(proj .. "/.git/config") ~= nil, "write into .git refused")
check(auto.write_blocker(proj .. "/sub/.nvim.lua") ~= nil, ".nvim.lua refused")
check(auto.write_blocker(proj .. "/.claude/settings.json") ~= nil, ".claude/ refused")
check(auto.write_blocker(proj .. "/.envrc") ~= nil, ".envrc refused")
vim.uv.fs_symlink("/tmp", proj .. "/link")
check(auto.write_blocker(proj .. "/link/x.txt") ~= nil, "symlink out of cwd refused")

-- write_file in auto mode: no prompt inside, marked; prompt for .nvim.lua
note("_→ nvim:write_file · a.txt_")
local txt, err = call("write_file", { path = "a.txt", content = "hi\n" })
check(not err and #prompts == 0 and vim.fn.readfile(proj .. "/a.txt")[1] == "hi", "auto write without prompt: " .. txt)
check(has_line("_→ nvim:write_file · a.txt · auto (rule)_"), "write note marked")
txt, err = call("write_file", { path = ".nvim.lua", content = "print(1)" })
check(err and #prompts == 1 and not vim.uv.fs_stat(proj .. "/.nvim.lua"), ".nvim.lua asked and declined")

-- bash rule: no prompt, no classifier, marked
vim.cmd("cd " .. vim.fn.fnameescape(root))
reset_classified()
note("_→ nvim:bash · $ git status --short_")
txt, err = call("bash", { command = "git status --short" })
check(not err and #prompts == 1 and not classified(), "rule ran git status without asking or classifying")
check(has_line("_→ nvim:bash · $ git status --short · auto (rule)_"), "bash note marked rule")

-- classifier ALLOW
reply("ALLOW")
note("_→ nvim:bash · $ echo one | tr o 0_")
txt, err = call("bash", { command = "echo one | tr o 0", description = "replace letters" })
check(txt == "0ne" and not err and #prompts == 1, "classifier allowed: " .. txt)
check(has_line("_→ nvim:bash · $ echo one | tr o 0 · auto (classifier)_"), "bash note marked classifier")
local stdin = table.concat(vim.fn.readfile(dir .. "/stdin"), "\n")
check(stdin:find("echo one | tr o 0", 1, true) and stdin:find("replace letters", 1, true)
  and stdin:find("show me the recent history", 1, true), "classifier saw command, description and prompt")
local argv = vim.fn.readfile(dir .. "/argv")
check(vim.tbl_contains(argv, "haiku") and vim.tbl_contains(argv, "--no-session-persistence"), "classifier argv")

-- classifier ASK: normal confirm with the reason
reply("ASK: pushes to a remote")
local marker = vim.fn.tempname()
txt, err = call("bash", { command = "touch " .. marker .. " && true" })
check(err and #prompts == 2 and notes[2]:find("pushes to a remote", 1, true), "ask shows reason: " .. notes[2])
check(not vim.uv.fs_stat(marker), "declined after ASK did not run")
answer = "yes"
txt, err = call("bash", { command = "touch " .. marker .. " && true" })
check(not err and vim.uv.fs_stat(marker), "approved after ASK ran")
answer = "no"

-- garbage and timeout ask
reply("maybe?")
call("bash", { command = "echo a | cat" })
check(notes[#notes]:find("no verdict", 1, true), "no verdict asks: " .. notes[#notes])
harner.config.auto.timeout = 1
vim.fn.writefile({}, dir .. "/sleep")
reply("ALLOW")
call("bash", { command = "echo b | cat" })
check(notes[#notes]:find("timed out", 1, true), "timeout asks: " .. notes[#notes])

-- cancel while classifying: the classifier dies and nothing runs afterwards
harner.config.auto.timeout = 15
local cmarker = vim.fn.tempname()
os.remove(dir .. "/finished")
local r = tools.call("bash", { command = "touch " .. cmarker .. " && true" })
check(r.pending ~= nil, "classifying call is pending")
vim.wait(300)
tools.cancel_pending("cancelled by the user")
vim.wait(3500)
os.remove(dir .. "/sleep")
check(not vim.uv.fs_stat(cmarker), "cancelled during classification did not run")
check(not vim.uv.fs_stat(dir .. "/finished"), "cancel killed the classifier")
local n = #prompts

-- run_command goes to the classifier
reply("ALLOW")
txt, err = call("run_command", { cmd = "let g:harner_auto_test = 1" })
check(not err and vim.g.harner_auto_test == 1 and #prompts == n, "run_command allowed by classifier: " .. txt)

-- auto off: confirm, no classifier
auto.toggle()
check(not vim.wo[win].winbar:find("AUTO", 1, true), "badge gone")
reset_classified()
call("bash", { command = "echo c | cat" })
check(#prompts == n + 1 and not classified(), "auto off asks without classifying")

-- a new chat starts at the default
auto.toggle()
chat.new()
check(chat.chats[chat.current].auto == false, "new chat resets auto")
harner.config.auto.enabled = true
chat.new()
check(chat.chats[chat.current].auto == true, "new chat takes config default")

t.finish()
