# AGENTS.md — runner.nvim

Notes for agents (and humans) working on this repository.  Keep this file up to
date when behaviour or the architecture changes.

## What this is

`runner.nvim` is a small standalone Neovim plugin.  It runs one shell command
per working directory and streams the output into a persistent, clickable
bottom split.  Output containing `file:line[:col]` is parsed into jump targets
and also copied into Neovim's quickfix list.

It is plain Lua and has no build step.  Minimum version is Neovim 0.9
(0.10+ is the practical target).

## Repository map

| Path | Responsibility |
| --- | --- |
| `lua/runner/init.lua` | Public API, prompt, job lifecycle, output buffer, pane/window handling, navigation, user commands, keymaps, setup. |
| `lua/runner/parser.lua` | Converts command output lines into `{ path, lnum, col, severity, message }` locations and highlight spans. |
| `lua/runner/state.lua` | Persists the per-cwd command, per-cwd history, and focus preference as JSON. |
| `lua/runner/complete.lua` | Shell-aware Tab completion for program names, file paths, and command history. |
| `plugin/runner.lua` | Standard plugin entry point.  Guards against double-loading and applies default setup so the repository works immediately after installation. |
| `README.md` | User-facing documentation. |
| `AGENTS.md` | This file: architecture, status, and agent workflow. |

There are no tests yet; the "Development / smoke tests" section below contains
headless commands that currently serve as the test suite.

## Run-time flow

1. `plugin/runner.lua` calls `setup()` with defaults unless the user
   already called it.  `setup(opts)` merges defaults, loads state, defines
   highlights, installs the completion wrapper and autocmds, creates commands,
   and (re)installs global keymaps.  Calling `setup()` again is supported: old
   plugin-owned keymaps are removed first, so `keymaps = false` and custom
   mappings work as expected.
2. `M.run(cmd)` resolves the cwd from the current editor window.  If `cmd` is
   nil/empty it uses the saved command, and if that is missing it prompts.
   An explicit command is saved immediately.
3. `run.cwd` and `run.editor_win` are remembered so later jumps can return to
   the source window.  Placeholders (`$FILE`, `$RELFILE`, `$DIR`, `$ROOT`,
   `$CWD`) are expanded before the shell sees the command.
4. `render_begin()` resets parser/location state, writes the `$ command` header
   and a `[running]` status line, then `jobstart()` streams stdout/stderr.
5. Every streamed line goes through `parser:feed()`; the parser returns
   highlight spans and optionally a location.  Locations are stored by buffer
   line number in `run.locations` for click/`<CR>`/next/prev navigation.
6. `finish()` appends any partial line, replaces the status line with the exit
   status, marks the buffer non-modifiable, and populates quickfix when the
   latest run produced locations.
7. Jumping (`M.jump`) reuses the remembered editor window, opens/loads the
   target buffer there, converts compiler display columns to byte offsets, and
   keeps the runner pane visible.

Jobs are guarded by an incrementing `run.id`; callbacks from an older job are
ignored after a new run starts.

## State file

`stdpath("state")/runner/state.json`:

```json
{
  "version": 1,
  "focus": true,
  "commands": { "/home/me/project": "make -j" },
  "history":  { "/home/me/project": ["make -j", "gcc main.c"] }
}
```

Keys are normalised with `vim.fs.normalize(getcwd())`.  Writes are atomic
(write temp file, then rename).  Nothing is written into project directories.

## Command completion and the prompt

`complete.shell(arglead, cmdline, cursorpos, { history = ... })` is the single
completion implementation.

- The first word (program position) completes from `getcompletion(..., "shellcmd")`.
- File/path words complete from `getcompletion(..., "file")`.
- History completes only the token under the cursor, but the *replacement
  shape* depends on the caller (see below).  With history
  `{ "gcc main.c -o app" }` and the line `gcc ma`, the prompt gets the full
  line `gcc main.c`, while `:RunnerRun` gets just `main.c`.
- Spaces in returned paths are backslash-escaped.  A quote already open in
  `arglead` is preserved, so completing `"dir` yields `"dir with space/`.
- Duplicates are removed.  An empty first word prefers program names over
  listing the entire cwd.

The two callers pass different data:

| Caller | ArgLead | Candidate must replace |
| --- | --- | --- |
| `input()` prompt | entire text before the cursor | the entire text before the cursor |
| user command | current space-separated word only | just that word |

