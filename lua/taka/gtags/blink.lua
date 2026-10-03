-- The GTAGS completion (complete.lua) as a source of blink.cmp, the completion
-- menu LazyVim uses; set up in lua/plugins/completion.lua.
local complete = require("taka.gtags.complete")

local Source = {}

-- Where the last list of members was offered: { buf, row }. The other sources
-- keep their words out of the menu there (lua/plugins/completion.lua).
local members_at

-- Whether the cursor is where members were offered, in a member access.
function Source.offering_members(context)
  local line = context.line:sub(1, context.cursor[2])
  return members_at ~= nil
    and members_at.buf == context.bufnr
    and members_at.row == context.cursor[1] - 1
    and complete.chain(line) ~= nil
end

function Source.new()
  return setmetatable({}, { __index = Source })
end

-- A language server that completes, such as clangd, knows the types this
-- only reads from declarations, and offers members after a cast or a call
-- too. With one attached the menu is left to it; where it stops or is not
-- there, the GTAGS completion answers again.
local function server_completes(buf)
  return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/completion" }) > 0
end

function Source:enabled()
  local buf = vim.api.nvim_get_current_buf()
  return (vim.bo[buf].filetype == "c" or vim.bo[buf].filetype == "cpp") and not server_completes(buf)
end

-- `>` for `->`; complete.lua tells a `>` that is no member access apart.
function Source:get_trigger_characters()
  return { ".", ">" }
end

function Source:get_completions(context, callback)
  local Kind = require("blink.cmp.types").CompletionItemKind
  local row, col = context.cursor[1] - 1, context.cursor[2]
  complete.candidates(context.bufnr, row, col, function(result)
    if not result then
      return callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    end
    members_at = result.kind == "member" and #result.items > 0 and { buf = context.bufnr, row = row } or nil
    local first = col - #result.partial
    local items = {}
    for index, found in ipairs(result.items) do
      local item = {
        label = found.label,
        detail = found.detail,
        kind = result.kind == "member" and Kind.Field
          or (found.label:match("^[%u%d_]+$") and Kind.Constant)
          or Kind.Text,
        -- Members in the order of use, whatever blink's own order would be.
        sortText = result.kind == "member" and ("%05d"):format(index) or nil,
        textEdit = {
          newText = found.label,
          range = { start = { line = row, character = first }, ["end"] = { line = row, character = col } },
        },
      }
      if result.dot_on_pointer then
        -- `.` on a pointer: the dot before the member becomes `->`.
        local line = vim.api.nvim_buf_get_lines(context.bufnr, row, row + 1, false)[1]
        local dot = line:sub(1, first):find("%.%s*$")
        if dot then
          item.additionalTextEdits = {
            {
              newText = "->",
              range = { start = { line = row, character = dot - 1 }, ["end"] = { line = row, character = dot } },
            },
          }
        end
      end
      items[#items + 1] = item
    end
    callback({ items = items, is_incomplete_forward = not result.complete, is_incomplete_backward = false })
  end)
end

return Source
