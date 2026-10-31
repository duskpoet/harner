# harner

Neovim plugin (Lua, requires nvim 0.10+, developed on 0.12) that chats with
`claude -p` from a vertical split. Claude gets an MCP server that reads the
editor and displays content back in it. Lives in the user's config at
`~/.config/nvim/lua/harner/`, wired from `~/.config/nvim/init.lua` with a bare
`require("harner").setup()`; `setup()` registers the global keymaps itself.

One chat session per nvim instance, reachable from any window:

| key          | action                                                     |
| ------------ | ---------------------------------------------------------- |
| `<leader>hh` | input popup for the current chat (`prompt.lua`); in visual mode it attaches a *reference* to the selection |
| `<leader>ht` | toggle the chat split                                      |
| `<leader>hn` | new chat (fresh Claude session)                            |
| `<leader>hx` | cancel the running request                                 |

Keys live in `config.keys` (any entry `false` disables it; `keys.group`
registers a which-key group). `:HarnerAsk [text]` sends text directly or opens
the popup when called bare; with a range (`:'<,'>HarnerAsk`) it attaches the
range as a reference.

Selection handling is by reference, not by pasting: the popup title shows
`mcp.lua:12-20` and the prompt gets a trailing line
`Selection: <path> lines N-M (read it with get_selection)`. The system note in
`mcp.lua` tells Claude that line is a pointer, and `get_selection` reads the
`'<`/`'>` marks of the target window, so the two must stay consistent (the
visual mapping leaves visual mode first so the marks are set).

Not a git repo. The interactive Claude Code integration is a separate plugin
(`coder/claudecode.nvim`); harner is only the headless `-p` path.

## Architecture

```
chat.lua ──send──▶ runner.lua ──vim.system──▶ claude -p --output-format stream-json
   ▲                                              │ --mcp-config <tmp.json> --strict-mcp-config
   │ text deltas / tool notes                     ▼
   │                                      nvim -l bridge.lua   (MCP stdio server)
   │                                              │ vim.rpcrequest(chan, "nvim_exec_lua", ...)
   └──────── tools.lua (runs in the user's nvim) ◀┘
```

- `init.lua` — `M.config` defaults, `setup()` (commands `:Harner`, `:HarnerNew`,
  `:HarnerCancel`, `:HarnerAsk`, the `config.keys` keymaps, which-key group).
- `chat.lua` — chat buffer/window. Everything below the last separator line
  (`string.rep("─", 40)`) is pending input. One Claude session per buffer:
  first send uses `--session-id <uuid>`, later sends `--resume <uuid>`.
  `M.current` is the active chat; `ensure()` creates it lazily, `ask(prompt,
  origin_win)` writes the prompt below the separator, opens the split
  unfocused (`config.prompt.open_chat`) and calls `send()`. `send()` returns
  false when nothing was sent (empty input or a run in flight).
  `target_win()` picks the non-chat, non-floating window display tools act on;
  it prefers `chat.origin_win`, which `ask`/`send` record explicitly. Only
  windows whose buffer has an empty `buftype` qualify, so NERDTree, terminals,
  quickfix, help and show_text windows are never split or replaced (asking
  from the NERDTree window targets the file window next to it).
- `prompt.lua` — floating input popup (`<leader>hh`). Markdown scratch buffer,
  grows with `nvim_win_text_height` up to `config.prompt.max_height`. `<CR>`
  sends via `chat.ask` and returns focus to the window it was opened from,
  `<S-CR>`/`<C-CR>` insert a newline, `<Esc>`/`q`/`<C-c>` close keeping the
  text as a draft for the next open, leaving the float (WinLeave) closes it.
  While a run is in flight `<CR>` warns and keeps the popup open.
  `selection_ref()` / `ref_line(ref)` build the selection reference;
  `open({ ref = ... })` attaches one (shown in the title, appended on send,
  dropped on close, not part of the kept draft).
- `runner.lua` — builds argv, feeds the prompt on stdin, parses NDJSON. Text
  comes from `stream_event.content_block_delta` (`text_delta`), tool calls from
  `content_block_start` with a `tool_use` block (`on_tool(name)`); the call's
  input streams as `input_json_delta` fragments per block index and is decoded
  at `content_block_stop` (`on_tool_input(name, input)`). The `assistant`
  message event is only used as a fallback when no stream events arrived
  (`got_stream`). The final line has `duration_api_ms` / `total_cost_usd`.
  A missing `claude_cmd` is reported through `on_error`/`on_done` (scheduled,
  so the caller has stored the run first) without spawning anything.
- `mcp.lua` — writes the temp MCP config (server name `nvim`, command
  `vim.v.progpath -l bridge.lua`, env `HARNER_NVIM=vim.v.servername`) and the
  `--append-system-prompt` note describing the tools.
- `bridge.lua` — standalone MCP server run with `nvim -l`. Blocking
  `io.lines()` loop over stdin, synchronous rpcrequest into the parent for
  `tools/list` and `tools/call`. Has no access to the plugin's Lua state.
  When `tools.call` answers `{ pending = id }` the bridge polls
  `tools.poll(id)` every 100 ms (`vim.uv.sleep`) until a result table comes
  back, giving up after 10 min (`cancel_pending` + `isError`).
- `tools.lua` — `M.tools[name] = {description, inputSchema, handler, async?}`.
  `list()` and `call(name, args)` are what the bridge invokes. Sync handlers
  return a string; errors become `isError = true` results. Async handlers
  (`async = true`) get `handler(args, resolve)` and run `vim.ui.select` /
  `vim.ui.input`; `call` returns `{ pending = id }`, `resolve(text, is_error)`
  stores the result for `poll(id)`. `cancel_pending(reason, [id])` resolves
  waiting calls with an error (chat cancel and run end both call it).
  Every finished nvim tool calls `chat.on_tool_done(name)`.

