# gitflow

Unified Neovim workflow for `git` and `gh`: local git primitives, GitHub workflows,
and review UI in one interface.

## Architecture

```mermaid
flowchart TB
  subgraph NV["Neovim Runtime (Lua)"]
    ENTRY["plugin/gitflow.lua<br/>Entry + command registration"]
    CORE["lua/gitflow/init.lua<br/>Setup + orchestration"]
    SUPPORT["Support modules<br/>config, commands, highlights, utils"]
    PANELS["Panel layer<br/>lua/gitflow/panels/*"]
    UI["UI primitives<br/>lua/gitflow/ui/*"]
    GITMOD["Git modules<br/>lua/gitflow/git/*"]
    GHMOD["GitHub modules<br/>lua/gitflow/gh/*"]
  end

  NVAPI["Neovim API"]
  GITCLI["git CLI"]
  GHCLI["gh CLI"]
  GHAPI["GitHub API"]

  ENTRY --> CORE
  CORE --> SUPPORT
  CORE --> PANELS
  PANELS --> UI
  PANELS --> GITMOD
  PANELS --> GHMOD
  UI -->|Lua API calls| NVAPI
  GITMOD -->|Process I/O (stdout/stderr)| GITCLI
  GHMOD -->|CLI JSON over stdout| GHCLI
  GHCLI -->|HTTPS REST/GraphQL| GHAPI
```

## Basic Configuration

Example plugin setup (lazy.nvim style):

```lua
{
  "devGunnin/gitflow",
  config = function()
    require("gitflow").setup({
      sync = {
        pull_strategy = "rebase", -- "rebase" or "merge"
      },
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
| `gp` | push current branch |
| `<leader>gP` | pull/rebase flow |
| `<leader>gf` | fetch remotes |
| `<leader>gi` | open issue dashboard |
| `<leader>gr` | open PR dashboard |
| `<leader>gv` | open review diff view |
| `<leader>gm` | open merge/conflict center |
| `<leader>gS` | sync git + gh state |
| `<leader>gp` | open command palette |

## Stage 7 Commands

| Command | Description |
| --- | --- |
| `:Gitflow sync` | Run fetch + pull (`rebase` or `merge`) + push when ahead |
| `:Gitflow palette` | Open fuzzy-searchable command palette with grouped commands |
| `:Gitflow quick-commit` | Stage all changes and commit from a single prompt |
| `:Gitflow quick-push` | Quick commit flow followed by push |

## Delivery Roadmap

Implementation is split into chronological modular stages in `ISSUES.md`.
Use `scripts/create_stage_issues.sh` to publish all staged issues to GitHub once
`gh` auth is available.
