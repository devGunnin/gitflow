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
| `<leader>gI` | Open issue list | `issue` |
| `<leader>gR` | Open PR list | `pr` |
| `<leader>gL` | Open label list | `label` |
| `gR` | Open reset panel | `reset` |
| `<leader>gm` | Open conflict panel | `conflict` |
| `<leader>gp` | Open command palette | `palette` |

## Status Panel

Buffer-local bindings active in the status panel (`:Gitflow status`).

| Key | Action |
| --- | --- |
| `s` | Stage file under cursor |
| `u` | Unstage file under cursor |
| `a` | Stage all files |
| `A` | Unstage all files |
| `cc` | Commit |
| `dd` | Open diff for file under cursor |
| `cx` | Open conflict resolution for file |
| `p` | Push |
| `X` | Revert uncommitted changes in file |
| `r` | Refresh |
| `q` | Close |

## Diff View

Buffer-local bindings active in diff buffers (`:Gitflow diff`).

| Key | Action |
| --- | --- |
| `r` | Refresh diff |
| `q` | Close |

## Branch List

Buffer-local bindings active in the branch panel (`:Gitflow branch`).

| Key | Action |
| --- | --- |
| `<CR>` | Switch to branch under cursor |
| `c` | Create new branch |
| `d` | Delete branch |
| `D` | Force delete branch |
| `m` | Merge branch into current |
| `r` | Rename branch |
| `R` | Refresh branch list |
| `f` | Fetch remote branches |
| `q` | Close |

## Log View

Buffer-local bindings active in the log panel (`:Gitflow log`).

| Key | Action |
| --- | --- |
| `<CR>` | Open diff for commit under cursor |
| `r` | Refresh |
| `q` | Close |

## Reset Panel

Buffer-local bindings active in the reset panel (`:Gitflow reset`).

| Key | Action |
| --- | --- |
| `<CR>` | Select commit under cursor (prompts soft/hard) |
| `1`-`9` | Select commit by position (prompts soft/hard) |
| `S` | Soft reset to commit under cursor |
| `H` | Hard reset to commit under cursor |
| `r` | Refresh |
| `q` | Close |

## Stash Panel

Buffer-local bindings active in the stash panel (`:Gitflow stash list`).

| Key | Action |
| --- | --- |
| `P` | Pop stash entry under cursor |
| `D` | Drop stash entry under cursor |
| `S` | Stash with message prompt |
| `r` | Refresh |
| `q` | Close |

## Issue List

Buffer-local bindings active in the issue panel (`:Gitflow issue list`).

### List View

| Key | Action |
| --- | --- |
| `<CR>` | View issue under cursor |
| `c` | Create new issue |
| `C` | Comment on issue |
| `x` | Close issue |
| `L` | Edit labels |
| `r` | Refresh |
| `q` | Close |

### Detail View

| Key | Action |
| --- | --- |
| `b` | Back to list |
| `c` | Create new issue |
| `C` | Comment on issue |
| `x` | Close issue |
| `L` | Edit labels |
| `r` | Refresh |
| `q` | Close |

## PR List

Buffer-local bindings active in the PR panel (`:Gitflow pr list`).

### List View

| Key | Action |
| --- | --- |
| `<CR>` | View PR under cursor |
| `c` | Create new PR |
| `C` | Comment on PR |
| `L` | Edit labels |
| `m` | Merge PR |
| `o` | Checkout PR branch |
| `v` | Open review panel |
| `r` | Refresh |
| `q` | Close |

### Detail View

| Key | Action |
| --- | --- |
| `b` | Back to list |
| `c` | Create new PR |
| `C` | Comment on PR |
| `L` | Edit labels |
| `m` | Merge PR |
| `o` | Checkout PR branch |
| `v` | Open review panel |
| `r` | Refresh |
| `q` | Close |

## Review View

Buffer-local bindings active in the review panel (`:Gitflow pr review`).

| Key | Action |
| --- | --- |
| `]f` | Jump to next file |
| `[f` | Jump to previous file |
| `]c` | Jump to next hunk |
| `[c` | Jump to previous hunk |
| `a` | Approve review |
| `x` | Request changes |
| `c` | Inline comment on current line (normal and visual mode) |
| `S` | Submit pending review |
| `R` | Reply to comment thread |
| `<leader>t` | Toggle thread collapse/expand |
| `<leader>b` | Back to PR view |
| `r` | Refresh |
| `q` | Close (confirms if pending comments exist) |

## Conflict Resolution

### Conflict List Panel

Buffer-local bindings in the conflict list (`:Gitflow conflicts`).

| Key | Action |
| --- | --- |
| `<CR>` | Open 3-way conflict view |
| `r` | Refresh conflict list |
| `R` | Refresh conflict list |
| `C` | Continue active merge/rebase/cherry-pick |
| `A` | Abort active operation |
| `q` | Close |

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

Panel-local keybindings (status, branch, diff, etc.) are not currently
user-configurable and use the fixed mappings documented above.
