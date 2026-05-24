# Sourced from $PROFILE on every PowerShell startup. See README "PowerShell
# プロファイル設定" for the one-line installer.
#
# `nv` launches the "primary" nvim with a named-pipe listener so external
# tools (bin/open-in-nvim.cmd, browser editor integrations, file managers)
# can send files to it via `nvim --server \\.\pipe\nvim --remote-tab ...`.

function Start-NvimMain {
    nvim --listen \\.\pipe\nvim @args
}
Set-Alias nv Start-NvimMain -Force
