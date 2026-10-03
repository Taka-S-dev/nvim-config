-- Pin the scope line: keep the line of the block under the cursor drawn
-- while the cursor goes elsewhere.
--
-- The scope line follows the cursor, and the cursor follows the wheel, so
-- in a long block the line moves to whatever block the view lands in.
-- <leader>jl draws the block the cursor is in, in its own colour (ScopePin), and
-- leaves it there through scrolling and jumps; pressed again it takes the
-- line away. The block is found the way the scope line finds it, so the two
-- agree, and the drawn line moves with the text when lines are added above.
-- One pinned block per buffer.
local M = {}

local namespace = vim.api.nvim_create_namespace("config_scope_pin")
vim.api.nvim_set_hl(0, "ScopePin", { default = true, link = "DiagnosticInfo" })

local function clear(buf)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.b[buf].scope_pin = nil
end

local function draw(buf, scope)
  local guide = Snacks.config.get("indent", {}).scope
  local char = guide and guide.char or "│"
  for line = scope.from, scope.to do
    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    if text == "" or vim.fn.indent(line) > scope.indent then
      vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
        virt_text = { { char, "ScopePin" } },
        virt_text_win_col = scope.indent,
        hl_mode = "combine",
        priority = 250,
      })
    end
  end
  vim.b[buf].scope_pin = { from = scope.from, to = scope.to, indent = scope.indent }
end

function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  if vim.b[buf].scope_pin then
    clear(buf)
    return
  end
  Snacks.scope.get(function(scope)
    if not scope or scope.to <= scope.from then
      vim.notify("No block to pin here", vim.log.levels.WARN)
      return
    end
    draw(buf, scope)
  end, { buf = buf })
end

return M
