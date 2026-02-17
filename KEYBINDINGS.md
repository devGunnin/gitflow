# Gitflow Keybinding Reference

Complete keybinding reference organized by context. All keybindings listed
are defaults and can be overridden through `setup()`.

## Global

Normal-mode mappings available in any buffer. Configured via
`setup({ keybindings = { ... } })`.

| Key | Action | Config Key |
| --- | --- | --- |
| `<leader>gh` | Show help / usage | `help` |
| `<leader>go` | Open main panel | `open` |
| `<leader>gr` | Refresh current panel | `refresh` |
| `<leader>gq` | Close all Gitflow panels | `close` |
| `gs` | Open status panel | `status` |
| `gc` | Commit | `commit` |
| `gp` | Push | `push` |
| `gP` | Pull | `pull` |
| `<leader>gf` | Fetch | `fetch` |
| `gd` | Open diff view | `diff` |
| `gl` | Open log panel | `log` |
| `gS` | Open stash list | `stash` |
| `gZ` | Stash push (with prompt) | `stash_push` |
| `gX` | Stash pop | `stash_pop` |
| `<leader>gb` | Open branch list | `branch` |
| `<leader>gi` | Open issue list | `issue` |
| `<leader>gr` | Open PR list | `pr` |
| `<leader>gL` | Open label list | `label` |
| `gR` | Open reset panel | `reset` |
| `<leader>gm` | Open conflict panel | `conflict` |
| `<leader>gp` | Open command palette | `palette` |

## Status Panel

Buffer-local bindings active in the status panel (`:Gitflow status`).

| Key | Action | Action Name |
| --- | --- | --- |
| `s` | Stage file under cursor | `stage` |
| `u` | Unstage file under cursor | `unstage` |
| `a` | Stage all files | `stage_all` |
| `A` | Unstage all files | `unstage_all` |
| `cc` | Commit | `commit` |
| `dd` | Open diff for file under cursor | `diff` |
| `cx` | Open conflict resolution for file | `conflicts` |
| `p` | Push | `push` |
| `X` | Revert uncommitted changes in file | `revert` |
| `r` | Refresh | `refresh` |
| `q` | Close | `close` |

## Diff View

Buffer-local bindings active in diff buffers (`:Gitflow diff`).

| Key | Action | Action Name |
| --- | --- | --- |
| `q` | Close | `close` |
| `r` | Refresh diff | `refresh` |
| `]f` | Jump to next file | `next_file` |
| `[f` | Jump to previous file | `prev_file` |
| `]c` | Jump to next hunk | `next_hunk` |
| `[c` | Jump to previous hunk | `prev_hunk` |

## Branch List

Buffer-local bindings active in the branch panel (`:Gitflow branch`).

| Key | Action | Action Name |
| --- | --- | --- |
| `<CR>` | Switch to branch under cursor | `switch` |
| `c` | Create new branch | `create` |
| `d` | Delete branch | `delete` |
| `D` | Force delete branch | `force_delete` |
| `r` | Rename branch | `rename` |
| `R` | Refresh branch list | `refresh` |
| `f` | Fetch remote branches | `fetch` |
| `m` | Merge branch into current | `merge` |
| `G` | Toggle list/graph view | `toggle_graph` |
| `q` | Close | `close` |

## Log View

Buffer-local bindings active in the log panel (`:Gitflow log`).

| Key | Action | Action Name |
| --- | --- | --- |
| `<CR>` | Open diff for commit under cursor | `open_commit` |
| `r` | Refresh | `refresh` |
| `q` | Close | `close` |

## Reset Panel

Buffer-local bindings active in the reset panel (`:Gitflow reset`).

| Key | Action | Action Name |
| --- | --- | --- |
| `<CR>` | Select commit under cursor (prompts soft/hard) | `select` |
| `1`-`9` | Select commit by position (prompts soft/hard) | — |
| `S` | Soft reset to commit under cursor | `soft_reset` |
| `H` | Hard reset to commit under cursor | `hard_reset` |
| `r` | Refresh | `refresh` |
| `q` | Close | `close` |

## Stash Panel

Buffer-local bindings active in the stash panel (`:Gitflow stash list`).

| Key | Action | Action Name |
| --- | --- | --- |
| `P` | Pop stash entry under cursor | `pop` |
| `D` | Drop stash entry under cursor | `drop` |
| `S` | Stash with message prompt | `stash` |
| `r` | Refresh | `refresh` |
| `q` | Close | `close` |

## Issue List

Buffer-local bindings active in the issue panel (`:Gitflow issue list`).

### List View

| Key | Action | Action Name |
| --- | --- | --- |
| `<CR>` | View issue under cursor | `view` |
| `c` | Create new issue | `create` |
| `C` | Comment on issue | `comment` |
| `x` | Close issue | `close_issue` |
| `L` | Edit labels | `labels` |
| `A` | Edit assignees | `assign` |
| `r` | Refresh | `refresh` |
| `q` | Close | `close` |

### Detail View

| Key | Action | Action Name |
| --- | --- | --- |
| `b` | Back to list | `back` |
| `c` | Create new issue | `create` |
| `C` | Comment on issue | `comment` |
| `x` | Close issue | `close_issue` |
| `L` | Edit labels | `labels` |
| `A` | Edit assignees | `assign` |
| `r` | Refresh | `refresh` |
| `q` | Close | `close` |

## PR List

Buffer-local bindings active in the PR panel (`:Gitflow pr list`).

### List View

