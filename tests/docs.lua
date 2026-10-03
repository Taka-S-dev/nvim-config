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
    vim.cmd("help cfg")
    local opened = vim.fn.expand("%:t")
    vim.cmd("close")
    expect(opened == "cfg.txt", ":h cfg opened " .. opened)
    expect(#twice == 0, "tags defined twice: " .. table.concat(twice, ", "))
    expect(#broken == 0, "links to no tag: " .. table.concat(broken, ", "))
    expect(#missing == 0, "keys the help does not mention: " .. table.concat(missing, ", "))
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