`complete.shell()` detects this by checking whether `ArgLead` equals
`cmdline:sub(1, cursorpos)`.  In prompt mode it prepends the text before the
current token to every candidate.  This is why a raw candidate list of
`{ "main.c" }` would replace the whole prompt line instead of appending to
`gcc `.

Two entry points:

- `:RunnerRun` and `:RunnerSet` pass the Lua function `M.complete` directly to
  `nvim_create_user_command({ complete = ... })`.  Vim includes the command name
  in the command line, so `M.complete` strips the first token before calling
  `complete.shell`.
- The `input()` prompt uses `completion = "customlist,RunnerPromptComplete"`.
  `setup()` defines that tiny Vimscript function; it forwards its three
  arguments through `luaeval()` to `M.complete_prompt`.  This wrapper is
  required: Lua functions stored in `_G` are **not** callable as Vimscript
  functions, so the previous `custom,_runner_complete` approach silently
  did not work with `input()`.

`getcompletion("file")` resolves relative paths against the process cwd, which
matches the cwd used by the prompt in normal use.  The prompt stores its cwd in
`prompt_cwd` so `M.complete_prompt` can look up the correct history.

## Parser

`parser.new({ cwd, is_file })` returns an object with `feed(line)`; it is
stateful because some tools split severity/file information across lines.

- `PATTERNS` in `parser.lua` is an ordered list of Lua patterns.  More specific
  forms come first.
- `looks_like_path()` filters out prose and compiler noise.  Paths containing
  whitespace are accepted only when `is_file()` confirms they exist.
- Rust's `error[E0308]:` line is remembered as `pending`, then applied to the
  following `--> file:line:col` line.
- eslint's file header is remembered as `current_file`; numbered rows below it
  become locations.
- `try_fallback()` catches embedded locations such as Node stack traces.
- Severity words (`error`, `warning`, `note`, `info`, `hint`, ...) are detected
  for highlighting even when the line is not a jumpable location.
- `column_to_byte()` in `init.lua` converts compiler display columns (tabs count
  to the next multiple of 8) to byte columns for `nvim_win_set_cursor`.

To support a new tool, add its most specific pattern before the generic
`file:line[:col]` patterns and verify path filtering with a real sample line.

## Pane, keys, and commands

The pane is a `nofile` scratch buffer shown in a `botright <height>split`.
`opts.focus` decides whether the split steals focus.  Closing the pane keeps
the job running (`run.hidden = true`); a later run reopens it.  `WinClosed`
clears the cached window handle.

Buffer-local keys: `<CR>` / mouse opens a location, `<C-n>` / `<C-p>` cycle
locations, `R` reruns, `<C-c>` stops, `q` closes the pane.

User commands: `:RunnerRun`, `:RunnerSet`, `:RunnerStop`, `:RunnerClose`,
`:RunnerClear`, `:RunnerForget`, `:RunnerFocus [on|off]`, `:RunnerInfo`.

Global keymaps (configurable or disable with `keymaps = false`):
`<M-r>` run, `<M-R>` set/prompt, `<M-f>` toggle focus stealing.  A single
mapping can be disabled by setting it to `false` in the `keymaps` table.

## Configuration

```lua
require("runner").setup({
  focus = true,       -- focus the pane when it opens
  height = 12,        -- split height
  follow = true,      -- auto-scroll while output arrives
  quickfix = true,    -- replace quickfix after runs with locations
  auto_save = true,   -- `silent! wall` before starting a job
  keymaps = {
    run = "<M-r>",
    set = "<M-R>",
    toggle_focus = "<M-f>",
  },
})
```

`focus` is also persisted in the state file and can be changed at runtime.

`auto_save` now writes modified file buffers with `silent! wall` before the
job starts.  It no longer depends on Neovim's `'autowrite'` option.  The runner
scratch buffer is skipped by `:wall` because it is `nofile`.

## Status

Working:

- [x] Per-cwd command, explicit command saving, prompt, and history.
- [x] Bottom output pane, live streaming, follow/auto-scroll, exit status.
- [x] Clickable `<CR>`/mouse/next/previous locations.
- [x] Quickfix population from parsed locations, with stale-list cleanup.
- [x] Highlighting of path, line, column, separators, severity.
- [x] Parser coverage for gcc/clang, rustc, go, Python, tsc, eslint,
      pylint/ruff, shellcheck, CMake, make, Node stack traces, and fallbacks.