Tools today: `show_text`, `open_file` (display); `get_current_buffer`,
`get_cursor`, `get_selection`, `list_buffers`, `get_diagnostics` (read
context); `ask_user`, `run_command` (async, wait on the user).

`open_file` resolves relative paths against `getcwd()`, opens in `target_win()`
(`split` first if that buffer is modified), centres the line and highlights the
range with a `Visual` extmark in the `harner_open_file` namespace that clears
once the cursor leaves the range. `run_command` runs an Ex command with
`nvim_exec2` in `target_win()`; unless it starts with an entry of
`config.run_command.allow` (whole-word prefix match, e.g. `Git log`) the user
confirms through `vim.ui.select({"run","skip"})`. `config.run_command.confirm
= false` skips the prompt for everything.

Tool notes in the transcript are `_→ nvim:show_text_` on `content_block_start`
and get amended to `_→ nvim:show_text · <summary>_` when the input arrives
(`chat.tool_line` remembers the line; `tool_summary()` picks title / path:line /
question / `:cmd` / file_path / url). Text that follows a note starts a new
paragraph.

## Permissions model

Headless Claude silently denies anything not pre-approved. We pass
`--tools Read,Grep,Glob,WebFetch` (restricts the built-in set, so no Edit /
Write / Bash exist at all) and `--allowedTools Read,Grep,Glob,WebFetch,mcp__nvim`
(`mcp__nvim` approves every tool of the server named `nvim`). The server name in
`mcp.lua` and the allow-list entry must stay in sync.

## Conventions and gotchas

- Tabs for indentation, same as the sibling modules in `lua/`.
- Never `print()` in `bridge.lua`: stdout is the MCP channel. Log to stderr.
- `vim.json.encode({})` yields `[]`. Use `vim.empty_dict()` for empty JSON
  objects (MCP `capabilities.tools`, empty `properties`).
- `vim.system` stdout/exit callbacks run outside the main loop; wrap API
  calls in `vim.schedule` (runner already does).
- `nvim_exec_lua` from the bridge blocks the bridge until the handler returns,
  but not the parent's main loop. Anything that waits on the user must be an
  async tool (`async = true`, `{ pending = id }` + `poll`), never a blocking
  wait inside a handler.
- `nvim_win_call` passes through a single return value: wrap `pcall(...)`
  results in a table (see `exec_command` in `tools.lua`).
- `nvim_exec_lua` returning `nil` arrives in the bridge as `vim.NIL`; the poll
  loop checks both.
- The chat buffer has `filetype=markdown` for highlighting; keymaps are
  buffer-local (`<CR>` n / `<C-s>` i send, `<C-c>` cancel). `q` closes
  show_text windows.
- `startinsert!` is deferred until the main loop runs, so under `nvim -l`
  tests the mode stays normal; `feedkeys(..., "x")` also ends insert mode.
  Drive popup tests through normal-mode keys and `nvim_buf_set_lines`.
- `vim.o.exrc` is on in the user's config, so a `.nvim.lua` in this directory
  would be sourced when nvim starts here. Do not add one.
- The user's `vim.ui.select` is telescope-ui-select (ask_user choices and the
  run_command confirm open a Telescope picker); `vim.ui.input` is the default
  `input()` cmdline prompt, which blocks the calling `nvim_exec_lua` until
  the user answers (functionally fine, the bridge just waits).
- To exercise flows with the main loop running (plugins, Telescope, NERDTree),
  start `nvim --headless --listen <sock> --cmd "set columns=155 lines=45"`
  with the real config and drive it from `nvim -l` over `sockconnect` with
  `nvim_input` / `nvim_exec_lua`. `nvim_input` does not expand `<leader>`:
  substitute `vim.g.mapleader` (`<Space>`) yourself. Stub the runner inside
  the instance (`package.loaded["harner.runner"]`) to replay `on_text` /
  `on_tool` without spending money.

## Testing

Headless, run from this directory; every offline test ends with `ALL OK`.
`vim.ui.select`/`vim.ui.input` are stubbed wherever an async tool is exercised
(headless nvim has no UI for them):

```sh
# bridge round trip: initialize, tools/list, show_text, open_file, ask_user,
# run_command (confirmed / declined / allow-listed / bad), cancel path (fast, offline)
nvim --headless -u NONE -l tests/bridge_test.lua

# popup + <leader>h keymaps, offline; the only test that stubs the runner
nvim --headless -u NONE -l tests/prompt_test.lua

# runner + chat against a fake `claude` shell script replaying stream events:
# tool note summaries, cost in the winbar, missing-binary error (offline)
nvim --headless -u NONE -l tests/runner_test.lua

# full loop against the real claude CLI: three messages, later ones resume (~2 min, costs money)
nvim --headless -u NONE -l tests/chat_test.lua

# confirm the user's real config registers the commands
nvim --headless -c 'lua print(vim.fn.exists(":HarnerAsk"), vim.fn.maparg("<leader>hh", "n") ~= "")' -c 'qa!'
```

Expected from chat_test: one `_→ nvim:show_text · Hello_` note (not two), a
`harner://show/N Hello` window with `ft=lua`, the second answer naming
`mcp.lua` line 12, and the third turn showing `ask_user · Which colour?`,
an `open_file · mcp.lua:N` note and the reply `green`. Probe raw CLI events
with:

```sh
claude -p "Reply with exactly: hello" --output-format stream-json --verbose --include-partial-messages --strict-mcp-config --tools ""
```
