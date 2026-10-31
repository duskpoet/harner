-- Shared bootstrap for the tests. Load it first thing with
--   local t = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/helper.lua")
-- It derives the repo root from its own path (so the checkout can live
-- anywhere), puts it on the rtp and provides the check/finish helpers.
local M = {}

M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(M.root)

M.fails = 0

---@param cond any
---@param msg string
function M.check(cond, msg)
  if not cond then M.fails = M.fails + 1 end
  io.stderr:write((cond and "ok   " or "FAIL ") .. msg .. "\n")
end

-- Print the verdict every test ends with and quit.
function M.finish()
  io.stderr:write(M.fails == 0 and "ALL OK\n" or (M.fails .. " FAILED\n"))
  vim.cmd("qa!")
end

return M
