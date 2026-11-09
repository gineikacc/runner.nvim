-- Output parser for runner.nvim.
--
-- This is deliberately independent of any language server or compiler: it
-- recognises the common "file:line[:col]" shapes emitted by gcc/clang, rustc,
-- go, Python, tsc, eslint, shellcheck, CMake, Node stack traces, etc.

local M = {}

local pack = table.pack or function(...)
	return { n = select("#", ...), ... }
end

local PATH = "RunnerPath"
local LINE = "RunnerLine"
local COL = "RunnerColumn"
local SEP = "RunnerSeparator"

local function sev_hl(sev)
	if sev == "warning" then
		return "RunnerWarning"
	elseif sev == "note" then
		return "RunnerNote"
	elseif sev == "info" then
		return "RunnerInfo"
	end
	return "RunnerError"
end

local function sev_type(sev)
	if sev == "warning" then
		return "W"
	elseif sev == "note" then
		return "N"
	elseif sev == "info" then
		return "I"
	end
	return "E"
end

local function severity_from_word(word)
	if not word then
		return nil
	end
	local w = vim.trim(word):lower()
	if w == "" then
		return nil
	end

	if w:match("^fatal") or w:match("^error") or w:match("^err") or w:match("^e%d") then
		return "error"
	end
	if w:match("^warning") or w:match("^warn") or w:match("^w%d") then
		return "warning"
	end
	if w:match("^note") or w:match("^n%d") then
		return "note"
	end
	if w:match("^info") or w:match("^hint") or w:match("^remark") or w:match("^i%d") or w:match("^h%d") then
		return "info"
	end
	if w:match("^c%d") or w:match("^r%d") then
		return "info"
	end
	if w:match("^f%d") then
		return "error"
	end
	return nil
end

local SEVERITY_WORDS = {
	{ word = "fatal error", sev = "error" },
	{ word = "error", sev = "error" },
	{ word = "warning", sev = "warning" },
	{ word = "warn", sev = "warning" },
	{ word = "note", sev = "note" },
	{ word = "remark", sev = "info" },
	{ word = "info", sev = "info" },
	{ word = "hint", sev = "info" },
	{ word = "help", sev = "info" },
}

local function find_severity(line)
	local lower = line:lower()
	for _, entry in ipairs(SEVERITY_WORDS) do
		local pattern = "%f[%a]" .. entry.word:gsub(" ", "%%s+") .. "%f[%A]"
		local s, e = lower:find(pattern)
		if s then
			return entry.sev, s, e
		end
	end

	local s, e, code = line:find("%f[%u]([A-Z]%d+)%f[%D]")
	if s then
		local sev = severity_from_word(code)
		if sev then
			return sev, s, e
		end
	end
	return nil
end

local KNOWN_FILES = {
	Makefile = true,
	makefile = true,
	GNUmakefile = true,
	Dockerfile = true,
	Containerfile = true,
	Rakefile = true,
	Gemfile = true,
	Procfile = true,
	Justfile = true,
	justfile = true,
}

local function basename(p)
	return p:match("([^/\\]+)$") or p
end

local function looks_like_path(p, is_file)
	if type(p) ~= "string" then
		return false
	end
	p = vim.trim(p)
	if p == "" or #p > 1000 then
		return false
	end
	if p:find("\n") or p:find("\r") then
		return false
	end
	if p:sub(1, 1) == "<" or p:sub(1, 1) == "[" then
		return false
	end
	if p:match("^%d+$") then
		return false
	end
	-- A path with whitespace is only accepted when the caller can confirm it
	-- really exists.  This avoids treating prose such as
	-- "thread 'main' panicked at src/main.rs" as one long file name.
	if p:find("%s") and not (type(is_file) == "function" and is_file(p)) then
		return false
	end
	if KNOWN_FILES[basename(p)] or basename(p) == "CMakeLists.txt" then
		return true
	end
	if p:find("[/\\]") then
		return true
	end
	if p:match("%.[%w_%-]+$") then
		return true
	end
	if type(is_file) == "function" and is_file(p) then
		return true
	end
	return false
end

