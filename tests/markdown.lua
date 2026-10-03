-- Markdown: drawn in place, and gf on a link.
return function(T)
  local check, expect, temp_dir, write, key, reset_editor =
    T.check, T.expect, T.temp_dir, T.write, T.key, T.reset_editor

  -- The rendering hangs on the markdown parsers and on the plugin's own marks;
  -- when either goes missing the file simply shows as plain text, with no error.
  check("markdown: headings and tables are drawn in place", function()
    local dir = temp_dir()
    write(dir .. "/note.md", { "# Title", "", "| key | does |", "|---|---|", "| a | b |", "", "text" })
    vim.cmd.edit(dir .. "/note.md")
    local namespace
    local drawn = vim.wait(5000, function()
      namespace = namespace or vim.api.nvim_get_namespaces()["render-markdown.nvim"]
      return namespace ~= nil and #vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {}) > 0
    end, 100)
    local toggle = vim.fn.maparg("<leader>um", "n") ~= ""
    reset_editor()
    expect(drawn, "nothing was drawn over the markdown source")
    expect(toggle, "<leader>um is not mapped")
  end)
  -- On Windows the built-in gf takes the brackets of `[text](target)` for part
  -- of the file name, and the drawn link hides the target, so gf on a link
  -- found nothing.
  check("markdown: gf follows a link from its text, to a file and to a heading", function()
    -- lua/config/autocmds.lua is read on VeryLazy, which a headless start never
    -- reaches.
    if vim.fn.exists("#markdown_links") == 0 then
      require("config.autocmds")
    end
    local dir = temp_dir()
    write(dir .. "/docs/setup.md", { "# Setup", "", "## 必要なもの (Windows)", "text" })
    write(dir .. "/README.md", {
      "# Title",
      "",
      "一覧を返す([docs/setup.md](docs/setup.md))",
      "[ここ](docs/setup.md#必要なもの-windows) と [下](#レガシー-c-ナビ-gtags--cscope_mapsnvim)",
      "",
      "## レガシー C ナビ (gtags + cscope_maps.nvim)",
    })
    local function follow(line, needle)
      vim.cmd.edit(dir .. "/README.md")
      vim.fn.cursor(line, vim.fn.getline(line):find(needle, 1, true) + 1)
      key("gf")()
      return vim.fn.expand("%:t") .. ":" .. vim.fn.line(".")
    end
    local from_text = follow(3, "[docs/setup.md]")
    local to_heading_elsewhere = follow(4, "[ここ]")
    local to_heading_here = follow(4, "[下]")
    reset_editor()
    expect(from_text == "setup.md:1", "from the link text: " .. from_text)
    expect(to_heading_elsewhere == "setup.md:3", "file and heading: " .. to_heading_elsewhere)
    expect(to_heading_here == "README.md:6", "heading in the same file: " .. to_heading_here)
  end)
end
