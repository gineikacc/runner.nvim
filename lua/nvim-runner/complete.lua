-- Shell-style completion for the runner command prompt.
--
-- The prompt is a shell command, so completion needs to understand that:
--   * the first word is usually a program name (PATH completion),
--   * later words are often file paths,
--   * history entries complete only the token the cursor is on.
--
-- `complete.shell()` is shared by the `input()` prompt and by the
-- `:RunnerRun` / `:RunnerSet` user commands.

local M = {}

local function add(out, seen, item)
	if item and item ~= "" and not seen[item] then
		seen[item] = true
		out[#out + 1] = item
	end
end

local function unquote(arg)
	local q = arg:sub(1, 1)
	if q == '"' or q == "'" then
		return arg:sub(2), q
	end
	return arg, nil
end

-- Remove backslash escapes so `dir\ with\ space` can be passed to
-- getcompletion(), which expects a real path.
local function unescape(arg)
	return (arg:gsub("\\(.)", "%1"))
end

local function escape(path, quote)
	if quote then
		return quote .. path
	end
	return (path:gsub(" ", "\\ "))
end

-- Find where the argument under the cursor starts.  It understands simple
-- quoting and backslash escapes.
local function token_start(prefix)
	local start = 1
	local quote
	local i = 1
	while i <= #prefix do
		local c = prefix:sub(i, i)
		if c == "\\" then
			i = i + 2
		elseif quote then
			if c == quote then
				quote = nil
			end
			i = i + 1
		elseif c == "'" or c == '"' then
			quote = c
			i = i + 1
		elseif c:match("%s") then
			start = i + 1
			i = i + 1
		else
			i = i + 1
		end
	end
	return start
end

-- Complete only the token under the cursor from history.  `lead` is what the
-- candidate must replace: just the current word for user-command completion,
-- or the whole line so far for input() completion.  For example, with history
-- `{ "gcc main.c -o app" }`, the line `gcc ma`, and `lead = "gcc ma"`, this
-- returns `gcc main.c`.
local function history_matches(prefix, lead, history)
	local out = {}
	for _, cmd in ipairs(history or {}) do
		if cmd:sub(1, #prefix) == prefix and #cmd > #prefix then
			local rest = cmd:sub(#prefix + 1)
			local token = rest:match("^[^%s]*")
			if token and token ~= "" then
				out[#out + 1] = lead .. token
			end
		end
	end
	return out
end

-- opts:
--   history: list of previous commands for the current cwd
--
-- `cmdline` must start at the command itself, not at ":RunnerRun" etc.
function M.shell(arglead, cmdline, cursorpos, opts)
	arglead = arglead or ""
	cmdline = cmdline or ""
	cursorpos = cursorpos or #cmdline
	opts = opts or {}

	-- input() passes the whole text before the cursor as ArgLead, while user
	-- command completion passes only the current word.  Detect the difference
	-- so we complete the right token in both cases.
	local input_mode = arglead == cmdline:sub(1, math.max(cursorpos, 0))
	local prefix
	local start
	if input_mode then
		prefix = cmdline:sub(1, math.max(cursorpos, 0))
		start = token_start(prefix)
		arglead = prefix:sub(start)
	else
		prefix = cmdline:sub(1, math.max(cursorpos - 1, 0))
		start = token_start(prefix)
		if #arglead > #prefix - start + 1 then
			start = #prefix - #arglead + 1
		end
	end

	local before = prefix:sub(1, start - 1)
	local first = before:match("^%s*$") ~= nil

	-- input() replaces the whole ArgLead with the chosen candidate, while
	-- command completion replaces only the current word.
	local lead = input_mode and prefix or arglead
	local base = input_mode and before or ""

	local out, seen = {}, {}
	for _, item in ipairs(history_matches(prefix, lead, opts.history)) do
		add(out, seen, item)
	end

	local quoted, quote = unquote(arglead)
	local lookup = unescape(quoted)

	-- At the start of an empty prompt, prefer program names over the whole
	-- contents of the cwd.
	if not (first and arglead == "") then
		local ok, files = pcall(vim.fn.getcompletion, lookup, "file")
		if ok and type(files) == "table" then
			for _, file in ipairs(files) do
				add(out, seen, base .. escape(file, quote))
			end
		end
	end

	if first and not arglead:match("^[./~]") then
		local ok, cmds = pcall(vim.fn.getcompletion, lookup, "shellcmd")
		if ok and type(cmds) == "table" then
			for _, cmd in ipairs(cmds) do
				add(out, seen, base .. escape(cmd, quote))
			end
		end
	end

	return out
end

return M
