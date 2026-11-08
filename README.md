# nvim-runner

A small standalone Neovim plugin that runs one **run command** and shows its
output in a persistent, clickable bottom pane.  It is inspired by the run
buffers Tsoding uses, but it parses `file:line:column` locations and can jump
straight to them.

## Features

- One run command per working directory, stored in Neovim's state directory.
- `<leader>r` runs it; if nothing is configured yet, you are prompted.
- `<leader>R` prompts for/updates the command for the current directory.
- Output pane at the bottom, live output, auto-scroll, exit status.
- Click a `file:line:col` field (or press `<CR>`) to open that location.
- The source is opened in the editor window; the run pane stays visible.
- Colour-coded file/line/column, severity (`error`, `warning`, `note`, ...),
  and message fields.
- Parses many common formats: gcc/clang, rustc, go, Python, tsc, eslint,
  pylint/ruff, shellcheck, CMake, GNU make, Node stack traces, and more.
- Also fills Neovim's quickfix list in the background, so `:cnext`, `:cprev`,
  and your existing quickfix keys work too.
- Focus stealing is on by default and can be toggled.

## Requirements

- Neovim 0.9 or newer (0.10+ recommended).

## Installation

This repository lives outside the Neovim config.  With lazy.nvim, point `dir`
at it:

```lua
-- ~/.config/nvim/lua/config/plugins/nvim-runner.lua
return {
  {
    dir = vim.fn.expand("~/code/nvim-runner"),
    name = "nvim-runner",
    lazy = false,
    opts = {
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
    },
    config = function(_, opts)
      require("nvim-runner").setup(opts)
    end,
  },
}
```

Then run `:Lazy reload nvim-runner` or restart Neovim.

## Usage

1. `:RunnerSet gcc main.c` (or `<leader>R` and type it).
2. `<leader>r` to run it.
3. Click an error line, or move to it and press `<CR>`.

The command is remembered per current working directory.  Use `:cd` or start
Neovim in the project root if you keep multiple projects open.

```vim
:RunnerRun              " run saved command, prompt if missing
:RunnerRun gcc main.c   " run and save this command
:RunnerSet              " prompt for a command
:RunnerSet make -j      " set without running
:RunnerStop             " stop the running job
:RunnerClose            " close the pane
:RunnerClear            " clear the output
:RunnerForget           " forget the saved command for this cwd
:RunnerFocus            " toggle focus stealing
:RunnerFocus on|off     " set it explicitly
:RunnerInfo             " show command/cwd/focus/state file
```

### Command placeholders

Before running, these are expanded in the command string:

| Placeholder | Value |
| --- | --- |
| `$FILE` | absolute path of the file in the editor window |
| `$RELFILE` | that file relative to the working directory |
| `$DIR` | directory of that file |
| `$ROOT`, `$CWD` | the runner working directory |

Quote them if the path may contain spaces, for example:

```vim
:RunnerSet gcc "$FILE" -o /tmp/a.out && /tmp/a.out
```

Other shell variables such as `$HOME` are left alone.

## Run pane keys

| Key | Action |
| --- | --- |
| `<CR>` | open the location under the cursor |
| `<LeftMouse>` / double click | open the clicked location |
| `<C-n>` / `<C-p>` | next / previous location |
| `R` | run the command again |
| `<C-c>` | stop the running job |
| `q` | close the pane (the job keeps running) |

Quickfix is replaced with the locations from the latest runner command (when
there is at least one location).  Existing quickfix navigation then works.

## Configuration

```lua
require("nvim-runner").setup({
  focus = true,       -- focus the run pane when it opens
  height = 12,        -- split height
  follow = true,      -- stick to the bottom while output arrives
  quickfix = true,    -- populate the quickfix list
  auto_save = true,   -- write modified buffers before running
  keymaps = {
    run = "<leader>r",
    set = "<leader>R",
    toggle_focus = "<leader>rf",
  },
  -- keymaps = false  -- disable all global mappings
})
```

`focus` can also be changed at runtime with `<leader>rf`,
`:RunnerFocus`, or `:RunnerFocus on|off`.  The setting is persisted.

## State file

Commands and history are stored in:

```
stdpath("state")/nvim-runner/state.json
```

Nothing is written into your project directories.  Prompt history is available
with Tab completion after the first command has been run in that directory.

## How locations are found

The parser is intentionally independent of LSP and compilers.  It recognises
the usual shapes, including:

```
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

Compiler display columns are converted to byte offsets, so tab-indented code
still jumps to the right character.

## Development

The plugin is plain Lua and has no build step.  A quick smoke test:

```sh
nvim --headless -u NONE \
  --cmd 'set rtp+=/home/blud/code/nvim-runner' \
  -c 'lua require("nvim-runner").setup({ focus = false })' \
  -c 'lua require("nvim-runner").run("gcc main.c")' \
  -c 'lua vim.wait(10000, function() return not require("nvim-runner").is_running() end)' \
  -c 'qa!'
```

`require("nvim-runner").buffer()`, `.window()`, `.locations()`, and
`.is_running()` are exposed for tests and scripting.
