-- Standard Neovim plugin entry point.
--
-- The plugin works immediately after installation: setup() is called with
-- defaults here.  Calling require("nvim-runner").setup(opts) afterwards (as a
-- plugin manager does when `opts` is configured) simply applies the user's
-- settings and replaces the default keymaps.

if vim.g.loaded_nvim_runner == 1 then
	return
end
vim.g.loaded_nvim_runner = 1

local ok, runner = pcall(require, "nvim-runner")
if ok and not runner.is_setup() then
	runner.setup()
end
