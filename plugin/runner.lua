-- Standard Neovim plugin entry point.
--
-- The plugin works immediately after installation: setup() is called with
-- defaults here.  Calling require("runner").setup(opts) afterwards (as a
-- plugin manager does when `opts` is configured) simply applies the user's
-- settings and replaces the default keymaps.

if vim.g.loaded_runner == 1 then
	return
end
vim.g.loaded_runner = 1

local ok, runner = pcall(require, "runner")
if ok and not runner.is_setup() then
	runner.setup()
end