- [x] Focus toggle, persistence, hidden pane handling, window-closed handling.
- [x] `:RunnerForget`.
- [x] Auto-save before run, controlled by `opts.auto_save`.
- [x] Program-name and file-path Tab completion in the prompt.
- [x] Program-name and file-path completion for `:RunnerRun` / `:RunnerSet`.
- [x] Prompt completion actually wired through a Vimscript wrapper.
- [x] Standard `plugin/` entry point with guard and default auto-setup.
- [x] Repeated `setup()` calls replace plugin-owned keymaps cleanly.
- [x] Default keymaps use Alt keys (`<M-r>`, `<M-R>`, `<M-f>`).

Known gaps / possible next work:

- [ ] No automated test harness.  The parser is a good candidate for pure-Lua
      tests; the pane/job lifecycle needs a headless Neovim harness.
- [ ] Completion is synchronous.  `getcompletion()` in an enormous directory
      can block the command line; this is normally acceptable.
- [ ] Token splitting understands whitespace, quotes, and backslash escapes,
      but not shell operators such as `&&`, `;`, and `|`.
- [ ] No configurable filetype/location parser hooks; new formats go directly
      into `parser.lua`.

## Development / smoke tests

Load the plugin and check completion (run from a directory containing files):

```sh
cd /tmp/some-project
nvim --clean --headless -u NONE \
  --cmd "set rtp+=$PWD" \
  -c 'lua require("runner").setup({ keymaps = false })' \
  -c 'lua print(vim.inspect(vim.fn.getcompletion("RunnerRun gcc ma", "cmdline")))' \
  -c 'qa!'
```

Exercise the completion module directly:

```sh
nvim --clean --headless -u NONE \
  --cmd "set rtp+=$PWD" \
  -c 'lua local c=require("runner.complete"); print(vim.inspect(c.shell("ma","gcc ma",7,{history={"gcc main.c"}})))' \
  -c 'qa!'
```

Run a command and inspect the pane:

```sh
nvim --clean --headless -u NONE \
  --cmd "set rtp+=$PWD" \
  -c 'lua local r=require("runner"); r.setup({focus=false,keymaps=false}); r.run("echo hi"); vim.wait(5000,function() return not r.is_running() end); print(vim.inspect(vim.api.nvim_buf_get_lines(r.buffer(),0,-1,false)))' \
  -c 'qa!'
```

Verify a parsed location and jump:

```sh
printf 'line1\nline2\nline3\n' > main.c
nvim --clean --headless -u NONE \
  --cmd "set rtp+=$PWD" \
  -c 'lua local r=require("runner"); r.setup({focus=false,keymaps=false}); r.run("printf \"main.c:2:3: error: boom\\n\""); vim.wait(5000,function() return not r.is_running() end); local l=r.locations()[2]; print(vim.inspect(l)); r.jump(l); print(vim.inspect(vim.api.nvim_win_get_cursor(0)))' \
  -c 'qa!'
```

When changing completion, set `wildmode` in an interactive session and try
Tab on both the prompt and `:RunnerRun`; completion flow differs between the
two even though both use `complete.lua`.

## Gotchas

- The runner buffer is `nofile` and `undolevels = -1`; do not write it to disk.
- `status_line` points at a special line above which streamed output is
  inserted.  If the buffer is recreated, the old status line index is stale.
- All job callbacks run through `vim.schedule()` and re-check `run.id`.
- `M.jump` must never replace the runner pane with the target file.
- Highlight extmarks use the `runner` namespace; clear it when re-rendering.
- `state.save()` is best-effort: failures are swallowed so a broken state file
  cannot break running commands.
- `setup()` tracks the global maps it installs and removes them on the next
  call only if the description still matches.  Do not remove that check, or
  repeated setup calls could delete a user's remap.
- `plugin/runner.lua` auto-calls `setup()` only when `is_setup()` is false,
  so a user config that runs before the plugin file is not overwritten.
- Keep the public API table-friendly; `M.buffer()`, `M.window()`,
  `M.locations()`, `M.is_running()`, and `M.is_setup()` are used by
  scripts/tests.
