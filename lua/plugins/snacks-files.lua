-- A path pasted into the list of files (<leader>ff) is found as it is written
-- on Windows. The list names files as `ssl/ssl.h`, and a path with back slashes,
-- `ssl\ssl.h:12`, or starting at a slash or a drive, as tools on Windows write
-- them, matched nothing. What is typed is left as it is; what it is matched
-- against is the path with forward slashes, from the cwd where it is under it.
local function as_listed(pattern)
  local path = pattern:gsub("\\", "/")
  local cwd = vim.fs.normalize(vim.fn.getcwd()):gsub("\\", "/")
  if path:lower():sub(1, #cwd + 1) == cwd:lower() .. "/" then
    path = path:sub(#cwd + 2)
  end
  return (path:gsub("^/+", ""))
end

return {
  "folke/snacks.nvim",
  opts = {
    picker = {
      sources = {
        files = {
          filter = {
            transform = function(picker, filter)
              filter.pattern = as_listed(filter.pattern)
              -- The preview follows a line typed after the file, as in
              -- `ssl_lib.c:45`, when only the line changes: snacks shows an
              -- item again only when its position is another table, and it
              -- changes the line inside the same one, so the preview stayed
              -- on the first line typed. Once the match is done, a line not
              -- yet shown is shown.
              local tries = 0
              local function settle()
                tries = tries + 1
                if picker.closed or tries > 100 then
                  return
                end
                if picker:is_active() then
                  return vim.defer_fn(settle, 20)
                end
                local item = picker:current()
                local line = item and item.pos and item.pos[1]
                if line and line ~= picker.config_shown_line and picker.preview then
                  picker.config_shown_line = line
                  picker.preview:show(picker, { force = true })
                end
              end
              vim.defer_fn(settle, 20)
            end,
          },
        },
      },
    },
  },
}
