# harner follow-up plan

State at 2026-10-31: v1 plus `open_file`, `ask_user` and `run_command`, all
tested end to end (offline tests, chat_test against the real CLI, and an
interactive dogfood pass with the user's config). The async bridge path
(`{ pending = id }` + polling) is the pattern for anything that waits on the
user. Design notes live in CLAUDE.md.

## 1. Quality of life

- Reference other things the same way as the selection: `@buf` for a listed
  buffer, `@diag` for diagnostics, so the user can point without pasting.
- Popup polish: `<Up>` history of sent prompts, show the chat state
  (idle/thinking) in the popup title.
- `:HarnerSwitch` / telescope picker over `chat.chats` to revisit old chats;
  `:HarnerNew` currently just hides the old buffer.
- Persist transcripts to `stdpath("state")/harner/<session>.md` on each turn,
  and a `:HarnerResume <id>` that reopens one with `--resume`.
- Mark tool completion in the note (`✓` / `✗`); `on_tool_done` today only
  resets the winbar. Errors from a tool are not visible in the transcript at
  all, only in Claude's reply.
- Spinner or `…` in the winbar while waiting for the first token.
- Fold `## You` / `## Claude` sections (markdown folding is already available).
- Model picker (`config.model` exists, no UI).
- run_command: the `allow` list is prefix-only. A per-command "always allow"
  choice in the confirm prompt would save repeated confirms in one session.
- ask_user without choices uses the `input()` cmdline prompt (no dressing.nvim
  installed). A small float would match the popup better.

## 2. Later / maybe

- Escalation per buffer (`:HarnerNew --tools=Bash`) was discussed and rejected
  for v1; default stays read-only. If added, make it explicit in the winbar.
- Replace polling in the bridge with proper libuv stdin handling so the bridge
  can serve concurrent tool calls; only matters if Claude parallelises calls.
  While an async tool waits, other MCP requests (ping, a parallel tool call)
  queue in the bridge's stdin.
- If the claude process dies while a tool waits on the user, the bridge keeps
  polling until the 10 min timeout; `on_done` already resolves pending calls,
  which makes the bridge return and then exit on closed stdin.
