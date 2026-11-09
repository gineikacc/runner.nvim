# runner.nvim

Run one command for your project and watch the output in a pane at the bottom
of Neovim.  When the command prints `file:line:column` locations, they become
clickable links, so you can jump straight from a compiler error to the source.

It is a small, plain-Lua plugin with no build step and no dependencies.

## What you get

- A run command saved per working directory, so each project remembers its own
  build/test command.
- Live output in a persistent bottom pane, with auto-scroll and exit status.
- Clickable error locations, also copied into Neovim's quickfix list.
- Nice highlighting for paths, line/column numbers, and severities.
- Parsing for many common tools: gcc/clang, rustc, Go, Python, tsc, eslint,
  pylint/ruff, shellcheck, CMake, make, Node stack traces, and more.
- Tab completion for program names, file paths, and previous commands.
- Optional focus stealing: choose whether the output pane takes your cursor.

## Requirements

- Neovim 0.9 or newer (0.10+ recommended).

## Installation

The plugin uses the standard Neovim layout (`lua/` plus `plugin/`), so any
normal plugin manager works.

### lazy.nvim

```lua
{
  "YOURNAME/runner.nvim",
  lazy = false,
  opts = {
    -- optional; the defaults are good
  },
}
```

Calling `setup()` is optional.  Without it, the plugin starts with its default
settings.  See [Configuration](#configuration) when you want to change them.

### vim-plug

```vim
Plug 'YOURNAME/runner.nvim'
```

Restart Neovim.  To customize, add this after `plug#end()`:

```lua
require("runner").setup({
  height = 16,
})
```

### Manual installation

Clone the repository into a directory Neovim already loads:

```sh
git clone https://github.com/YOURNAME/runner.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/runner.nvim
```

Or put it anywhere on `runtimepath` and run:

```vim
:packadd runner.nvim
```

## Quick start

1. Open a project file.
2. Set the command with `:RunnerSet` or press Alt+R (`<M-R>`).
3. Run it with `:RunnerRun` or press Alt+r (`<M-r>`).
4. Click an error, or move to it and press `<CR>`.

Example:

```vim
:RunnerSet gcc main.c -o app && ./app
```

The command is stored for the current working directory.  Start Neovim in the
project root (or use `:cd`) if you keep several projects open.

> Alt key mappings need a terminal that sends Alt/Meta combinations to
> Neovim.  If your terminal intercepts them, see
> [Configuration](#configuration) and choose different keys.

## Commands

| Command | What it does |
| --- | --- |
| `:RunnerRun` | Run the saved command, or prompt if there is none. |
| `:RunnerRun gcc main.c` | Run this command and save it. |
| `:RunnerSet` | Prompt for a command and save it. |
| `:RunnerSet make -j` | Save a command without running it. |
| `:RunnerStop` | Stop the running job. |
| `:RunnerClose` | Close the output pane. |
| `:RunnerClear` | Clear the output. |
| `:RunnerForget` | Forget the saved command for this directory. |
| `:RunnerFocus` | Toggle focus stealing. |
| `:RunnerFocus on\|off` | Set focus stealing explicitly. |
| `:RunnerInfo` | Show the command, directory, focus setting, and state file. |

## Default keymaps

| Key | Action |
| --- | --- |
| `<M-r>` | Run the saved command, or prompt for one. |
| `<M-R>` | Set/update the command. |
| `<M-f>` | Toggle whether the pane steals focus. |

While the output pane is focused:

| Key | Action |
| --- | --- |
| `<CR>` | Open the location under the cursor. |
| `<LeftMouse>` / double click | Open the clicked location. |
| `<C-n>` / `<C-p>` | Jump to the next / previous location. |
| `R` | Run the command again. |
| `<C-c>` | Stop the running job. |
| `q` | Close the pane; the job keeps running. |

## Tab completion

Press Tab while typing a command, either in the run prompt or after
`:RunnerRun` / `:RunnerSet`.

- The first word completes program names from your `PATH`.
- Later words complete file and directory paths.
- Previous commands for the current directory are suggested too.
- Paths with spaces are escaped for you.

Examples:

```vim
:RunnerSet gcc ma<Tab>          " -> gcc main.c
:RunnerRun ./scripts/te<Tab>    " -> ./scripts/test.sh
```

## Command placeholders

These are expanded just before the command runs:

| Placeholder | Value |
| --- | --- |
| `$FILE` | Absolute path of the file in the editor window. |
| `$RELFILE` | That file relative to the working directory. |
| `$DIR` | Directory containing that file. |
| `$ROOT`, `$CWD` | The runner working directory. |

Quote them if paths may contain spaces:

```vim
:RunnerSet gcc "$FILE" -o /tmp/a.out && /tmp/a.out
```

Other shell variables, such as `$HOME`, are left alone.

## Configuration

All settings are optional:

```lua
require("runner").setup({
  focus = true,       -- focus the output pane when it opens
  height = 12,        -- pane height
  follow = true,      -- keep the pane scrolled to the bottom
  quickfix = true,    -- replace quickfix with the latest run's locations
  auto_save = true,   -- write modified buffers before running
  keymaps = {
    run = "<M-r>",
    set = "<M-R>",
    toggle_focus = "<M-f>",
  },
})
```

`keymaps = false` disables all three global mappings.  You can also disable one
of them with `run = false`, `set = false`, or `toggle_focus = false`.

Focus stealing is remembered between sessions.  Change it at runtime with
`<M-f>`, `:RunnerFocus`, or `:RunnerFocus on|off`.

## How locations are found

The parser does not need an LSP or special compiler flags.  It recognises the
usual `file:line[:column]` output shapes, including:

```text
main.c:5:9: error: 'x' undeclared
src/main.rs:5:9: error[E0308]: mismatched types
  --> src/main.rs:5:9
foo.go:3:2: undefined: bar
foo.py:3:0: C0114: Missing module docstring
src/a.ts(10,5): error TS2322: ...
  File "foo.py", line 12, in <module>
script.sh: line 7: foo: command not found
script.sh:3:5: warning: ... [SC2046]
CMake Error at CMakeLists.txt:10 (project):
/path/to/file.js
  1:1  error  'foo' is defined but never used  no-unused-vars
thread 'main' panicked at src/main.rs:4:5:
    at Object.<anonymous> (/home/x/index.js:10:15)
```

Compiler columns are converted to byte offsets, so jumping still lands on the
right character in tab-indented files.

When a run produces locations, the runner replaces Neovim's quickfix list with
them.  `:cnext`, `:cprev`, and your existing quickfix workflow keep working.
A later clean run clears the stale runner quickfix list.

## Where state lives

Commands and history are stored in:

```text
stdpath("state")/runner/state.json
```

Nothing is written into your project directories.

## Development

The plugin is plain Lua.  There is no build step and no generated code.

See [`AGENTS.md`](AGENTS.md) for the architecture, completion internals, status
checklist, and headless smoke tests.

A quick command-run check:

```sh
nvim --headless -u NONE \
  --cmd 'set rtp+=/path/to/runner.nvim' \
  -c 'lua local r=require("runner"); r.setup({focus=false,keymaps=false}); r.run("echo hi"); vim.wait(5000,function() return not r.is_running() end); print(vim.inspect(vim.api.nvim_buf_get_lines(r.buffer(),0,-1,false)))' \
  -c 'qa!'
```

The module also exposes `buffer()`, `window()`, `locations()`, `is_running()`,
and `is_setup()` for scripting and tests.
