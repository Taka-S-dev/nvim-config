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
            transform = function(_, filter)
              filter.pattern = as_listed(filter.pattern)
            end,
          },
        },
      },
    },
  },
}
