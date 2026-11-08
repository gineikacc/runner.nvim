-- Persistent state for nvim-runner.
--
-- Commands are stored per working directory in Neovim's state directory, so
-- nothing is written into your projects.  The file is intentionally tiny and
-- human-readable:
--
--   {
--     "version": 1,
--     "focus": true,
--     "commands": { "/home/me/project": "make -j" },
--     "history":  { "/home/me/project": ["make -j", "gcc main.c"] }
--   }

local M = {}

local state_dir = vim.fn.stdpath("state") .. "/nvim-runner"
local state_file = state_dir .. "/state.json"

local data = {
	version = 1,
	focus = nil,
	commands = {},
	history = {},
}

local function key(cwd)
	return vim.fs.normalize(cwd or vim.fn.getcwd())
end

local function ensure_tables()
	if type(data.commands) ~= "table" then
		data.commands = {}
	end
	if type(data.history) ~= "table" then
		data.history = {}
	end
end

function M.load()
	local ok, lines = pcall(vim.fn.readfile, state_file)
	if not ok or type(lines) ~= "table" or #lines == 0 then
		return
	end

	local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not decoded_ok or type(decoded) ~= "table" then
		return
	end

	data = vim.tbl_deep_extend("force", data, decoded)
	ensure_tables()
end

function M.save()
	local ok = pcall(vim.fn.mkdir, state_dir, "p")
	if not ok then
		return
	end

	local encoded_ok, encoded = pcall(vim.json.encode, data)
	if not encoded_ok then
		return
	end

	local tmp = state_file .. ".tmp"
	if not pcall(vim.fn.writefile, { encoded }, tmp) then
		return
	end
	pcall(vim.uv.fs_rename, tmp, state_file)
end

function M.path()
	return state_file
end

function M.command(cwd)
	ensure_tables()
	return data.commands[key(cwd)]
end

function M.set_command(cwd, cmd)
	ensure_tables()
	local k = key(cwd)
	if cmd == nil or vim.trim(cmd) == "" then
		data.commands[k] = nil
	else
		data.commands[k] = vim.trim(cmd)
	end
	M.save()
end

function M.history(cwd)
	ensure_tables()
	local list = data.history[key(cwd)]
	if type(list) ~= "table" then
		return {}
	end
	return vim.deepcopy(list)
end

function M.push_history(cwd, cmd)
	ensure_tables()
	cmd = vim.trim(cmd or "")
	if cmd == "" then
		return
	end

	local k = key(cwd)
	local list = type(data.history[k]) == "table" and data.history[k] or {}

	-- Move an existing command to the front instead of duplicating it.
	for i = #list, 1, -1 do
		if list[i] == cmd then
			table.remove(list, i)
		end
	end
	table.insert(list, 1, cmd)

	while #list > 100 do
		table.remove(list)
	end
	data.history[k] = list
	M.save()
end

function M.focus(default)
	if type(data.focus) == "boolean" then
		return data.focus
	end
	return default
end

function M.set_focus(value)
	data.focus = not not value
	M.save()
end

-- Useful for tests.
function M.reset()
	data = {
		version = 1,
		focus = nil,
		commands = {},
		history = {},
	}
end

return M
