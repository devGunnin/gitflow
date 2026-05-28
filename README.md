# gitflow

Unified Git and GitHub integration for Neovim.

## Requirements

- Neovim >= 0.9
- [git](https://git-scm.com/)
- [gh](https://cli.github.com/) (GitHub CLI), authenticated

## Installation

### lazy.nvim

```lua
{
  "devGunnin/gitflow",
  config = function()
    require("gitflow").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "devGunnin/gitflow",
  config = function()
    require("gitflow").setup()
  end,
}
```

### Manual

Clone the repository into your Neovim packages directory:

```sh
git clone https://github.com/devGunnin/gitflow.git \
  ~/.local/share/nvim/site/pack/plugins/start/gitflow
```

Then add `require("gitflow").setup()` to your `init.lua`.

## Configuration

Call `setup()` with an optional configuration table. All fields are optional
and fall back to built-in defaults.

```lua
require("gitflow").setup({
  -- All values shown are defaults
  keybindings = {
    help       = "<leader>gh",
    open       = "<leader>go",
    close      = "<leader>gq",
    status     = "gs",
    commit     = "gc",
    push       = "<leader>gP",
    pull       = "<leader>gp",
    fetch      = "<leader>gf",
    diff       = "gD",
    log        = "gl",
    stash      = "gS",
    stash_push = "gZ",
    stash_pop  = "gX",
    branch     = "<leader>gb",
    issue      = "<leader>gi",
    pr         = "<leader>gr",
    label      = "<leader>gL",
    conflict   = "<leader>gm",
    palette      = "gP",
    blame        = "gB",
    blame_inline = "<leader>gB",
  },
  ui = {
    default_layout = "split",   -- "split" or "float"
    split = {
      orientation = "vertical", -- "vertical" or "horizontal"
      size = 50,
    },
    float = {
      width      = 0.8,        -- fraction of editor or absolute columns
      height     = 0.7,
      border     = "rounded",  -- none/single/double/rounded/solid/shadow
      title      = "Gitflow",
      title_pos  = "center",   -- left/center/right
      footer     = true,
      footer_pos = "center",
    },
  },
  behavior = {
    reuse_named_buffers        = true,
    close_windows_on_buffer_wipe = true,
  },
  git = {
    log = {
      count  = 50,
      format = "%h %s",
    },
  },
  sync = {
    pull_strategy = "rebase",   -- "rebase" or "merge"
  },
  quick_actions = {
    quick_commit = { "commit" },
    quick_push   = { "commit", "push" },
  },
  highlights = {},              -- { GroupName = { fg = "...", ... } }
  signs = {
    enable   = true,
    added    = "+",
    modified = "~",
    deleted  = "\u{2212}",      -- minus sign
    conflict = "!",
  },
  icons = {
    enable = true,              -- Nerd Font icons; false = ASCII fallback
  },
  inline_blame = {
    enable      = true,         -- master switch for inline blame
    auto        = false,        -- auto-show inline blame in every file buffer
    delay       = 200,          -- debounce (ms) before blaming the cursor line
    date_format = "%Y-%m-%d",   -- os.date() format for the author date
  },
})
```

### Configuration Options

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `keybindings.<action>` | `string` | see above | Normal-mode mapping for each action |
| `ui.default_layout` | `string` | `"split"` | Panel layout: `"split"` or `"float"` |
| `ui.split.orientation` | `string` | `"vertical"` | `"vertical"` or `"horizontal"` |
| `ui.split.size` | `number` | `50` | Column/row count for split panels |
| `ui.float.width` | `number` | `0.8` | Float width (0-1 = fraction, >1 = columns) |
| `ui.float.height` | `number` | `0.7` | Float height (0-1 = fraction, >1 = rows) |
| `ui.float.border` | `string` | `"rounded"` | Border style for float windows |
| `ui.float.title` | `string` | `"Gitflow"` | Default float title text |
| `ui.float.title_pos` | `string` | `"center"` | Title position: `left`/`center`/`right` |
| `ui.float.footer` | `boolean` | `true` | Show key-hint footer in floats |
| `ui.float.footer_pos` | `string` | `"center"` | Footer position: `left`/`center`/`right` |
| `behavior.reuse_named_buffers` | `boolean` | `true` | Reuse existing panel buffers by name |
| `behavior.close_windows_on_buffer_wipe` | `boolean` | `true` | Auto-close window when buffer is wiped |
| `git.log.count` | `number` | `50` | Number of commits to show in log |
| `git.log.format` | `string` | `"%h %s"` | Git log `--format` string |
| `sync.pull_strategy` | `string` | `"rebase"` | Pull strategy: `"rebase"` or `"merge"` |
| `quick_actions.quick_commit` | `list` | `{"commit"}` | Steps for `:Gitflow quick-commit` |
| `quick_actions.quick_push` | `list` | `{"commit","push"}` | Steps for `:Gitflow quick-push` |
| `highlights` | `table` | `{}` | Override highlight groups (see `:help gitflow-highlights`) |
| `signs.enable` | `boolean` | `true` | Enable sign column indicators |
| `signs.added` | `string` | `"+"` | Sign text for added lines (1-2 cells) |
| `signs.modified` | `string` | `"~"` | Sign text for modified lines |
| `signs.deleted` | `string` | `"\u{2212}"` | Sign text for deleted lines |
| `signs.conflict` | `string` | `"!"` | Sign text for conflict markers |
| `icons.enable` | `boolean` | `true` | Use Nerd Font icons; `false` = ASCII |
| `inline_blame.enable` | `boolean` | `true` | Master switch for inline blame; `false` disables `:Gitflow blame-inline` |
| `inline_blame.auto` | `boolean` | `false` | Automatically show inline blame in every file buffer |
| `inline_blame.delay` | `integer` | `200` | Debounce in ms before blaming the cursor line |
| `inline_blame.date_format` | `string` | `"%Y-%m-%d"` | `os.date()` format for the author date |

## Commands

All commands use the `:Gitflow` prefix.

### UI

| Command | Description |
| --- | --- |
| `:Gitflow help` | Show usage summary |
| `:Gitflow open` | Open the main panel |
| `:Gitflow refresh` | Refresh current panel content |
| `:Gitflow close` | Close all Gitflow panels |
| `:Gitflow palette` | Open the command palette |

### Git

| Command | Description |
| --- | --- |
| `:Gitflow status` | Open the status panel |
| `:Gitflow commit [--amend]` | Create a commit (optional amend) |
| `:Gitflow push` | Push current branch |
| `:Gitflow pull` | Pull with configured strategy |
| `:Gitflow fetch [remote]` | Fetch from remote |
| `:Gitflow sync` | Fetch + pull + push sequence |
| `:Gitflow diff [--staged] [path]` | Open diff view |
| `:Gitflow log` | Open commit log panel |
| `:Gitflow stash list` | Open stash list panel |
| `:Gitflow stash push [message]` | Stash changes with optional message |
| `:Gitflow stash pop` | Pop latest stash entry |
| `:Gitflow stash drop` | Drop latest stash entry |
| `:Gitflow stash apply [index]` | Apply stash entry |

| `:Gitflow branch` | Open branch list panel |
| `:Gitflow blame` | Open the git blame panel |
| `:Gitflow blame-inline` | Toggle inline blame on the current line |
| `:Gitflow merge <branch> [--abort]` | Merge a branch |
| `:Gitflow rebase <branch> [--abort\|--continue]` | Rebase onto a branch |
| `:Gitflow cherry-pick <commit>` | Cherry-pick a commit |
| `:Gitflow conflicts` | Open conflict resolution panel |
| `:Gitflow quick-commit` | Stage all + commit |
| `:Gitflow quick-push` | Stage all + commit + push |

### GitHub

| Command | Description |
| --- | --- |
| `:Gitflow issue list` | List repository issues |
| `:Gitflow issue view <number>` | View an issue |
| `:Gitflow issue create` | Create a new issue |
| `:Gitflow issue comment <number>` | Comment on an issue |
| `:Gitflow issue close <number>` | Close an issue |
| `:Gitflow issue reopen <number>` | Reopen an issue |
| `:Gitflow issue edit <number> [opts]` | Edit issue (title=, body=, add=, remove=) |
| `:Gitflow pr list` | List pull requests |
| `:Gitflow pr view <number>` | View a pull request |
| `:Gitflow pr create` | Create a new pull request |
| `:Gitflow pr comment <number>` | Comment on a PR |
| `:Gitflow pr merge <number>` | Merge a PR (strategy prompt) |
| `:Gitflow pr checkout <number>` | Check out a PR branch |
| `:Gitflow pr close <number>` | Close a PR |
| `:Gitflow pr review <number>` | Open review panel for a PR |
| `:Gitflow pr submit-review <number>` | Submit pending review |
| `:Gitflow pr respond <number>` | Respond to a review thread |
| `:Gitflow pr edit <number> [opts]` | Edit PR (title=, body=, add=, remove=) |
| `:Gitflow label list` | List repository labels |
| `:Gitflow label create` | Create a new label |
| `:Gitflow label delete <name>` | Delete a label |

## Default Keybindings

See [KEYBINDINGS.md](KEYBINDINGS.md) for the complete keybinding reference
organized by context, including all panel-local bindings and override
instructions.

### Global Mappings

| Key | Action |
| --- | --- |
| `<leader>gh` | Help |
| `<leader>go` | Open main panel |
| `gr` | Refresh |
| `<leader>gq` | Close panels |
| `gs` | Status panel |
| `gc` | Commit |
| `<leader>gP` | Push |
| `<leader>gp` | Pull |
| `<leader>gf` | Fetch |
| `gd` | Diff |
| `gl` | Log |
| `gS` | Stash list |
| `gZ` | Stash push |
| `gX` | Stash pop |
| `<leader>gb` | Branch list |
| `gB` | Open blame panel |
| `<leader>gB` | Toggle inline blame |
| `<leader>gi` | Issues |
| `<leader>gr` | Pull requests |
| `<leader>gL` | Labels |
| `<leader>gm` | Conflicts |
| `gP` | Command palette |
| `<leader>gG` | Toggle PR review mode |

## Statusline

The plugin provides a statusline component showing branch name, upstream
divergence, and dirty state.

```lua
-- Native statusline
vim.o.statusline = "%{%v:lua.require'gitflow'.statusline()%}"

-- lualine.nvim
require("lualine").setup({
  sections = { lualine_c = { require("gitflow").statusline } },
})
```

## Highlight Groups

Gitflow defines two kinds of highlight groups:

- **Link-based** groups (e.g. `GitflowAdded → DiffAdd`) that follow your
  colorscheme automatically.
- **Accent-colored** groups (e.g. `GitflowBorder`, `GitflowTitle`,
  `GitflowDiffFileHeader`) that use a built-in palette selected by
  `vim.o.background`:
  - dark defaults (`PALETTE_DARK`): cyan `#56B6C2`, gold `#DCA561`,
    purple `#C678DD`
  - light defaults (`PALETTE_LIGHT`): cyan `#0E7490`, gold `#B5651D`,
    purple `#A626A4`

Override any group via `setup({ highlights = { ... } })`. Each override
fully replaces that group's default:

```lua
require("gitflow").setup({
  highlights = {
    -- Change accent colors
    GitflowBorder = { fg = "#98C379" },
    GitflowTitle  = { fg = "#98C379", bold = true },
    -- Or switch accent groups to colorscheme links
    GitflowHeader = { link = "TabLineSel" },
    GitflowFooter = { link = "Comment" },
  },
})
```

See `:help gitflow-highlights` for the full group list and palette reference.

## License

MIT
