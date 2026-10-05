-- The help and the README: every key told, every link alive.
return function(T)
  local check, expect, key, reset_editor = T.check, T.expect, T.key, T.reset_editor

  check("help: :h cfg opens, every key the config adds is in it, every link leads somewhere", function()
    local config = vim.fn.stdpath("config")
    local help = table.concat(vim.fn.readfile(config .. "/doc/cfg.txt"), "\n")
    local defined, twice, broken, missing = {}, {}, {}, {}
    for tag in help:gmatch("%*(cfg[%w-]*)%*") do
      if defined[tag] then
        twice[#twice + 1] = tag
      end
      defined[tag] = true
    end
    for tag in help:gmatch("|(cfg[%w-]*)|") do
      if not defined[tag] then
        broken[#broken + 1] = tag
      end
    end
    local seen = {}
    for _, file in ipairs(vim.fn.globpath(config .. "/lua", "**/*.lua", false, true)) do
      for _, line in ipairs(vim.fn.readfile(file)) do
        for key in line:gmatch('"(<leader>[^"]+)"') do
          if not seen[key] and not help:find(key, 1, true) then
            missing[#missing + 1] = key .. " (" .. vim.fs.basename(file) .. ")"
          end
          seen[key] = true
        end
      end
    end
    -- Every section is in the index at the top, which a link leads from to it:
    -- a section left out of it could only be found by paging.
    local index = help:match("\n目次\n(.-)\n\n") or ""
    local unlisted = {}
    for tag in pairs(defined) do
      if tag ~= "cfg" and not index:find("|" .. tag .. "|", 1, true) then
        unlisted[#unlisted + 1] = tag
      end
    end
    table.sort(unlisted)
    vim.cmd("help cfg")
    local opened = vim.fn.expand("%:t")
    vim.cmd("close")
    expect(opened == "cfg.txt", ":h cfg opened " .. opened)
    expect(#twice == 0, "tags defined twice: " .. table.concat(twice, ", "))
    expect(#broken == 0, "links to no tag: " .. table.concat(broken, ", "))
    expect(#missing == 0, "keys the help does not mention: " .. table.concat(missing, ", "))
    expect(#unlisted == 0, "sections not in the index: " .. table.concat(unlisted, ", "))
  end)
  -- <C-]> on a link of the help follows it, as Vim's own key does there: the
  -- key of this config, which looks a name up in GTAGS or tags, took the
  -- link for a name and went to the top of the page. <C-t> comes back.
  check("help: <C-]> follows a link of the cheat sheet, and <C-t> comes back", function()
    vim.cmd("help cfg-features")
    vim.fn.search("|cfg-trace|")
    vim.cmd("normal! l")
    local from = vim.fn.line(".")
    key("<C-]>")()
    local landed = vim.fn.getline(".")
    vim.cmd("pop")
    local back = vim.fn.line(".")
    reset_editor()
    expect(landed:find("*cfg-trace*", 1, true), "landed on: " .. landed)
    expect(back == from, ("<C-t> came back to line %d, not %d"):format(back, from))
  end)
  check("README: every link to a heading or a file leads somewhere", function()
    local config = vim.fn.stdpath("config")
    vim.cmd.edit(config .. "/README.md")
    local broken = {}
    for number, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      -- An example of the syntax inside a code span is not a link.
      for target in line:gsub("`[^`]*`", ""):gmatch("%]%(([^)%s]+)%)") do
        if not target:match("^%a[%w+.-]*:") then
          vim.cmd.edit(config .. "/README.md")
          vim.fn.cursor(number, line:find("](" .. target, 1, true))
          local before = vim.fn.expand("%:p") .. ":" .. vim.fn.line(".")
          key("gf")()
          if vim.fn.expand("%:p") .. ":" .. vim.fn.line(".") == before then
            broken[#broken + 1] = number .. ": " .. target
          end
        end
      end
    end
    reset_editor()
    expect(#broken == 0, "leads nowhere: " .. table.concat(broken, ", "))
  end)
end
