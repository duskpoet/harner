# harner

Chat with `claude -p` from a Neovim split. Claude gets an MCP server that
reads the editor (buffer, cursor, selection, diagnostics) and displays
content back in it (scratch windows, jump to file and line, buffer edits
that stay unsaved until you review them).

harner is the headless path only: every request is one `claude -p` call
that resumes the same session. For the interactive Claude Code terminal use
[coder/claudecode.nvim](https://github.com/coder/claudecode.nvim).

## Requirements

- Neovim 0.10 or newer
- the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) on
  `PATH` as `claude` (or set `claude_cmd`), logged in
- optional: [which-key.nvim](https://github.com/folke/which-key.nvim) for
  the `<leader>h` group label, a `vim.ui.select` frontend such as
  telescope-ui-select for nicer confirm prompts

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "<github-user>/harner",
  event = "VeryLazy",
  opts = {},
}
```

`opts` is passed to `require("harner").setup()`. To lazy-load on first use
instead, list the commands and keys in the spec:

```lua
{
  "<github-user>/harner",
  cmd = { "Harner", "HarnerAsk", "HarnerNew", "HarnerCancel", "HarnerAuto" },
  keys = { "<leader>hh", { "<leader>hh", mode = "x" }, "<leader>ht", "<leader>hn", "<leader>hl", "<leader>hx", "<leader>ha" },
  opts = {},
}
```

## Usage

| key / command            | action                                                             |
| ------------------------ | ------------------------------------------------------------------ |
| `<leader>hh`             | input popup for the current chat; in visual mode it attaches a reference to the selection |
| `<leader>ht` / `:Harner` | toggle the chat split                                              |
| `<leader>hn` / `:HarnerNew` | new chat (fresh Claude session; the old chat is kept)           |
| `<leader>hl` / `:HarnerChats` | pick one of this nvim's chats to show                         |
| `<leader>hx` / `:HarnerCancel` | cancel the running request (the current chat's, else the only running one) |
| `<leader>ha` / `:HarnerAuto` | toggle auto mode (fewer confirms) for the current chat         |
| `:HarnerAsk [text]`      | send text directly, or open the popup when called bare; `:'<,'>HarnerAsk` attaches the range |

In the popup `<CR>` sends, `<S-CR>` or `<C-CR>` inserts a newline, `<Esc>`
closes and keeps the text as a draft. In the chat split everything below the
last `────` line is your next message: `<CR>` in normal mode or `<C-s>` in
insert mode sends it, `<C-c>` cancels a run.

A selection is passed by reference, not pasted: the prompt ends with a
`Selection: <path> lines N-M` line and Claude reads the lines itself with
`get_selection`.

Chats live until nvim exits. Closing the split, `:bdelete` or `:bwipeout` on
a chat buffer only hides it; `<leader>hl` brings it back with the same
transcript and Claude session. Several chats can run at once; each one's
tools act on the window it was asked from.

### What Claude can do in the editor

- read: `get_current_buffer`, `get_cursor`, `get_selection`, `list_buffers`,
  `get_diagnostics`
- display: `show_text` (scratch window with a filetype, `q` closes it),
  `open_file` (jump to a file and highlight a line range)
- change: `edit_file` (str_replace-style edit applied to the buffer, unsaved
  and undoable), `write_file` and `save_file` (disk writes, unasked except outside the
  working directory, `.git/`, `.claude/` and files that run code when loaded;
  `save_file` takes several files under at most one confirm)
- interact: `ask_user` (question with optional choices), `run_command` (an Ex
  command, confirmed unless it starts with an entry of `run_command.allow`)
- shell (opt-in, `bash = { enabled = true }`): `bash` runs a command with
  `bash -c` in the working directory and returns stdout, stderr and the exit
  code. Each command is confirmed unless it starts with an entry of
  `bash.allow` and contains no shell operators (`;`, `&`, `|`, redirects,
  `$`, backticks, ...), so `git status; rm -rf ~` never slips through an
  allowed `git status`. The operator check does not limit what the allowed
  program does with its own arguments, so keep entries to specific read-only
  subcommands (`git status`, `git log`, `gh pr view`). A bare program name
  allows everything it can do (`git -c alias.x='!rm -rf ~' x` passes a
  `git` entry), as does any entry that writes through options (`git diff
  --output=FILE`) or runs project scripts (`npm`, `make`, `cargo`). No stdin
  or TTY; commands are killed (whole process
  group) on timeout, `<leader>hx` or the end of the reply. This is what
  shell-dependent skills such as a PR review need. With the tool off, Claude
  is told to say up front when a task needs a shell instead of stopping
  partway through.

Commands and the disk writes that ask are confirmed in a small float that
shows the full command or file list: `y` approves, `a` approves and stops asking for the rest
of the chat (that exact command, or all writes), `n` / `<Esc>` skips. Edited
files are shown in your working window; if it holds unsaved changes of your
own, harner splits once and reuses that window for every later file. If
Claude wants to edit a file you have unsaved changes in, it asks first: `s`
saves your changes and then edits, `d` drops them (reloads from disk), `n`
skips the edit.

### Auto mode

Auto mode is on by default (the winbar shows `AUTO`); `<leader>ha` toggles it
for the current chat, and a new chat starts at `auto.enabled`. Your allow-lists and `a` grants
still apply first. Beyond them:

- with `write_file.confirm = true`, writes (`write_file`, `save_file`) inside
  the working directory run without asking (with the default `false` they
  never ask anyway);
- writes outside the working directory or under `.git/` / `.claude/` go to
  the classifier below (it also sees the content, or the diff for
  `save_file`). Files that run code or grant permissions always ask, auto
  mode or not: `.nvim.lua`, `.nvimrc`, `.exrc`, `.lazy.lua`, `.envrc`,
  a `.git` file, `hooks/` and `config` under `.git/` (submodules and
  worktrees included),
  everything under a `.claude/` dir (project or `~`: settings, hooks and
  their scripts, plugins) except memory notes in `projects/<x>/memory/`, and
  `~/.claude.json`;
- a built-in list of read-only shell commands runs without asking (`git
  status|log|diff|show|blame`, read-only `git branch`, `ls`, `pwd`, `rg`, and
  `cat|head|tail|wc` on paths inside the working directory), plus your
  `auto.allow` entries. Chains (`&&`, `||`, `;`, `|`) pass when every part
  does; quotes are respected and `2>&1` / `2>/dev/null` are allowed, any
  other operator, redirect, `$` or backtick rules the command out;
- every other `bash` and `run_command` call goes to a classifier
  (`claude -p --model haiku`, no tools) that sees the command, Claude's
  description and your latest message. It either lets the call run or opens
  the normal confirm with its reason under the command. It never refuses on
  its own; an error or a timeout (`auto.timeout`, 15 s) asks you;
- `edit_file`'s save/drop question over your own unsaved changes always asks.

Calls that ran unasked are marked in the transcript, e.g.
`→ nvim:bash · $ git log -5 · auto (rule)` or `· auto (classifier)`.

Every decision (rule, classifier, or your answer to a confirm) is appended
to `decisions.path` (default `stdpath("state")/harner/decisions.jsonl`).
`:HarnerDecisions` summarises it by tool and command, so you can see what
still asks and add `auto.allow` entries for it.

The confirm float has its own highlight groups so it stands out from the
code behind it: `HarnerConfirmBorder`, `HarnerConfirmTitle` and
`HarnerConfirmKey` (the keys in the footer) link to `DiagnosticInfo` by
default, `HarnerConfirmFooter` to `Comment` and `HarnerConfirmNormal` (the
body) to `NormalFloat`. Override any of them with `nvim_set_hl`, e.g. give
`HarnerConfirmNormal` a distinct background if your `NormalFloat` matches
`Normal`.

Headless Claude silently denies anything not pre-approved. harner restricts
the built-in tools to `Read`, `Grep`, `Glob`, `WebFetch` and `ToolSearch` and
approves the `nvim` MCP server, so there is no built-in shell and no direct file write;
all changes go through the tools above (shell commands only through the
confirmed `bash` tool, when you enable it).

## Configuration

Defaults:

```lua
require("harner").setup({
  claude_cmd = "claude",
  model = nil,            -- passed as --model when set
  width = 0.4,            -- chat split: fraction of columns, or columns if >= 1
  builtin_tools = { "Read", "Grep", "Glob", "WebFetch", "ToolSearch" },
  allowed_tools = { "mcp__nvim" },
  extra_args = {},        -- appended to the claude argv (no --settings: harner passes its own)
  mcp_servers = {},       -- extra MCP servers, see below
  connectors = {},        -- claude.ai connectors to approve, see below
  show_text = {
    mode = "split",       -- "split" | "vsplit" | "float"
    float_width = 100,
  },
  title = {
    enabled = false,      -- mirror the chat state into the terminal title ('titlestring')
    prefix = "",          -- string or function, e.g. the ssh/dtach session the editor runs in
    format = nil,         -- function(state, chat) -> string, replaces the whole title (prefix ignored)
  },
  render = {
    enabled = true,       -- decorate the transcript: box tables, shaded code, URL / file:line links (`gf` follows)
    conceal = true,       -- 'conceallevel' 2: hide `**`, backticks, fences, link targets off the cursor line
    tables = true,        -- re-pad finished tables so columns line up
  },
  run_command = {
    confirm = true,       -- ask before each command not covered by `allow`
    allow = { "edit", "Telescope", "DiffviewOpen", "Git blame", "Git log", "Git diff" },
  },
  write_file = {
    confirm = false,      -- true: ask before every write_file / save_file (auto mode off);
                          -- outside cwd, .git/, .claude/, .nvim.lua & co. always ask
  },
  bash = {
    enabled = false,      -- opt-in shell tool
    confirm = true,       -- ask before each command not covered by `allow`
    allow = {},           -- read-only subcommands only, e.g. { "git status", "gh pr view" }
                          -- (never a bare "git" / "npm": its arguments can run anything)
    shell = "bash",       -- run as `<shell> -c <command>`
    timeout = 120,        -- seconds when Claude gives none (max 540)
    max_output = 30000,   -- bytes returned to Claude, middle cut beyond that
  },
  auto = {                -- auto mode, see above
    enabled = true,       -- default for new chats (<leader>ha toggles per chat)
    allow = {},           -- extra bash prefixes that run without asking
    model = "haiku",      -- classifier model
    timeout = 15,         -- classifier seconds before falling back to asking
  },
  decisions = {           -- decision log, :HarnerDecisions
    enabled = true,
    path = nil,           -- default stdpath("state")/harner/decisions.jsonl
  },
  keys = {                -- set an entry to false to skip it
    group = "<leader>h",  -- which-key group label
    ask = "<leader>hh",
    toggle = "<leader>ht",
    new = "<leader>hn",
    cancel = "<leader>hx",
    auto = "<leader>ha",
    list = "<leader>hl",
  },
  prompt = {
    width = 0.6,
    min_height = 1,
    max_height = 10,
    border = "rounded",
    open_chat = true,     -- open the chat split (unfocused) when sending from the popup
  },
})
```

### Extra MCP servers

Claude loads every MCP server it knows about: claude.ai connectors, servers
added with `claude mcp add`, plugin servers. harner approves only `nvim` and
the ones you list; Claude still sees the others (deferred through `ToolSearch`,
so their schemas don't fill the context), but every call to them is denied and
the system note tells it not to try. To trim what loads, disconnect servers in
claude itself. The exception is project `.mcp.json` files (in the working
directory or any parent): `claude -p` would start them without a trust
prompt, so harner denies them; if one can't be read, that chat runs with
`--strict-mcp-config` and loads none of the above. A project's
`.claude/settings.json` is still read unasked, though: its `permissions.allow`
can pre-approve any loaded server's tools (your connectors included) and its
`hooks` run commands. Only chat in repositories you trust.

Servers that only harner should use go in `mcp_servers` (Claude's
`mcpServers` format). They are merged next to harner's own `nvim` server (that
name is reserved), every tool they offer is pre-approved (`mcp__<name>`), and
the system note tells Claude they exist. claude.ai connectors go in
`connectors`, by the name `claude mcp list` shows without the `claude.ai `
prefix, e.g. `connectors = { "Grafana Cloud", "Linear" }`, which approves
`mcp__claude_ai_Grafana_Cloud__*` and `mcp__claude_ai_Linear__*`.

```lua
require("harner").setup({
  mcp_servers = {
    -- OAuth: log in once from interactive `claude` (/mcp) with a server of the
    -- same name and URL; `claude -p` reuses the stored token
    linear = { type = "http", url = "https://mcp.linear.app/mcp" },
    -- or an API key
    github = {
      type = "http",
      url = "https://api.githubcopilot.com/mcp/",
      headers = { Authorization = "Bearer " .. (os.getenv("GITHUB_TOKEN") or "") },
    },
  },
})
```

OAuth tokens are stored per server name and URL, so the name in `mcp_servers`
must match the one you logged in with (`claude mcp list` shows it). The
generated config file can contain API keys: it is written `0600` and deleted
when the run ends.

## How it works

```
chat.lua ──send──▶ runner.lua ──vim.system──▶ claude -p --output-format stream-json
   ▲                                              │ --mcp-config <tmp.json>
   │ text deltas / tool notes                     ▼
   │                                      nvim -l bridge.lua   (MCP stdio server)
   │                                              │ RPC into the running nvim
   └──────── tools.lua (runs in your nvim) ◀──────┘
```

The MCP server is `bridge.lua`, started by the CLI with the same `nvim`
binary in `-l` mode. It forwards every tool call over RPC to the nvim that
owns the chat, where `tools.lua` runs it. Tools that wait on you or a process
(`ask_user`, `run_command`, `bash`, `write_file`, `save_file`) answer
asynchronously so the editor stays responsive.

## Development

Offline tests, run from the repo root; each ends with `ALL OK`:

```sh
nvim --headless -u NONE -l tests/bridge_test.lua   # MCP round trip, every tool
nvim --headless -u NONE -l tests/prompt_test.lua   # popup and keymaps
nvim --headless -u NONE -l tests/confirm_test.lua  # confirm float, grants, window reuse
nvim --headless -u NONE -l tests/runner_test.lua   # stream parsing against a fake claude
nvim --headless -u NONE -l tests/bash_test.lua     # opt-in shell tool, allow-list, timeout, cancel
nvim --headless -u NONE -l tests/chat_test.lua     # real CLI, costs money
```

Design notes and gotchas are in `CLAUDE.md`.
