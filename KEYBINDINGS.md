# Gitflow Keybinding Reference

Complete keybinding reference organized by context. All keybindings listed
are defaults and can be overridden through `setup()`.

## Known Conflicts

Gitflow's global keybindings (see below) are ordinary normal-mode mappings
installed in every buffer, so they can shadow a plugin or LSP mapping you
already rely on:

- **`gc` vs vim-commentary.** Gitflow binds `gc` to `commit`. vim-commentary
  (and similar comment plugins) use `gc` as a comment operator (`gcc`,
  `gc{motion}`, visual `gc`). Whichever plugin calls `setup()`/loads last wins
  the mapping. Remap gitflow's commit action to free `gc`:
  ```lua
  require("gitflow").setup({ keybindings = { commit = "<leader>gc" } })
  ```
- **`gd` vs LSP go-to-definition — not actually a conflict.** Gitflow's diff
  command is bound to `gD` (capital D), not `gd`; there is no default gitflow
  mapping on lowercase `gd`, so it does not collide with the common LSP
  `gd` = go-to-definition convention out of the box.
- If your LSP setup binds the common `gr` = references convention (bare,
  not `<leader>`-prefixed), note gitflow uses bare `gr` for `refresh`. Remap
  one side if both are active:
  ```lua
  require("gitflow").setup({ keybindings = { refresh = "<leader>gz" } })
  ```

