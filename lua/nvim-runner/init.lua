-- nvim-runner: a small Tsoding-style run panel.
--
-- The public API is intentionally table-friendly so it can be scripted:
--   require("nvim-runner").run("gcc main.c")
--   require("nvim-runner").set()
--   require("nvim-runner").toggle_focus()

local parser = require("nvim-runner.parser")
local state = require("nvim-runner.state")

local uv = vim.uv or vim.loop

local M = {}

local opts
local buf
local win
local status_line

local run = {
	id = 0,
	job = nil,
	cmd = nil,
	cwd = nil,
	editor_win = nil,
	parser = nil,
	items = {},
	locations = {},
	partial = "",
	started = 0,
	running = false,
	stopped = false,
	hidden = false,
	ns = vim.api.nvim_create_namespace("nvim-runner"),
}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO)
end

local function define_highlights()
	local links = {
		RunnerPath = "Directory",
		RunnerLine = "Number",
		RunnerColumn = "Constant",
		RunnerSeparator = "Delimiter",
		RunnerError = "DiagnosticError",
		RunnerWarning = "DiagnosticWarn",
		RunnerNote = "DiagnosticHint",
		RunnerInfo = "DiagnosticInfo",
		RunnerCommand = "Title",
		RunnerOK = "DiagnosticOk",
		RunnerFail = "DiagnosticError",
		RunnerDim = "Comment",
		RunnerRunning = "DiagnosticWarn",
	}
	for name, target in pairs(links) do
		vim.api.nvim_set_hl(0, name, { link = target, default = true })
	end
end

