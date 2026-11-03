-- A path made to fit a width, for the statusline
-- (lua/plugins/lualine-path.lua): whole when it fits, else with folders taken
-- off the front. The folders next to the file are the ones that tell which
-- module it is in, which LazyVim's own path, cut in the middle
-- (`ssl/…/extensions/x.c`), lost; the file name is never cut.
local M = {}

-- The parts of `path` (split at / and \) that fit in `width` display columns,
-- `…` standing for the folders taken off; the separator is not counted twice.
function M.fit(path, width)
  local parts = vim.split(path, "[\\/]")
  local sep = path:match("[\\/]") or "/"
  local function wide(list)
    return vim.fn.strdisplaywidth(table.concat(list, sep))
  end
  if wide(parts) <= width or #parts == 1 then
    return parts
  end
  -- The front taken off, one folder at a time, until what is left with `…`
  -- before it fits, or only the file is left.
  for first = 2, #parts do
    local left = { "…", unpack(parts, first) }
    if wide(left) <= width or first == #parts then
      return left
    end
  end
  return parts
end

return M
