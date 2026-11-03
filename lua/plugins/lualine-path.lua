-- The path of the file in the statusline, whole, relative to the working
-- directory or the project as LazyVim's is, with its colours. Only a path
-- wider than the room the statusline leaves is cut, and from the front, so
-- the folders that tell the module stay (lua/taka/lib/fit_path.lua).

-- The columns the rest of the statusline takes: the mode and the project on
-- the left, the encoding, the debug lines, the line and the time on the
-- right. Measured with all of them shown: with 50, a screen 80 or 90 columns
-- wide had the whole line pushed past its edge, and lualine cut it from the
-- left, the mode and all.
local ROOM = 60

local function path(self)
  local full = vim.fn.expand("%:p")
  if full == "" then
    return ""
  end
  full = LazyVim.norm(full)
  local shown = full
  local function under(dir)
    local a, b = full, LazyVim.norm(dir)
    if LazyVim.is_win() then
      a, b = a:lower(), b:lower()
    end
    return a:find(b .. "/", 1, true) == 1
  end
  local cwd, root = LazyVim.root.cwd(), LazyVim.root.get({ normalize = true })
  if under(cwd) then
    shown = full:sub(#LazyVim.norm(cwd) + 2)
  elseif under(root) then
    shown = full:sub(#LazyVim.norm(root) + 2)
  end
  local sep = package.config:sub(1, 1)
  local parts = require("taka.lib.fit_path").fit((shown:gsub("/", sep)), math.max(vim.o.columns - ROOM, 12))
  local format = LazyVim.lualine.format
  -- The name in the colour of a change not written, as LazyVim's.
  local name = format(self, parts[#parts], vim.bo.modified and "MatchParen" or "Bold")
  local dir = #parts > 1 and format(self, table.concat({ unpack(parts, 1, #parts - 1) }, sep) .. sep, "") or ""
  local readonly = vim.bo.readonly and format(self, " 󰌾 ", "MatchParen") or ""
  return dir .. name .. readonly
end

return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    -- LazyVim's path is the one after the file type's icon.
    local section = opts.sections.lualine_c
    for index, component in ipairs(section) do
      if component[1] == "filetype" and section[index + 1] then
        section[index + 1] = { path }
        break
      end
    end
  end,
}
