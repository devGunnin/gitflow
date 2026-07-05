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
| `gr` | Refresh current panel | `refresh` |
| `<leader>gq` | Close all Gitflow panels | `close` |
| `gs` | Open status panel | `status` |
| `gc` | Commit | `commit` |
| `<leader>gP` | Push | `push` |
| `<leader>gp` | Pull | `pull` |
| `<leader>gf` | Fetch | `fetch` |
| `gD` | Open diff view | `diff` |
| `gl` | Open log panel | `log` |
| `gS` | Open stash list | `stash` |
| `gZ` | Stash push (with prompt) | `stash_push` |
| `gX` | Stash pop | `stash_pop` |
| `<leader>gb` | Open branch list | `branch` |
| `gW` | Open worktree panel | `worktree` |
| `<leader>gB` | Toggle inline blame on current line | `blame_inline` |
| `<leader>gi` | Open issue list | `issue` |
| `<leader>gr` | Open PR list | `pr` |
| `<leader>gL` | Open label list | `label` |
| `<leader>gR` | Open reset panel | `reset` |
| `<leader>gm` | Open conflict panel | `conflict` |
| `gP` | Open command palette | `palette` |
| `gV` | Open revert panel | `revert` |
| `gT` | Open tag list | `tag` |
| `gB` | Toggle blame panel | `blame` |
| `gF` | Open reflog panel | `reflog` |
| `gC` | Open cherry-pick panel | `cherry_pick` |
| `gI` | Open interactive rebase panel | `rebase_interactive` |
| `gA` | Open GitHub Actions panel | `actions` |
| `gN` | Open notification center | `notifications` |
| `<leader>gG` | Toggle PR review mode (tabpage with file list + inline diff) | `pr_review` |

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
| `A` | Apply stash entry under cursor |
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

## PR Review Mode

PR review mode opens a dedicated tabpage with a persistent file list on
the left and a normal editing area on the right. Files opened from the
list display the actual working-tree file with inline PR diff
annotations (added lines highlighted, removed lines as virtual lines,
hunk markers).

Toggle with `<leader>gG` (or `:Gitflow pr-review`). Switch between the
file list and the editing area with the standard `<C-w>w` motion.

### File list pane

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open the file under cursor in the right pane |
| `]f` / `[f` | Next / previous file |
| `]C` / `[C` | Jump to the next / previous comment thread (any file) |
| `c` | Comment on the whole file under the cursor (works for deleted files too) |
| `C` | Scope the review to a single commit or a range of commits |
| `S` | Submit review — opens dropdown (comment / request changes / approve), then prompts for an optional body |
| `r` | Refresh PR metadata, diff, and threads |
| `q` | Close review mode (confirms if pending comments exist) |

Files that carry review comments show a `[n]` badge (remote threads, from
any author) and `●n` for your unsubmitted drafts; collapsed folders roll
those counts up, and the **Files** header shows the total (`[threads in
files]`). Use `]C` / `[C` to walk straight through every comment.

On a draft row in the **Drafts** section: `<CR>` jumps to the comment,
`e` edits the draft body, `dd` deletes it, `X` deletes all off-diff drafts.
`e` on a **file row** edits any draft on that file (file-level or line
comment); if the file has more than one draft you're asked which to edit.

### Editing pane (per-file)

| Key | Action |
| --- | --- |
| `c` | Comment on the current line. If deleted lines are shown next to the cursor row, you'll be asked whether to comment on the added/context line or one of the deleted lines (normal and visual mode) |
| `S` | Submit review (same dropdown flow as the file list) |
| `R` | Reply to the existing thread on the current line |
| `]f` / `[f` | Next / previous file (without leaving the editing pane) |
| `]c` / `[c` | Next / previous hunk |
| `]C` / `[C` | Next / previous comment thread — opens the file and jumps to the line, crossing files as needed |
| `<leader>e` | Edit the draft comment on the current line |
| `<leader>x` | Delete the comment on the current line (draft, or remote if you authored it) |
| `<leader>i` | Toggle inline comment body lines (collapsed vs. expanded) |
| `<leader>d` | Toggle the diff overlay: PR changes ↔ the file as it is in the branch |

Pending comments are persisted to
`stdpath('data')/gitflow/review/<repo>/<pr>.json` and rehydrated when
the same PR is reopened, so a crashed editor doesn't lose drafts.

## Conflict Resolution

### Conflict List Panel

Buffer-local bindings in the conflict list (`:Gitflow conflicts`).

| Key | Action |
| --- | --- |
| `<CR>` | Open the conflict resolver for the file under the cursor |
| `r` | Refresh conflict list |
| `R` | Refresh conflict list |
| `C` | Continue active merge/rebase/cherry-pick |
| `A` | Abort active operation |
| `q` | Close |

### Merge Conflict Resolver