local function strip_ansi(s)
	s = s:gsub("\27%[[0-9;?]*[%a]", "")
	s = s:gsub("\27%][^\7\27]*\7", "")
	s = s:gsub("\27%][^\7]*\7", "")
	s = s:gsub("\r$", "")
	-- Progress output often uses \r; keep only the last visual segment.
	s = s:gsub(".*\r", "")
	return s
end

M.strip_ansi = strip_ansi

-- Descriptors for the recognised location shapes.  The order matters: the
-- more specific severity/code forms are tried before the generic forms.
local PATTERNS = {
	-- file:line:col: severity: message
	{ p = "^(.-):(%d+):(%d+):%s*([%a][%w_ ]-):%s*(.*)$", path = 1, line = 2, col = 3, sev = 4, msg = 5 },
	-- file:line:col: error[E0308]: message
	{ p = "^(.-):(%d+):(%d+):%s*([%a][%w_ ]*%b[]):%s*(.*)$", path = 1, line = 2, col = 3, sev = 4, msg = 5 },
	-- file:line: severity: message
	{ p = "^(.-):(%d+):%s*([%a][%w_ ]-):%s*(.*)$", path = 1, line = 2, sev = 3, msg = 4 },
	-- file:line:col: CODE: message (pylint, ruff, pyright, ...)
	{ p = "^(.-):(%d+):(%d+):%s*([A-Z]%d+):%s*(.*)$", path = 1, line = 2, col = 3, sev = 4, msg = 5 },
	-- file:line:col: CODE message
	{ p = "^(.-):(%d+):(%d+):%s*([A-Z]%d+)%s+(.*)$", path = 1, line = 2, col = 3, sev = 4, msg = 5 },
	-- file(line,col): severity: message (tsc, dotnet)
	{ p = "^(.-)%((%d+),(%d+)%):%s*([%a][%w_ ]-):%s*(.*)$", path = 1, line = 2, col = 3, sev = 4, msg = 5 },
	-- rustc: --> file:line:col
	{ p = "^%s*%-%->%s*(.-):(%d+):(%d+)%s*$", path = 1, line = 2, col = 3, msg = 0 },
	-- rustc: --> file:line
	{ p = "^%s*%-%->%s*(.-):(%d+)%s*$", path = 1, line = 2, msg = 0 },
	-- Python/OCaml: File "file", line N
	{ p = '^%s*File%s+"(.-)",%s*line%s+(%d+)', path = 1, line = 2, msg = 0 },
	-- shell: file: line N: message
	{ p = "^(.-):%s*line%s+(%d+):%s*(.*)$", path = 1, line = 2, msg = 3 },
	-- CMake Error/Warning at file:line
	{ p = "^CMake%s+([%a]+)%s+at%s+(.-):(%d+)%s*(.*)$", sev = 1, path = 2, line = 3, msg = 4 },
	-- gcc include chain
	{ p = "^In file included from%s+(.-):(%d+)", path = 1, line = 2, msg = 0 },
	-- Node: at function (file:line:col)
	{ p = "^%s*at%s+.-%((.-):(%d+):(%d+)%)", path = 1, line = 2, col = 3, msg = 0 },
	-- Node: at file:line:col
	{ p = "^%s*at%s+(.-):(%d+):(%d+)%s*$", path = 1, line = 2, col = 3, msg = 0 },
	-- Interpreter prefix: lua: main.lua:5: message
	{ p = "^(%a[%w_%-]*):%s+(.-):(%d+):(%d+):%s*(.*)$", path = 2, line = 3, col = 4, msg = 5 },
	{ p = "^(%a[%w_%-]*):%s+(.-):(%d+):%s*(.*)$", path = 2, line = 3, msg = 4 },
	-- Generic file:line:col: message
	{ p = "^(.-):(%d+):(%d+):%s*(.*)$", path = 1, line = 2, col = 3, msg = 4 },
	-- Generic file:line: message
	{ p = "^(.-):(%d+):%s*(.*)$", path = 1, line = 2, msg = 3 },
	-- Generic file(line,col): message
	{ p = "^(.-)%((%d+),(%d+)%)%s*:?%s*(.*)$", path = 1, line = 2, col = 3, msg = 4 },
}