See [Overriding Keybindings](#overriding-keybindings) below for the general
remap mechanism.

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
| `gI` | Open rebase panel (normal, `i` for interactive) | `rebase_interactive` |
| `gA` | Open GitHub Actions panel | `actions` |
| `gN` | Open notification center | `notifications` |
| `<leader>gG` | Toggle PR review mode (tabpage with file list + inline diff) | `pr_review` |

## Status Panel

Buffer-local bindings active in the status panel (`:Gitflow status`).

| Key | Action |
| --- | --- |
| `s` | Stage file under cursor (or the visual-line selection) |
| `u` | Unstage file under cursor (or the visual-line selection) |
| `a` | Stage all files |
| `A` | Unstage all files |
| `<CR>` | Open the file under cursor for editing |
| `cc` | Commit |
| `dd` | Review diff for file under cursor (opens the diff review viewer) |
| `cx` | Open conflict resolution for file |
| `p` | Push |
| `X` | Revert uncommitted changes in file |
| `r` | Refresh |
| `q` | Close |

`s` / `u` also work in visual line mode (`V` to select rows, then `s` or `u`)
to stage/unstage several files at once.

## Diff View

Buffer-local bindings active in diff buffers (`:Gitflow diff`).

| Key | Action |
| --- | --- |
| `r` | Refresh diff |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk |
| `q` | Close |

## Diff Review Viewer

A separate, richer diff surface (not the Diff View above): a tabpage with a
file-list pane on the left and a per-file diff on the right. It opens for
`dd` in the [Status Panel](#status-panel) (the working tree, or `--staged`),
and for `<CR>` / range-review in the [Log View](#log-view) (a single commit,
or a marked commit range) — no direct `:Gitflow` command opens it.

### File list pane

| Key | Action |
| --- | --- |
| `<CR>` / `o` | Open the file under cursor in the right pane |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk |
| `r` | Refresh |
| `q` | Close |

### Diff pane

| Key | Action |
| --- | --- |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk |
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
| `u` | Update branch to its upstream (fast-forward, no checkout) |
| `r` | Rename branch |
| `R` | Refresh branch list (with fetch) |
| `f` | Fetch remote branches |
| `.` | Jump to the current branch (list view only) |
| `G` | Toggle list / graph view |
| `q` | Close |

## Log View

Buffer-local bindings active in the log panel (`:Gitflow log`).

| Key | Action |
| --- | --- |
| `<CR>` | Review commit under cursor (or, with a range marked, the range) |
| `V` | Mark the commit under cursor as a range start (`<CR>` on another commit reviews the combined range); `V` on the same commit clears it |
| `<Esc>` | Cancel a pending range selection |
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
| `A` | Edit assignees |
| `f` | Open filter menu (state / labels / assignee / milestone) |
| `X` | Clear all filters |
| `s` | Cycle sort key (updated → number → title → milestone) |
| `S` | Toggle sort direction |
| `G` | Cycle grouping (none → milestone → assignee → label) |
| `<Tab>` | Fold / unfold the group under cursor (when grouped) |
| `v` | Switch to a saved view |
| `V` | Save current filters/sort as a named view |
| `D` | Delete a saved view |
| `B` | Create a branch from the selected issue (prompts, prefilled name) |
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
| `A` | Edit assignees |
| `f` | Open filter menu |
| `X` | Clear all filters |
| `s` | Cycle sort key |
| `S` | Toggle sort direction |
| `G` | Cycle grouping |
| `v` | Switch to a saved view |
| `V` | Save current filters/sort as a named view |
| `D` | Delete a saved view |
| `B` | Create a branch from this issue (prompts, prefilled name) |
| `r` | Refresh |
| `q` | Close |

`f`/`X`/`s`/`S`/`G`/`v`/`V`/`D` act on the panel's shared filter/sort/group/view
state, so they take effect from either view but only become visible once you
go back (`b`) to the list.

## PR List

Buffer-local bindings active in the PR panel (`:Gitflow pr list`).

### List View

| Key | Action |
| --- | --- |
| `<CR>` | View PR under cursor |
| `c` | Create new PR |
| `C` | Comment on PR |
| `L` | Edit labels |
| `A` | Edit assignees |
| `m` | Merge PR |
| `x` | Close PR |
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
| `A` | Edit assignees |
| `m` | Merge PR |
| `x` | Close PR |
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
| `<CR>` / `o` / `<Tab>` | Open the file under cursor in the right pane, or fold/unfold a folder row |
| `za` | Toggle the folder under the cursor |
| `zR` | Unfold all folders |
| `zM` | Fold all folders |
| `]f` / `[f` | Next / previous file |
| `]C` / `[C` | Jump to the next / previous comment thread (any file) |
| `c` | Comment on the whole file under the cursor (works for deleted files too) |
| `C` | Scope the review to a single commit or a range of commits |
| `S` | Submit review — opens dropdown (comment / request changes / approve), then prompts for an optional body |
| `<leader>c` | Comments overview — picker listing every comment thread in the PR, jump on select |
| `<leader>d` | Toggle the diff overlay: PR changes ↔ the file as it is in the branch |
| `r` | Refresh PR metadata, diff, and threads |
| `q` | Close review mode (confirms if pending comments exist) |

Files that carry review comments show a `[n]` badge (remote threads, from
any author) and `●n` for your unsubmitted drafts; collapsed folders roll
those counts up, and the **Files** header shows the total (`[threads in
files]`). Use `]C` / `[C` to walk straight through every comment.

On a draft row in the **Drafts** section: `<CR>` jumps to the comment,
`e` edits the draft body, `dd` (or `x`) deletes it, `X` deletes all off-diff
drafts. `e` on a **file row** edits any draft on that file (file-level or
line comment); if the file has more than one draft you're asked which to
edit.

### Editing pane (per-file)

| Key | Action |
| --- | --- |
| `c` | Comment on the current line. If deleted lines are shown next to the cursor row, you'll be asked whether to comment on the added/context line or one of the deleted lines (normal and visual mode) |
| `s` | Start a GitHub suggestion block for the current line (normal and visual mode) — opens the comment composer prefilled with a suggestion code fence containing the selected lines, so you can propose an actual code edit |
| `S` | Submit review (same dropdown flow as the file list) |
| `R` | Reply to the existing thread on the current line |
| `]f` / `[f` | Next / previous file (without leaving the editing pane) |
| `]c` / `[c` | Next / previous hunk |
| `]C` / `[C` | Next / previous comment thread — opens the file and jumps to the line, crossing files as needed |
| `<leader>t` | Fold / unfold the reply thread on the current line (threads with no replies are unaffected) |
| `<leader>c` | Comments overview — picker listing every comment thread in the PR, jump on select |
| `<leader>e` | Edit the draft comment on the current line |
| `<leader>x` | Delete the comment on the current line (draft, or remote if you authored it) |
| `<leader>i` | Toggle inline comment body lines (collapsed vs. expanded) |
| `<leader>d` | Toggle the diff overlay: PR changes ↔ the file as it is in the branch |

### Thread popup

Opened by `<CR>` on a commented line in the editing pane.

| Key | Action |
| --- | --- |
| `R` | Reply to the thread (remote threads only) |
| `q` / `<Esc>` | Close the popup |

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

## Rebase Panel

Buffer-local bindings active in the rebase panel (`:Gitflow rebase-interactive`).
The panel opens on a base-branch picker, then a plain (non-interactive) rebase
preview. Press `i` from the preview to switch to the interactive editor.

Base picker:

| Key | Action |
| --- | --- |
| `<CR>` | Select base branch |
| `q` | Close |

Normal rebase preview:

| Key | Action |
| --- | --- |
| `X` | Execute plain rebase onto base |
| `i` | Switch to interactive rebase |
| `P` | Toggle diff preview for commit under cursor |
| `b` | Change base branch |
| `q` | Close |

Interactive rebase editor:

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
| `X` | Execute interactive rebase |
| `P` | Toggle diff preview for commit under cursor |
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
| `1`-`9` | Run the numbered command directly (see the index shown next to the first 9 entries) |

### List (Normal Mode)

| Key | Action |
| --- | --- |
| `<CR>` | Select highlighted command |
| `j` / `<C-n>` | Move selection down |
| `k` / `<C-p>` | Move selection up |
| `1`-`9` | Run the numbered command directly |
| `q` / `<Esc>` | Close palette |

## Cross-Panel Inconsistencies

Panel-local bindings are fixed per panel (see [Overriding
Keybindings](#overriding-keybindings)), so the same key is free to mean
something different in each one. This is a known, intentional tradeoff, not a
bug — but it can catch you out if you jump between panels on muscle memory:

- **`A`** — [abort the active merge/rebase/cherry-pick](#conflict-resolution)
  (Conflict List, destructive, confirms first) / [unstage all
  files](#status-panel) (Status Panel) / [apply the stash under
  cursor](#stash-panel) (Stash Panel) / [edit assignees](#issue-list)
  (Issue List, PR List).
- **`R`** — [reset to the entry under cursor](#reflog-panel) (Reflog Panel,
  destructive, confirms first, default choice is Cancel) / refresh (Branch
  List, Conflict List — same as `r` there) / [reply to the comment thread on
  the current line](#pr-review-mode) (PR Review Mode editing pane and thread
  popup).
- **"Back to list"** — `b` (Issue List, PR List) or `<BS>` (Actions Panel),
  depending on the panel. There is no panel where `<Esc>` performs this;
  `<Esc>` is used elsewhere for unrelated things (cancelling a log-panel range
  selection, closing the command palette or a review thread popup).

Both destructive cases above (`A` = abort, `R` = reset) show a confirmation
prompt defaulting to Cancel, so an accidental press does not lose work.

This is a documentation note, not a proposal to change any binding — panel
keybindings are not currently user-configurable (see below).

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