Buffer-local bindings in the single-pane conflict editor. Resolution actions
are `c`-prefixed so plain vim motions (`o`, `a`, `e`, `b`, `t`, `r`, …) keep
working while you hand-edit a hunk.

| Key | Action |
| --- | --- |
| `co` | Take OURS (current) for the hunk |
| `ct` | Take THEIRS (incoming) for the hunk |
| `cb` | Keep BOTH sides for the hunk |
| `cB` | Take BASE version for the hunk |
| `ca` | Resolve all hunks (prompts for side) |
| `ce` | Enter manual edit mode for hunk |
| `cx` | Reset the file to its original conflicted state (undo all edits/choices) |
| `cr` | Refresh from disk |
| `]c` | Jump to next conflict hunk |
| `[c` | Jump to previous conflict hunk |
| `q` | Save & close conflict view |

## Label Panel

Buffer-local bindings active in the label panel (`:Gitflow label list`).

| Key | Action |
| --- | --- |
| `c` | Create new label |
| `d` | Delete label under cursor |
| `r` | Refresh |
| `q` | Close |

## Revert Panel

Buffer-local bindings active in the revert panel (`:Gitflow revert`).

| Key | Action |
| --- | --- |
| `<CR>` | Revert commit under cursor |
| `1-9` | Revert commit by position |
| `r` | Refresh |
| `q` | Close |

## Tag Panel

Buffer-local bindings active in the tag panel (`:Gitflow tag list`).

| Key | Action |
| --- | --- |
| `c` | Create tag |
| `D` | Delete local tag |
| `X` | Delete remote tag |
| `P` | Push tag to remote |
| `r` | Refresh |
| `q` | Close |

## Worktree Panel

Buffer-local bindings active in the worktree panel (`:Gitflow worktree`).

| Key | Action |
| --- | --- |
| `a` | Add a worktree: prompts for a path, then a **searchable branch picker** for the base ref, then an optional new branch name (empty = check out the picked ref) |
| `d` | Remove worktree under cursor (refuses if locked — unlock or use `D`) |
| `D` | Force-remove worktree under cursor (discards changes; also removes locked) |
| `m` | Move worktree under cursor to a new path |
| `L` | Lock / unlock worktree under cursor (locking prompts for an optional reason) |
| `p` | Prune stale worktree entries |
| `<CR>` | Switch to worktree under cursor (changes cwd) |
| `r` | Refresh |
| `q` | Close |

## Blame Panel

Buffer-local bindings active in the blame panel (`:Gitflow blame`).

| Key | Action |
| --- | --- |
| `<CR>` | Open diff for commit under cursor |
| `r` | Refresh |
| `q` | Close |

## Reflog Panel

Buffer-local bindings active in the reflog panel (`:Gitflow reflog`).

| Key | Action |
| --- | --- |
| `<CR>` | Checkout entry under cursor |
| `1-9` | Select entry by position |
| `R` | Reset to entry |
| `r` | Refresh |
| `q` | Close |

## Cherry-Pick Panel

Buffer-local bindings active in the cherry-pick panel (`:Gitflow cherry-pick-panel`).

| Key | Action |
| --- | --- |
| `<CR>` | Cherry-pick commit under cursor |
| `1-9` | Cherry-pick commit by position |
| `b` | Pick source branch |
| `B` | Cherry-pick into branch |
| `r` | Refresh |
| `q` | Close |

## Interactive Rebase Panel

Buffer-local bindings active in the interactive rebase panel (`:Gitflow rebase-interactive`).

| Key | Action |
| --- | --- |
| `<CR>` | Cycle action for commit under cursor |
| `p` | Set action to pick |
| `r` | Set action to reword |
| `e` | Set action to edit |
| `s` | Set action to squash |
| `f` | Set action to fixup |
| `d` | Set action to drop |
| `J` | Move commit down |
| `K` | Move commit up |
| `X` | Execute rebase |
| `b` | Change base branch |
| `q` | Close |

## Actions Panel

Buffer-local bindings active in the actions panel (`:Gitflow actions`).

| Key | Action |
| --- | --- |
| `<CR>` | View run detail |
| `o` | Open in browser |
| `<BS>` | Back to list |
| `r` | Refresh |
| `q` | Close |

## Notifications Panel

Buffer-local bindings active in the notifications panel (`:Gitflow notifications`).

| Key | Action |
| --- | --- |
| `<CR>` | Open context |
| `1` | Filter by error |
| `2` | Filter by warning |
| `3` | Filter by info |
| `0` | Show all |
| `c` | Clear all |
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
    push    = "gp",           -- remap push
    palette = "<leader>gx",   -- remap command palette
  },
})
```

Only the keybindings you specify are changed; all others keep their defaults.

Panel-local keybindings (status, branch, diff, etc.) are not currently
user-configurable and use the fixed mappings documented above.
