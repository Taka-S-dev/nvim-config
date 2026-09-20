-- gf for Markdown: follows the link the cursor is in, wherever in
-- `[text](target)` the cursor is.
--
-- The built-in gf reads the file name under the cursor. On Windows `[` and `]`
-- count as file name characters, so from the text of `[docs/setup.md](docs/setup.md)`
-- it looks for a file called "[docs/setup.md]" and fails, and with the link
-- drawn in place (lua/plugins/markdown.lua) the target between the parentheses
-- is not even on screen unless the cursor is on that line.
--
-- A target is a path relative to the file, a URL, or a heading given as
-- `#anchor`, alone or after a path. Anchors are matched the way GitHub names
-- them: lower case, punctuation dropped, spaces turned into hyphens. Outside a
-- link the key is the built-in gf.
local M = {}

local function link_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local from = 1
  while true do
    local first, last, target = line:find("%[[^%]]*%]%(([^)]*)%)", from)
    if not first then
      return nil
    end
    if col >= first and col <= last then
      -- `<path with spaces>` and `path "title"` are both allowed in a target.
      return target:match("^<(.-)>") or target:match("^(%S+)") or ""
    end
    from = last + 1
  end
end

-- Punctuation GitHub drops that Lua's %p, which only knows ASCII, leaves in.
local wide_punctuation = "[（）、。・：；／「」『』【】！？～]"

local function anchor_of(heading)
  local text = vim.fn.tolower((heading:gsub("^#+%s*", ""):gsub("%s+#+%s*$", "")))
  text = text:gsub("%p", function(char)
    return (char == "-" or char == "_") and char or ""
  end)
  -- A Vim pattern, because a Lua character class works on bytes.
  text = vim.fn.substitute(text, wide_punctuation, "", "g")
  return (text:gsub("%s", "-"))
end

local function go_to_anchor(anchor)
  anchor = vim.fn.tolower(vim.uri_decode(anchor))
  local fenced = false
  for number, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fenced = not fenced
    elseif not fenced and line:match("^#+%s") and anchor_of(line) == anchor then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { number, 0 })
      return
    end
  end
  vim.notify("No heading for #" .. anchor, vim.log.levels.WARN)
end

function M.follow()
  local target = link_under_cursor()
  if not target then
    local ok, err = pcall(vim.cmd, "normal! gf")
    if not ok then
      vim.notify((tostring(err):gsub("^.-(E%d+:)", "%1")), vim.log.levels.ERROR)
    end
    return
  end
  if target:match("^%a[%w+.-]*:") and not target:match("^%a:[/\\]") then
    vim.ui.open(target)
    return
  end
  local path, anchor = target:match("^([^#]*)#?(.*)$")
  if path ~= "" then
    local file = vim.fs.normalize(vim.fs.joinpath(vim.fn.expand("%:p:h"), vim.uri_decode(path)))
    if not vim.uv.fs_stat(file) then
      vim.notify("No such file: " .. file, vim.log.levels.WARN)
      return
    end
    vim.cmd("normal! m'")
    vim.cmd.edit(vim.fn.fnameescape(file))
  end
  if anchor ~= "" then
    go_to_anchor(anchor)
  end
end

function M.setup(buf)
  vim.keymap.set("n", "gf", M.follow, { buffer = buf, desc = "Follow link or go to file" })
end

return M