| Key | Action | Action Name |
| --- | --- | --- |
| `<CR>` | View PR under cursor | `view` |
| `c` | Create new PR | `create` |
| `C` | Comment on PR | `comment` |
| `L` | Edit labels | `labels` |
| `A` | Edit assignees | `assign` |
| `m` | Merge PR | `merge` |
| `o` | Checkout PR branch | `checkout` |
| `v` | Open review panel | `review` |
| `r` | Refresh | `refresh` |
| `q` | Close | `close` |

### Detail View

| Key | Action | Action Name |
| --- | --- | --- |
| `b` | Back to list | `back` |
| `c` | Create new PR | `create` |
| `C` | Comment on PR | `comment` |
| `L` | Edit labels | `labels` |
| `A` | Edit assignees | `assign` |
| `m` | Merge PR | `merge` |
| `o` | Checkout PR branch | `checkout` |
| `v` | Open review panel | `review` |
| `r` | Refresh | `refresh` |
| `q` | Close | `close` |

## Review View

Buffer-local bindings active in the review panel (`:Gitflow pr review`).

| Key | Action | Action Name |
| --- | --- | --- |
| `]f` | Jump to next file | `next_file` |
| `[f` | Jump to previous file | `prev_file` |
| `]c` | Jump to next hunk | `next_hunk` |
| `[c` | Jump to previous hunk | `prev_hunk` |
| `a` | Approve review | `approve` |
| `x` | Request changes | `request_changes` |
| `c` | Inline comment (normal mode) | `inline_comment` |
| `c` | Inline comment (visual mode) | `inline_comment_visual` |
| `S` | Submit pending review | `submit_review` |
| `R` | Reply to comment thread | `reply` |
| `<leader>t` | Toggle thread collapse/expand | `toggle_thread` |
| `<leader>i` | Toggle inline comment bodies | `toggle_inline` |
| `<leader>b` | Back to PR view | `back_to_pr` |
| `r` | Refresh | `refresh` |
| `q` | Close (confirms if pending) | `close` |

## Conflict Resolution

### Conflict List Panel

Buffer-local bindings in the conflict list (`:Gitflow conflicts`).

| Key | Action | Action Name |
| --- | --- | --- |
| `<CR>` | Open 3-way conflict view | `open` |
| `r` | Refresh conflict list | `refresh` |
| `R` | Refresh conflict list | `refresh_alias` |
| `C` | Continue active merge/rebase/cherry-pick | `continue` |
| `A` | Abort active operation | `abort` |
| `q` | Close | `close` |

### 3-Way Merge View

Buffer-local bindings in the merged pane of the 3-way conflict editor.

| Key | Action |
| --- | --- |
| `1` | Accept LOCAL version for current hunk |
| `2` | Accept BASE version for current hunk |
| `3` | Accept REMOTE version for current hunk |
| `a` | Resolve all hunks (prompts for side) |
| `e` | Enter manual edit mode for hunk |
| `]x` | Jump to next conflict hunk |
| `[x` | Jump to previous conflict hunk |
| `r` | Refresh merged buffer |
| `q` | Close conflict view |

## Label Panel

Buffer-local bindings active in the label panel (`:Gitflow label list`).

| Key | Action |
| --- | --- |
| `c` | Create new label |
| `d` | Delete label under cursor |
| `r` | Refresh |
| `q` | Close |

## Command Palette

Bindings active in the command palette (`:Gitflow palette`).

### Prompt (Insert/Normal Mode)

| Key | Action |
| --- | --- |
| `<CR>` | Select highlighted command |
| `<Esc>` | Close palette |
| `<Down>` / `<C-n>` / `<Tab>` / `<C-j>` | Move selection down |
| `<Up>` / `<C-p>` / `<S-Tab>` / `<C-k>` | Move selection up |

### List (Normal Mode)

| Key | Action |
| --- | --- |
| `<CR>` | Select highlighted command |
| `j` / `<C-n>` | Move selection down |
| `k` / `<C-p>` | Move selection up |
| `q` / `<Esc>` | Close palette |

## Overriding Keybindings

### Global Keybindings

Global keybindings are overridden by passing a `keybindings` table to
`setup()`. Each key in the table corresponds to an action name (listed in
the Config Key column of the Global table above).

```lua
require("gitflow").setup({
  keybindings = {
    status  = "<leader>gs",   -- remap status panel
    commit  = "<leader>gc",   -- remap commit
    push    = "<leader>gP",   -- remap push
    palette = "<leader>gx",   -- remap command palette
  },
})
```

Only the keybindings you specify are changed; all others keep their defaults.

### Panel-Local Keybindings

Panel-local keybindings are overridden via the `panel_keybindings` table.
Each key is a panel name and each value is a table mapping action names to
key sequences. Action names are listed in the "Action Name" column of each
panel table above.

```lua
require("gitflow").setup({
  panel_keybindings = {
    status = {
      stage   = "S",    -- remap stage from "s" to "S"
      unstage = "U",    -- remap unstage from "u" to "U"
    },
    branch = {
      create = "n",     -- remap create branch from "c" to "n"
    },
    review = {
      approve = "A",    -- remap approve from "a" to "A"
    },
  },
})
```

Only the action names you specify are changed; all others keep their
defaults. Validation rejects duplicate keys within the same panel
(e.g., mapping two actions to the same key).

Valid panel names: `status`, `branch`, `diff`, `review`, `conflict`,
`issues`, `prs`, `log`, `stash`, `reset`, `revert`, `cherry_pick`.
