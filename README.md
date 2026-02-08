# gitflow

Unified Neovim workflow for `git` and `gh`: local git primitives, GitHub workflows,
and review UI in one interface.

## Basic Configuration

Example plugin setup (lazy.nvim style):

```lua
{
  "devGunnin/gitflow",
  config = function()
    require("gitflow").setup({
      theme = "nvim",
      keymaps = "default",
      gh_sync = "on_demand", -- single keystroke sync entrypoint
    })
  end,
}
```

## Functionality Wiki

| Area | Scope |
| --- | --- |
| Git Core | `status`, `add`, `commit`, `push`, `pull`, `fetch`, `rebase`, `merge`, branch ops |
| GitHub Workflows | issues, labels, pull requests, review requests, comments, merge actions |
| Review UI | side-by-side/unified diff, file tree, hunk navigation, inline comment thread actions |
| Conflict Resolution | conflict file list, marker jump/actions, resolve+stage helpers |
| Sync | one-keystroke state refresh with `gh` + local git status reconciliation |
| Theming | Neovim-native styling with configurable highlights and palette presets |

## Default Binds

| Key | Action |
| --- | --- |
| `<leader>gs` | open unified status view |
| `<leader>ga` | stage current file/hunk |
| `<leader>gc` | commit flow |
| `<leader>gp` | push current branch |
| `<leader>gP` | pull/rebase flow |
| `<leader>gf` | fetch remotes |
| `<leader>gi` | open issue dashboard |
| `<leader>gr` | open PR dashboard |
| `<leader>gv` | open review diff view |
| `<leader>gm` | open merge/conflict center |
| `<leader>gS` | sync git + gh state |

## Delivery Roadmap

Implementation is split into chronological modular stages in `ISSUES.md`.
Use `scripts/create_stage_issues.sh` to publish all staged issues to GitHub once
`gh` auth is available.