local function resolve(path, cwd)
	if not path or path == "" then
		return path
	end

	if path:sub(1, 1) == "~" then
		path = vim.fn.expand(path)
	end

	cwd = cwd or vim.fn.getcwd()
	local candidates = {}

	if path:sub(1, 1) == "/" then
		candidates[#candidates + 1] = path
	else
		candidates[#candidates + 1] = cwd .. "/" .. path
		candidates[#candidates + 1] = path
		local editor = run.editor_win
		if editor and vim.api.nvim_win_is_valid(editor) then
			local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editor))
			if name ~= "" then
				candidates[#candidates + 1] = vim.fn.fnamemodify(name, ":h") .. "/" .. path
			end
		end
	end

	for _, candidate in ipairs(candidates) do
		if vim.fn.filereadable(candidate) == 1 then
			return vim.fs.normalize(candidate)
		end
	end
	return vim.fs.normalize(candidates[1] or path)
end

local function is_runner_buffer(b)
	return buf ~= nil and vim.api.nvim_buf_is_valid(b) and b == buf
end

local function current_context()
	local cur_win = vim.api.nvim_get_current_win()
	local cur_buf = vim.api.nvim_win_get_buf(cur_win)
	if is_runner_buffer(cur_buf) then
		return run.cwd or vim.fn.getcwd(), run.editor_win
	end
	run.editor_win = cur_win
	return vim.fn.getcwd(), cur_win
end

-- Compilers report display columns, counting a tab as the next multiple of 8.
-- Convert that to a byte offset so a location in tab-indented code still lands
-- on the right character.
local function column_to_byte(line, col)
	if not col or col <= 1 or line == "" then
		return 0
	end

	local target = col - 1
	local width = 0
	local byte = 0
	while byte < #line do
		local first = line:byte(byte + 1)
		local len = 1
		if first >= 0xF0 then
			len = 4
		elseif first >= 0xE0 then
			len = 3
		elseif first >= 0xC0 then
			len = 2
		end
		local char = line:sub(byte + 1, byte + len)
		local w = char == "\t" and (8 - (width % 8)) or vim.fn.strdisplaywidth(char)
		if width + w > target then
			break
		end
		width = width + w
		byte = byte + len
		if width == target then
			break
		end
	end
	return math.max(0, math.min(byte, #line - 1))
end

local function set_spans(b, lnum, spans)
	local line = vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1] or ""
	for _, span in ipairs(spans or {}) do
		local s, e, hl = span[1], span[2], span[3]
		if s and e and hl and s >= 1 and s <= #line + 1 then
			local start_col = math.max(s - 1, 0)
			local end_col = math.min(e, #line)
			if end_col >= start_col then
				pcall(vim.api.nvim_buf_set_extmark, b, run.ns, lnum - 1, start_col, {
					end_col = end_col,
					hl_group = hl,
					priority = 100,
				})
			end
		end
	end
end

local function is_at_bottom(w)
	if not w or not vim.api.nvim_win_is_valid(w) then
		return true
	end
	local info = vim.fn.getwininfo(w)[1]
	if not info then
		return true
	end
	return info.topline + info.height >= vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(w))
end

local function scroll_bottom(w)
	if not w or not vim.api.nvim_win_is_valid(w) then
		return
	end
	local b = vim.api.nvim_win_get_buf(w)
	local last = vim.api.nvim_buf_line_count(b)
	pcall(vim.api.nvim_win_set_cursor, w, { last, 0 })
	pcall(vim.api.nvim_win_call, w, function()
		vim.cmd("normal! zb")
	end)
end

-- Forward declaration: buffer-local maps are installed by ensure_buf().
local set_buffer_maps

local function ensure_buf()
	if buf and vim.api.nvim_buf_is_valid(buf) then
		return buf
	end

	buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, "runner://output")
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].undolevels = -1
	vim.bo[buf].filetype = "runner"
	vim.bo[buf].modifiable = true
	set_buffer_maps(buf)
	return buf
end

local function ensure_win(b)
	local current_tab = vim.api.nvim_get_current_tabpage()
	if
		win
		and vim.api.nvim_win_is_valid(win)
		and vim.api.nvim_win_get_buf(win) == b
		and vim.api.nvim_win_get_tabpage(win) == current_tab
	then
		return win
	end

	local prev = vim.api.nvim_get_current_win()
	local height = math.max(1, math.min(opts.height or 12, math.max(1, vim.o.lines - 3)))
	vim.cmd("botright " .. height .. "split")
	local w = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(w, b)

	local wo = vim.wo[w]
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
	wo.foldcolumn = "0"
	wo.wrap = false
	wo.spell = false
	wo.list = false
	wo.cursorline = false
	wo.winfixheight = true
	wo.scrolloff = 0

	win = w
	if not M._focus then
		vim.api.nvim_set_current_win(prev)
	end
	return w
end

local function append_lines(lines)
	if not lines or #lines == 0 then
		return
	end

	local b = ensure_buf()
	if not (win and vim.api.nvim_win_is_valid(win)) and not run.hidden then
		ensure_win(b)
	end

	-- If the buffer was recreated while a job was running, the old status line
	-- no longer exists.
	if status_line and status_line > vim.api.nvim_buf_line_count(b) + 1 then
		status_line = nil
	end

	local follow = true
	if win and vim.api.nvim_win_is_valid(win) then
		follow = is_at_bottom(win)
	end

	local cleaned = {}
	for i, line in ipairs(lines) do
		cleaned[i] = parser.strip_ansi(line)
	end

	local insert_at
	local first
	if status_line then
		insert_at = status_line - 1
		first = status_line
	else
		insert_at = -1
		first = vim.api.nvim_buf_line_count(b) + 1
	end

	vim.bo[b].modifiable = true
	vim.api.nvim_buf_set_lines(b, insert_at, insert_at, false, cleaned)
	if status_line then
		status_line = status_line + #cleaned
	end

	for i, line in ipairs(cleaned) do
		local lnum = first + i - 1
		local info = run.parser and run.parser:feed(line) or { line = line, spans = {} }
		set_spans(b, lnum, info.spans)
		if info.location then
			run.locations[lnum] = info.location
			run.items[#run.items + 1] = info.location
		end
	end

	if follow and opts.follow and win and vim.api.nvim_win_is_valid(win) then
		scroll_bottom(win)
	end
end

local function process_data(data)
	if not data or #data == 0 then
		return
	end

	local copy = {}
	for i = 1, #data do
		copy[i] = data[i]
	end
	copy[1] = (run.partial or "") .. copy[1]
	run.partial = table.remove(copy) or ""
	if #copy > 0 then
		append_lines(copy)
	end
end

local function render_begin(cmd, cwd)
	local b = ensure_buf()
	local w = ensure_win(b)

	run.locations = {}
	run.items = {}
	run.partial = ""
	run.parser = parser.new({
		cwd = cwd,
		is_file = function(p)
			return vim.fn.filereadable(resolve(p, cwd)) == 1
		end,
	})

	vim.bo[b].modifiable = true
	vim.api.nvim_buf_clear_namespace(b, run.ns, 0, -1)

	local header = "$ " .. cmd
	vim.api.nvim_buf_set_lines(b, 0, -1, false, { header, "[running]" })
	status_line = 2

	set_spans(b, 1, {
		{ 1, 2, "RunnerDim" },
		{ 3, #header, "RunnerCommand" },
	})
	set_spans(b, 2, { { 1, #"[running]", "RunnerRunning" } })

	scroll_bottom(w)
end

local function set_status(text, hl)
	local b = ensure_buf()
	vim.bo[b].modifiable = true

	local count = vim.api.nvim_buf_line_count(b)
	if not status_line or status_line > count then
		status_line = count + 1
		vim.api.nvim_buf_set_lines(b, -1, -1, false, { "" })
	end

	vim.api.nvim_buf_set_lines(b, status_line - 1, status_line, false, { text })
	vim.api.nvim_buf_clear_namespace(b, run.ns, status_line - 1, status_line)
	set_spans(b, status_line, { { 1, #text, hl } })
	vim.bo[b].modifiable = false
end

local function finish(code)
	local b = ensure_buf()

	if run.partial and run.partial ~= "" then
		append_lines({ run.partial })
		run.partial = ""
	end

	local elapsed = (uv.hrtime() - run.started) / 1e9
	local status, hl
	if run.stopped then
		status = "[stopped]"
		hl = "RunnerWarning"
	elseif code == 0 then
		status = string.format("[exit 0  %.2fs]", elapsed)
		hl = "RunnerOK"
	else
		status = string.format("[exit %d  %.2fs]", code, elapsed)
		hl = "RunnerFail"
	end

	set_status(status, hl)
	run.running = false
	run.job = nil

	local n = #run.items
	if opts.quickfix then
		local title = ""
		pcall(function()
			title = vim.fn.getqflist({ title = 1 }).title or ""
		end)

		if n > 0 then
			local qf = {}
			for _, item in ipairs(run.items) do
				qf[#qf + 1] = {
					filename = resolve(item.path, item.cwd or run.cwd),
					lnum = item.lnum,
					col = item.col,
					text = item.message,
					type = item.type,
					valid = 1,
				}
			end
			pcall(vim.fn.setqflist, {}, "r", {
				title = "runner: " .. (run.cmd or ""),
				items = qf,
				context = { runner = { cmd = run.cmd, cwd = run.cwd, code = code } },
			})
		elseif title:match("^runner:") then
			-- Don't leave a stale runner quickfix list after a clean run.
			pcall(vim.fn.setqflist, {}, "r", {
				title = "runner: " .. (run.cmd or ""),
				items = {},
			})
		end
	end

	local msg
	if run.stopped then
		msg = "runner: stopped"
	elseif code == 0 then
		msg = string.format("runner: exit 0 (%.2fs)", elapsed)
	else
		msg = string.format("runner: exit %d (%.2fs, %d location%s)", code, elapsed, n, n == 1 and "" or "s")
	end
	notify(msg, code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
	run.stopped = false

	-- Read-only when idle; made writable again by the next run.
	if b and vim.api.nvim_buf_is_valid(b) then
		vim.bo[b].modifiable = false
	end
end

local function expand_placeholders(cmd, cwd, editor_win)
	local file = ""
	if editor_win and vim.api.nvim_win_is_valid(editor_win) then
		file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(editor_win))
	end
	local dir = file ~= "" and vim.fn.fnamemodify(file, ":h") or cwd
	local rel = file ~= "" and vim.fn.fnamemodify(file, ":.") or ""
	local vars = {
		FILE = file,
		RELFILE = rel,
		DIR = dir,
		ROOT = cwd,
		CWD = cwd,
	}

	cmd = cmd:gsub("%${(%w+)}", function(name)
		return vars[name] or ("${" .. name .. "}")
	end)
	cmd = cmd:gsub("%$(%u+)", function(name)
		return vars[name] or ("$" .. name)
	end)
	return cmd
end

local function ensure_setup()
	if not opts then
		M.setup()
	end
end

function M.prompt(cwd, default)
	ensure_setup()
	cwd = cwd or vim.fn.getcwd()
	local history = state.history(cwd)

	_G._nvim_runner_complete = function(arglead)
		local matches = {}
		for _, cmd in ipairs(history) do
			if vim.startswith(cmd, arglead) then
				matches[#matches + 1] = cmd
			end
		end
		return matches
	end

	local ok, result = pcall(vim.fn.input, {
		prompt = "run [" .. vim.fn.fnamemodify(cwd, ":~") .. "]: ",
		default = default or state.command(cwd) or "",
		completion = "custom,_nvim_runner_complete",
	})
	if not ok or not result then
		return nil
	end

	result = vim.trim(result)
	if result == "" then
		return nil
	end
	return result
end

function M.set()
	ensure_setup()
	local cwd = current_context()
	local cmd = M.prompt(cwd, state.command(cwd))
	if not cmd then
		return
	end
	state.set_command(cwd, cmd)
	notify("runner: command set: " .. cmd)
end

function M.run(cmd)
	ensure_setup()
	local cwd, editor_win = current_context()

	if cmd == nil or vim.trim(cmd) == "" then
		cmd = state.command(cwd)
		if not cmd or vim.trim(cmd) == "" then
			cmd = M.prompt(cwd, nil)
			if not cmd then
				return
			end
			state.set_command(cwd, cmd)
		end
	else
		cmd = vim.trim(cmd)
		state.set_command(cwd, cmd)
	end

	state.push_history(cwd, cmd)

	run.id = run.id + 1
	local id = run.id
	if run.job then
		pcall(vim.fn.jobstop, run.job)
		run.job = nil
	end

	run.cmd = cmd
	run.cwd = cwd
	run.editor_win = editor_win
	run.started = uv.hrtime()
	run.running = true
	run.stopped = false
	run.hidden = false

	if opts.auto_save and vim.o.autowrite then
		pcall(vim.cmd, "silent! wall")
	end

	local expanded = expand_placeholders(cmd, cwd, editor_win)
	render_begin(cmd, cwd)

	local ok, res = pcall(vim.fn.jobstart, expanded .. " 2>&1", {
		cwd = cwd,
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data)
			if id ~= run.id then
				return
			end
			vim.schedule(function()
				if id ~= run.id then
					return
				end
				process_data(data)
			end)
		end,
		on_stderr = function(_, data)
			if id ~= run.id then
				return
			end
			vim.schedule(function()
				if id ~= run.id then
					return
				end
				process_data(data)
			end)
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				if id ~= run.id then
					return
				end
				finish(code)
			end)
		end,
	})

	if not (ok and type(res) == "number" and res > 0) then
		run.running = false
		set_status("[failed to start: " .. tostring(res) .. "]", "RunnerFail")
		notify("runner: failed to start command: " .. tostring(res), vim.log.levels.ERROR)
		return
	end

	run.job = res
end

function M.stop()
	ensure_setup()
	if not run.job then
		notify("runner: nothing is running", vim.log.levels.WARN)
		return
	end
	run.stopped = true
	pcall(vim.fn.jobstop, run.job)
end

function M.close()
	ensure_setup()
	if win and vim.api.nvim_win_is_valid(win) then
		pcall(vim.api.nvim_win_close, win, true)
	end
	win = nil
	run.hidden = true
end

function M.clear()
	ensure_setup()
	if run.running then
		notify("runner: cannot clear while a command is running", vim.log.levels.WARN)
		return
	end

	local b = ensure_buf()
	vim.bo[b].modifiable = true
	vim.api.nvim_buf_clear_namespace(b, run.ns, 0, -1)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, {})
	status_line = nil
	run.locations = {}
	run.items = {}
	run.parser = parser.new({ cwd = run.cwd })
	vim.bo[b].modifiable = false
end

function M.toggle_focus()
	ensure_setup()
	M._focus = not M._focus
	state.set_focus(M._focus)
	notify("runner: focus " .. (M._focus and "ON" or "OFF"))
	if M._focus and win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
	end
end

function M.set_focus(value)
	ensure_setup()
	M._focus = not not value
	state.set_focus(M._focus)
	notify("runner: focus " .. (M._focus and "ON" or "OFF"))
end

function M.jump(loc)
	if not loc then
		return
	end

	local cwd = loc.cwd or run.cwd or vim.fn.getcwd()
	local target = resolve(loc.path, cwd)
	if not target or vim.fn.filereadable(target) ~= 1 then
		notify("runner: file not found: " .. tostring(target or loc.path), vim.log.levels.WARN)
		return
	end

	local current_tab = vim.api.nvim_get_current_tabpage()
	local target_win = run.editor_win
	if
		not (target_win and vim.api.nvim_win_is_valid(target_win))
		or target_win == win
		or vim.api.nvim_win_get_tabpage(target_win) ~= current_tab
	then
		target_win = nil
	end

	if not target_win then
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			if w ~= win and vim.api.nvim_win_get_tabpage(w) == current_tab then
				target_win = w
				break
			end
		end
	end

	if not target_win then
		vim.cmd("aboveleft split")
		target_win = vim.api.nvim_get_current_win()
	end

	local target_buf = vim.fn.bufadd(target)
	vim.fn.bufload(target_buf)

	-- Reuse a window that already shows this buffer, if one exists.
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if w ~= win and vim.api.nvim_win_get_buf(w) == target_buf then
			target_win = w
			break
		end
	end

	local set_ok = pcall(vim.api.nvim_win_set_buf, target_win, target_buf)
	if not set_ok then
		vim.cmd("aboveleft split")
		target_win = vim.api.nvim_get_current_win()
		pcall(vim.api.nvim_win_set_buf, target_win, target_buf)
	end
	vim.api.nvim_set_current_win(target_win)
	local count = vim.api.nvim_buf_line_count(target_buf)
	local lnum = math.max(1, math.min(loc.lnum or 1, count))
	local text = vim.api.nvim_buf_get_lines(target_buf, lnum - 1, lnum, false)[1] or ""
	local col = column_to_byte(text, loc.col)
	pcall(vim.api.nvim_win_set_cursor, target_win, { lnum, col })
	pcall(vim.api.nvim_win_call, target_win, function()
		vim.cmd("normal! zz")
	end)
	run.editor_win = target_win
end

function M.jump_at_cursor()
	ensure_setup()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local loc = run.locations[lnum]
	if loc then
		M.jump(loc)
	else
		notify("runner: no location on this line", vim.log.levels.WARN)
	end
end

function M.next_location(direction)
	ensure_setup()
	local lnum = vim.api.nvim_win_get_cursor(0)[1]
	local lines = {}
	for l in pairs(run.locations) do
		lines[#lines + 1] = l
	end
	table.sort(lines)

	if #lines == 0 then
		notify("runner: no locations", vim.log.levels.WARN)
		return
	end

	local target
	if direction >= 0 then
		for _, l in ipairs(lines) do
			if l > lnum then
				target = l
				break
			end
		end
		target = target or lines[1]
	else
		for i = #lines, 1, -1 do
			if lines[i] < lnum then
				target = lines[i]
				break
			end
		end
		target = target or lines[#lines]
	end

	vim.api.nvim_win_set_cursor(0, { target, 0 })
	M.jump(run.locations[target])
end

local function on_mouse()
	local m = vim.fn.getmousepos()
	local b = ensure_buf()
	local cur = vim.api.nvim_get_current_win()

	if m.winid ~= 0 and m.winid ~= cur and vim.api.nvim_win_is_valid(m.winid) then
		vim.api.nvim_set_current_win(m.winid)
		local target_buf = vim.api.nvim_win_get_buf(m.winid)
		local count = vim.api.nvim_buf_line_count(target_buf)
		local lnum = math.max(1, math.min(m.line or 1, count))
		local text = vim.api.nvim_buf_get_lines(target_buf, lnum - 1, lnum, false)[1] or ""
		local col = math.max(0, math.min((m.column or 1) - 1, math.max(#text - 1, 0)))
		pcall(vim.api.nvim_win_set_cursor, m.winid, { lnum, col })
		return
	end

	local lnum = m.line
	if not lnum or lnum < 1 then
		return
	end

	local line = vim.api.nvim_buf_get_lines(b, lnum - 1, lnum, false)[1] or ""
	local col = math.max(0, math.min((m.column or 1) - 1, math.max(#line - 1, 0)))
	pcall(vim.api.nvim_win_set_cursor, cur, { lnum, col })

	local loc = run.locations[lnum]
	if loc then
		M.jump(loc)
	end
end

set_buffer_maps = function(b)
	local o = { buffer = b, silent = true, nowait = true }
	vim.keymap.set("n", "<CR>", M.jump_at_cursor, vim.tbl_extend("force", o, { desc = "Open location" }))
	vim.keymap.set("n", "<LeftMouse>", on_mouse, o)
	vim.keymap.set("n", "<2-LeftMouse>", on_mouse, o)
	vim.keymap.set("n", "q", M.close, o)
	vim.keymap.set("n", "R", M.run, vim.tbl_extend("force", o, { desc = "Run again" }))
	vim.keymap.set("n", "<C-c>", M.stop, o)
	vim.keymap.set("n", "<C-n>", function()
		M.next_location(1)
	end, o)
	vim.keymap.set("n", "<C-p>", function()
		M.next_location(-1)
	end, o)
end

function M.info()
	ensure_setup()
	local cwd = current_context()
	notify(
		string.format(
			"runner: %s\ncwd: %s\nfocus: %s\nstate: %s",
			state.command(cwd) or "<not set>",
			cwd,
			tostring(M._focus),
			state.path()
		)
	)
end

local function create_commands()
	local commands = {
		{
			name = "RunnerRun",
			cmd = function(args)
				local cmd = vim.trim(table.concat(args.fargs, " "))
				M.run(cmd ~= "" and cmd or nil)
			end,
			opts = { nargs = "*", complete = "shellcmd", desc = "Run the current runner command" },
		},
		{
			name = "RunnerSet",
			cmd = function(args)
				local cmd = vim.trim(table.concat(args.fargs, " "))
				local cwd = current_context()
				if cmd == "" then
					cmd = M.prompt(cwd, state.command(cwd))
				end
				if not cmd then
					return
				end
				state.set_command(cwd, cmd)
				notify("runner: command set: " .. cmd)
			end,
			opts = { nargs = "*", complete = "shellcmd", desc = "Set the runner command for this cwd" },
		},
		{ name = "RunnerStop", cmd = M.stop, opts = { desc = "Stop the running command" } },
		{ name = "RunnerClose", cmd = M.close, opts = { desc = "Close the runner pane" } },
		{ name = "RunnerClear", cmd = M.clear, opts = { desc = "Clear the runner output" } },
		{
			name = "RunnerFocus",
			cmd = function(args)
				local value = vim.trim(args.args or ""):lower()
				if value == "on" then
					M.set_focus(true)
				elseif value == "off" then
					M.set_focus(false)
				else
					M.toggle_focus()
				end
			end,
			opts = { nargs = "?", complete = function() return { "on", "off" } end, desc = "Toggle run pane focus" },
		},
		{ name = "RunnerInfo", cmd = M.info, opts = { desc = "Show runner state" } },
	}

	for _, entry in ipairs(commands) do
		pcall(vim.api.nvim_del_user_command, entry.name)
		vim.api.nvim_create_user_command(entry.name, entry.cmd, entry.opts)
	end
end

function M.setup(user_opts)
	opts = vim.tbl_deep_extend("force", {
		focus = true,
		height = 12,
		follow = true,
		quickfix = true,
		auto_save = true,
		keymaps = {
			run = "<leader>r",
			set = "<leader>R",
			toggle_focus = "<leader>rf",
		},
	}, user_opts or {})

	state.load()
	M._focus = state.focus(opts.focus)

	define_highlights()
	vim.api.nvim_create_augroup("NvimRunner", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = "NvimRunner",
		callback = define_highlights,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = "NvimRunner",
		callback = function(args)
			if win and tonumber(args.match) == win then
				win = nil
				run.hidden = true
			end
		end,
	})

	create_commands()

	local km = opts.keymaps
	if km ~= false then
		km = km or {}
		local function map(lhs, fn, desc)
			if lhs and lhs ~= false then
				vim.keymap.set("n", lhs, fn, { desc = desc })
			end
		end
		map(km.run or "<leader>r", M.run, "Run command in output pane")
		map(km.set or "<leader>R", M.set, "Set run command")
		map(km.toggle_focus or "<leader>rf", M.toggle_focus, "Toggle run pane focus")
	end

	return M
end

-- Useful for tests and for automation.
function M.buffer()
	return buf
end

function M.window()
	return win
end

function M.is_running()
	return run.running
end

function M.locations()
	return run.locations
end

return M
