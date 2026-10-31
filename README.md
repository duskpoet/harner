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
  cmd = { "Harner", "HarnerAsk", "HarnerNew", "HarnerCancel" },
  keys = { "<leader>hh", { "<leader>hh", mode = "x" }, "<leader>ht", "<leader>hn", "<leader>hx" },
  opts = {},
}
```

## Usage

| key / command            | action                                                             |
| ------------------------ | ------------------------------------------------------------------ |
| `<leader>hh`             | input popup for the current chat; in visual mode it attaches a reference to the selection |
| `<leader>ht` / `:Harner` | toggle the chat split                                              |
| `<leader>hn` / `:HarnerNew` | new chat (fresh Claude session)                                 |
| `<leader>hx` / `:HarnerCancel` | cancel the running request                                   |
| `:HarnerAsk [text]`      | send text directly, or open the popup when called bare; `:'<,'>HarnerAsk` attaches the range |

In the popup `<CR>` sends, `<S-CR>` or `<C-CR>` inserts a newline, `<Esc>`
closes and keeps the text as a draft. In the chat split everything below the
last `────` line is your next message: `<CR>` in normal mode or `<C-s>` in
insert mode sends it, `<C-c>` cancels a run.

A selection is passed by reference, not pasted: the prompt ends with a
`Selection: <path> lines N-M` line and Claude reads the lines itself with
`get_selection`.

### What Claude can do in the editor

- read: `get_current_buffer`, `get_cursor`, `get_selection`, `list_buffers`,
  `get_diagnostics`
- display: `show_text` (scratch window with a filetype, `q` closes it),
  `open_file` (jump to a file and highlight a line range)
- change: `edit_file` (str_replace-style edit applied to the buffer, unsaved
  and undoable), `write_file` and `save_file` (disk writes, confirmed by you)
- interact: `ask_user` (question with optional choices), `run_command` (an Ex
  command, confirmed unless it starts with an entry of `run_command.allow`)

Headless Claude silently denies anything not pre-approved. harner restricts
the built-in tools to `Read`, `Grep`, `Glob` and `WebFetch` and approves the
`nvim` MCP server, so there is no shell and no direct file write; all changes
go through the tools above.

## Configuration

Defaults:

```lua
require("harner").setup({
  claude_cmd = "claude",
  model = nil,            -- passed as --model when set
  width = 0.4,            -- chat split: fraction of columns, or columns if >= 1
  builtin_tools = { "Read", "Grep", "Glob", "WebFetch" },
  allowed_tools = { "mcp__nvim" },
  extra_args = {},        -- appended to the claude argv
  show_text = {
    mode = "split",       -- "split" | "vsplit" | "float"
    float_width = 100,
  },
  run_command = {
    confirm = true,       -- ask before each command not covered by `allow`
    allow = { "edit", "Telescope", "DiffviewOpen", "Git blame", "Git log", "Git diff" },
  },
  write_file = {
    confirm = true,       -- ask before write_file / save_file touch the disk
  },
  keys = {                -- set an entry to false to skip it
    group = "<leader>h",  -- which-key group label
    ask = "<leader>hh",
    toggle = "<leader>ht",
    new = "<leader>hn",
    cancel = "<leader>hx",
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
owns the chat, where `tools.lua` runs it. Tools that wait on you (`ask_user`,
`run_command`, `write_file`, `save_file`) answer asynchronously so the editor
stays responsive.

## Development

Offline tests, run from the repo root; each ends with `ALL OK`:

```sh
nvim --headless -u NONE -l tests/bridge_test.lua   # MCP round trip, every tool
nvim --headless -u NONE -l tests/prompt_test.lua   # popup and keymaps
nvim --headless -u NONE -l tests/runner_test.lua   # stream parsing against a fake claude
nvim --headless -u NONE -l tests/chat_test.lua     # real CLI, costs money
```

Design notes and gotchas are in `CLAUDE.md`.
