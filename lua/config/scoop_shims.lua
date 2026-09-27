-- scoop's tools started from the folder they are really in, so that they run
-- in a session opened over ssh.
--
-- scoop reaches each tool through `apps\<tool>\current`, a junction to the
-- folder of the installed version, both from the shim it puts on the PATH and
-- from the path the shim holds. In a session opened by Windows OpenSSH a path
-- through that junction cannot be followed ("the path cannot be traversed
-- because it contains an untrusted mount point", error 448), where the same
-- path works at the desktop. So over ssh every tool reached through scoop
-- failed to start: global found nothing, and the lookups fell back to ctags
-- without a word.
--
-- For the tools this config starts, the folder each shim points to is taken
-- with its junctions replaced by where they lead, read rather than passed
-- through, and put at the front of Neovim's own PATH. Whatever runs the tools
-- from Neovim, plugins included, then starts them without crossing a junction.
-- The PATH of the shell Neovim was started from is untouched.
if vim.fn.has("win32") == 0 then
  return
end

local root = vim.env.SCOOP or vim.fs.joinpath(vim.env.USERPROFILE or "", "scoop")
local shims = vim.fs.joinpath(root, "shims")
local tools = { "global", "gtags", "gtags-cscope", "ctags", "readtags", "rg" }

-- The path with each junction or link in it replaced by where it leads. The
-- link is read, never passed through; reading it works over ssh too.
local function without_links(path)
  local parts = vim.split((path:gsub("/", "\\")), "\\", { plain = true })
  local out = parts[1]
  for index = 2, #parts do
    out = out .. "\\" .. parts[index]
    local stat = vim.uv.fs_lstat(out)
    local target = stat and stat.type == "link" and vim.uv.fs_readlink(out)
    if target then
      target = target:gsub("^\\\\%?\\", "")
      -- A link may lead somewhere relative to the folder it is in.
      out = target:match("^%a:") and target or (vim.fn.fnamemodify(out, ":h") .. "\\" .. target)
    end
  end
  return out
end

local folders, seen = {}, {}
for _, tool in ipairs(tools) do
  -- A shim file reads `path = "C:\...\tool.exe"`.
  local ok, lines = pcall(vim.fn.readfile, vim.fs.joinpath(shims, tool .. ".shim"))
  local target = ok and vim.trim(lines[1] or ""):match('^path%s*=%s*"?([^"]+)"?$')
  if target then
    target = without_links(target)
    if vim.fn.executable(target) == 1 then
      local folder = vim.fn.fnamemodify(target, ":h")
      if not seen[folder] then
        seen[folder] = true
        folders[#folders + 1] = folder
      end
    end
  end
end

if #folders > 0 then
  vim.env.PATH = table.concat(folders, ";") .. ";" .. vim.env.PATH
end