local function add_span(spans, s, e, hl)
	if s and e and s >= 1 and e >= s then
		spans[#spans + 1] = { s, e, hl }
	end
end

local FIELD_ORDER = { "path", "line", "col", "sev", "msg" }

-- Lua's string.find() returns capture *values*, not their positions.  Search
-- the captures back out of the matched line in order, which is reliable because
-- captures appear left-to-right in these patterns.
local function capture_map(line, pattern, fields)
	local r = pack(line:find(pattern))
	if not r[1] then
		return nil
	end

	local list = {}
	for _, field in ipairs(FIELD_ORDER) do
		local idx = fields[field]
		if idx and idx > 0 then
			list[#list + 1] = { field = field, idx = idx }
		end
	end
	table.sort(list, function(a, b)
		return a.idx < b.idx
	end)

	local out = {}
	local cursor = r[1]
	for _, item in ipairs(list) do
		local value = r[item.idx + 2]
		if value ~= nil then
			local s, e
			if value == "" then
				s, e = cursor, cursor - 1
			else
				s, e = line:find(value, cursor, true)
				if not s then
					s, e = line:find(value, 1, true)
				end
				if s then
					cursor = e + 1
				end
			end
			out[item.field] = { value = value, s = s, e = e }
		end
	end
	return out
end

local function make_location(self, line, f)
	local lnum = tonumber(f.lnum)
	if not lnum or lnum < 1 then
		return nil
	end

	local path = f.path
	if not path or not looks_like_path(path, self.opts.is_file) then
		return nil
	end

	local spans = {}
	add_span(spans, f.ps, f.pe, PATH)
	add_span(spans, f.ls, f.le, LINE)
	add_span(spans, f.cs, f.ce, COL)

	-- Colour the punctuation between path/line/column dimly.
	if f.ps and f.ls and f.ls > f.pe + 1 then
		add_span(spans, f.pe + 1, f.ls - 1, SEP)
	end
	if f.ls and f.cs and f.cs > f.le + 1 then
		add_span(spans, f.le + 1, f.cs - 1, SEP)
	end

	local severity = f.severity
	if severity then
		if f.ss then
			add_span(spans, f.ss, f.se, sev_hl(severity))
		else
			local _, s, e = find_severity(line)
			add_span(spans, s, e, sev_hl(severity))
		end
	else
		local found, s, e = find_severity(line)
		if found then
			severity = found
			add_span(spans, s, e, sev_hl(severity))
		end
	end
	severity = severity or "error"

	local message = f.message
	if not message or vim.trim(message) == "" then
		message = line
	end

	return {
		path = path,
		lnum = lnum,
		col = tonumber(f.col) or 1,
		severity = severity,
		message = vim.trim(message),
		spans = spans,
		type = sev_type(severity),
		cwd = self.cwd,
	}
end

local function try_patterns(self, line)
	for _, pat in ipairs(PATTERNS) do
		local caps = capture_map(line, pat.p, pat)
		if caps then
			local path = caps.path and caps.path.value
			local lnum = caps.line and caps.line.value
			local sevw = caps.sev and caps.sev.value
			local msg = caps.msg and caps.msg.value

			local ok = true
			local severity
			if sevw then
				severity = severity_from_word(sevw)
				if not severity then
					-- Something like "undefined:" is a message, not a severity.
					ok = false
				end
			end

			-- rustc puts the severity/message on the "error[...]:" line and the
			-- location on the following "--> file:line:col" line.
			if ok and not severity and self.pending and pat.sev == nil then
				severity = self.pending.severity
			end
			if ok and (not msg or vim.trim(msg) == "") and self.pending and pat.msg == 0 then
				msg = self.pending.message
			end

			if ok and path and looks_like_path(path, self.opts.is_file) and tonumber(lnum) then
				local loc = make_location(self, line, {
					path = path,
					ps = caps.path.s,
					pe = caps.path.e,
					lnum = lnum,
					ls = caps.line.s,
					le = caps.line.e,
					col = caps.col and caps.col.value,
					cs = caps.col and caps.col.s,
					ce = caps.col and caps.col.e,
					severity = severity,
					ss = caps.sev and caps.sev.s,
					se = caps.sev and caps.sev.e,
					message = msg,
				})
				if loc then
					return loc
				end
			end
		end
	end
	return nil
end

local function try_eslint(self, line)
	if not self.current_file then
		return nil
	end

	local caps = capture_map(line, "^%s*(%d+):(%d+)%s+([%a]+)%s+(.*)$", {
		line = 1,
		col = 2,
		sev = 3,
		msg = 4,
	})
	if not caps then
		return nil
	end

	local severity = severity_from_word(caps.sev.value)
	local msg = caps.msg.value
	if not severity then
		-- Keep the unknown word as part of the message.
		msg = vim.trim(line:sub(caps.col.e + 1))
	end

	return make_location(self, line, {
		path = self.current_file,
		lnum = caps.line.value,
		ls = caps.line.s,
		le = caps.line.e,
		col = caps.col.value,
		cs = caps.col.s,
		ce = caps.col.e,
		severity = severity,
		ss = caps.sev.s,
		se = caps.sev.e,
		message = msg,
	})
end

local function try_fallback(self, line)
	-- Last resort for lines such as stack traces that contain a location in the
	-- middle of the line.
	local s, e, path, lnum, col = line:find("([%w%._/\\~@%-]+):(%d+):(%d+)")
	if s and looks_like_path(path, self.opts.is_file) then
		local loc = make_location(self, line, {
			path = path,
			ps = s,
			pe = s + #path - 1,
			lnum = lnum,
			ls = s + #path + 1,
			le = s + #path + 1 + #lnum - 1,
			col = col,
			cs = s + #path + 1 + #lnum + 1,
			ce = s + #path + 1 + #lnum + 1 + #col - 1,
			message = line,
		})
		if loc then
			return loc
		end
	end

	s, e, path, lnum = line:find("([%w%._/\\~@%-]+):(%d+)")
	if s and looks_like_path(path, self.opts.is_file) then
		local loc = make_location(self, line, {
			path = path,
			ps = s,
			pe = s + #path - 1,
			lnum = lnum,
			ls = s + #path + 1,
			le = s + #path + 1 + #lnum - 1,
			message = line,
		})
		if loc then
			return loc
		end
	end

	return nil
end

function M.new(opts)
	opts = opts or {}
	local self = {
		opts = opts,
		cwd = opts.cwd,
		pending = nil,
		current_file = nil,
	}

	function self:reset()
		self.pending = nil
		self.current_file = nil
	end

	function self:feed(raw)
		local line = strip_ansi(raw or "")

		if line:match("^%s*$") then
			self.current_file = nil
			self.pending = nil
			return { line = line, spans = {} }
		end

		-- eslint's stylish formatter ends with a summary; don't let a stale
		-- file header turn later numbers into locations.
		if line:match("^%s*[✖✔]") or line:match("^%s*%d+%s+problems?") or line:match("^Done in") then
			self.current_file = nil
		end

		local eslint = try_eslint(self, line)
		if eslint then
			return { line = line, location = eslint, spans = eslint.spans }
		end

		local loc = try_patterns(self, line) or try_fallback(self, line)
		if loc then
			return { line = line, location = loc, spans = loc.spans }
		end

		local spans = {}

		-- Remember rustc's "error[E0308]:" / "warning:" text so the following
		-- "--> file:line:col" line gets the right severity/message.
		local sev_word, msg = line:match("^%s*([%a]+)%b[]:%s*(.*)$")
		if not sev_word then
			sev_word, msg = line:match("^%s*([%a]+):%s*(.*)$")
		end
		if sev_word then
			local sev = severity_from_word(sev_word)
			if sev then
				self.pending = { severity = sev, message = msg or line }
			end
		end

		-- eslint/other tools print the file name on a line of its own.
		local trim = vim.trim(line)
		if trim == line and not trim:find("%s") and not trim:find(":%d") then
			if looks_like_path(trim, self.opts.is_file) then
				self.current_file = trim
				add_span(spans, 1, #line, PATH)
			end
		else
			-- gcc: "main.c: In function 'main':" and similar headers.
			local s, e, path = line:find("^(.-):%s+In%s+")
			if not s then
				s, e, path = line:find("^(.-):%s+At%s+")
			end
			if s and path and looks_like_path(path, self.opts.is_file) then
				add_span(spans, 1, #path, PATH)
			end
		end

		local sev, s, e = find_severity(line)
		if s then
			add_span(spans, s, e, sev_hl(sev))
		end

		return { line = line, spans = spans }
	end

	return self
end

return M
