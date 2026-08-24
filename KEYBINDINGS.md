# Gitflow Keybinding Reference

Complete keybinding reference organized by context. All keybindings listed
are defaults and can be overridden through `setup()`.

## Known Conflicts

Gitflow's global keybindings are ordinary normal-mode mappings installed in
every buffer. As of v2 none of them claims a bare `g` sequence that Neovim
itself defines — `gc` (comment operator), `gr` (0.11's LSP prefix), `gs`, `gD`,
`gP`, `gV`, `gT`, `gF`, `gI` and `gN` are all left alone. See
[Migration](#migration-from-the-pre-v2-keymaps) for where each of those moved.

The bare mappings that remain — `gl` `gS` `gZ` `gX` `gB` `gW` `gC` `gA` — shadow
no built-in command, but a plugin may still want them (`gl` for gitsigns, `gS`
for splitjoin). Move or drop any of them:

```lua
require("gitflow").setup({
  keybindings = {
    log   = "<leader>gl",   -- move it
    stash = false,          -- or leave the key alone entirely
  },
})
```

`keybindings = false` installs none of the global mappings at all; see
[Opting out](#opting-out).

Inside a panel, `?` opens a scrollable list of that panel's keys, generated
from the bindings themselves. `:Gitflow help` does the same for the
`:Gitflow` subcommands and the global mappings your config installs.

## Global

Normal-mode mappings available in any buffer. Configured via
`setup({ keybindings = { ... } })`.

| Key | Action | Config Key |
| --- | --- | --- |
| `<leader>gh` | Show help / usage (scrollable buffer) | `help` |
| `<leader>go` | Open main panel | `open` |
| `<leader>gz` | Refresh current panel | `refresh` |
| `<leader>gq` | Close all Gitflow panels | `close` |
| `<leader>gs` | Open status panel | `status` |
| `<leader>gc` | Commit | `commit` |
| `<leader>gP` | Push | `push` |
| `<leader>gp` | Pull | `pull` |
| `<leader>gf` | Fetch | `fetch` |
| `<leader>gd` | Open diff view | `diff` |
| `gl` | Open log panel | `log` |
| `gS` | Open stash list | `stash` |
| `gZ` | Stash push (with prompt) | `stash_push` |
| `gX` | Stash pop | `stash_pop` |
| `<leader>gb` | Open branch list | `branch` |
| `gW` | Open worktree panel | `worktree` |
| `gB` | Toggle blame panel | `blame` |
| `<leader>gB` | Toggle inline blame on current line | `blame_inline` |
| `<leader>gi` | Open issue list | `issue` |
| `<leader>gr` | Open PR list | `pr` |
| `<leader>gL` | Open label list | `label` |
| `<leader>gR` | Open reset panel | `reset` |
| `<leader>gm` | Open conflict panel | `conflict` |
| `<leader>gx` | Open command palette | `palette` |
| `<leader>gv` | Open revert panel | `revert` |
| `<leader>gt` | Open tag list | `tag` |
| `<leader>gF` | Open reflog panel | `reflog` |
| `gC` | Open cherry-pick panel | `cherry_pick` |
| `<leader>gI` | Open rebase panel (normal, `i` for interactive) | `rebase_interactive` |
| `gA` | Open GitHub Actions panel | `actions` |
| `<leader>gn` | Open notification center | `notifications` |
| `<leader>gG` | Toggle PR review mode (tabpage with file list + inline diff) | `pr_review` |

## Status Panel

Buffer-local bindings active in the status panel (`:Gitflow status`).

<!-- keys: status -->

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
| `X` | Discard uncommitted changes in file (confirms first) |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

`s` / `u` also work in visual line mode (`V` to select rows, then `s` or `u`)
to stage/unstage several files at once.

## Diff View

Buffer-local bindings active in diff buffers (`:Gitflow diff`).

<!-- keys: diff -->

| Key | Action |
| --- | --- |
| `r` | Refresh diff |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk |
| `?` | Key help for this panel |
| `q` | Close |

## Diff Review Viewer

A separate, richer diff surface (not the Diff View above): a tabpage with a
file-list pane on the left and a per-file diff on the right. It opens for
`dd` in the [Status Panel](#status-panel) (the working tree, or `--staged`),
and for `<CR>` / range-review in the [Log View](#log-view) (a single commit,
or a marked commit range) — no direct `:Gitflow` command opens it.

<!-- keys: diffview -->

### File list pane

| Key | Action |
| --- | --- |
| `<CR>` / `o` / `<2-LeftMouse>` | Open the file under cursor in the right pane |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk |
| `r` | Refresh |
| `?` | Key help for this viewer |
| `q` | Close |

### Diff pane

| Key | Action |
| --- | --- |
| `]f` / `[f` | Next / previous file |
| `]c` / `[c` | Next / previous hunk |
| `q` | Close |

## Branch List

Buffer-local bindings active in the branch panel (`:Gitflow branch`).

<!-- keys: branch -->

| Key | Action |
| --- | --- |
| `<CR>` | Switch to branch under cursor |
| `c` | Create new branch |
| `d` | Delete branch (confirms first) |
| `D` | Force delete branch (confirms first) |
| `m` | Merge branch into current (confirms first) |
| `u` | Update branch to its upstream (fast-forward, no checkout) |
| `M` | Rename branch (`git branch -m`) |
| `f` | Fetch remote branches |
| `.` | Jump to the current branch (list view only) |
| `G` | Toggle list / graph view |
| `r` | Refresh branch list (with fetch) |
| `?` | Key help for this panel |
| `q` | Close |

## Log View

Buffer-local bindings active in the log panel (`:Gitflow log`).

<!-- keys: log -->

| Key | Action |
| --- | --- |
| `<CR>` | Review commit under cursor (or, with a range marked, the range) |
| `V` | Mark the commit under cursor as a range start (`<CR>` on another commit reviews the combined range); `V` on the same commit clears it |
| `<Esc>` | Cancel a pending range selection |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Reset Panel

Buffer-local bindings active in the reset panel (`:Gitflow reset`).

<!-- keys: reset -->

| Key | Action |
| --- | --- |
| `<CR>` | Select commit under cursor (prompts soft/hard) |
| `1-9` | Select commit by position (prompts soft/hard) |
| `S` | Soft reset to commit under cursor — keeps every change, so not a destructive verb (confirms first) |
| `H` | Hard reset to commit under cursor — **discards** everything after it (confirms first, defaults to Cancel) |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Stash Panel

Buffer-local bindings active in the stash panel (`:Gitflow stash list`).

<!-- keys: stash -->

| Key | Action |
| --- | --- |
| `A` | Apply stash entry under cursor |
| `P` | Pop stash entry under cursor |
| `D` | Drop stash entry under cursor (confirms first) |
| `S` | Stash with message prompt |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Issue List

Buffer-local bindings active in the issue panel (`:Gitflow issue list`).

<!-- keys: issues -->

### List View

| Key | Action |
| --- | --- |
| `<CR>` | View issue under cursor |
| `c` | Create new issue |
| `C` | Comment on issue |
| `E` | Edit issue title/body |
| `x` | Close issue (confirms first) |
| `L` | Edit labels |
| `A` | Edit assignees |
| `f` | Open filter menu (state / labels / assignee / milestone) |
| `F` | Clear all filters |
| `s` | Cycle sort key (updated → number → title → milestone) |
| `S` | Toggle sort direction |
| `G` | Cycle grouping (none → milestone → assignee → label) |
| `<Tab>` | Fold / unfold the group under cursor (when grouped) |
| `o` | Switch to a saved view |
| `O` | Save current filters/sort as a named view |
| `D` | Delete a saved view (confirms first) |
| `B` | Create a branch from the selected issue (prompts, prefilled name) |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

### Detail View

| Key | Action |
| --- | --- |
| `b` | Back to list |
| `c` | Create new issue |
| `C` | Comment on issue |
| `E` | Edit issue title/body |
| `x` | Close issue (confirms first) |
| `L` | Edit labels |
| `A` | Edit assignees |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

The list-only keys `f`/`F`/`s`/`S`/`G`/`<Tab>`/`o`/`O`/`D`/`B` act on the panel's shared filter/sort/group/view
the panel's shared filter/sort/group/view state and are bound in the list view
only; go back (`b`) to reach them.

## PR List

Buffer-local bindings active in the PR panel (`:Gitflow pr list`).

<!-- keys: prs -->

### List View

| Key | Action |
| --- | --- |
| `<CR>` | View PR under cursor |
| `c` | Create new PR |
| `C` | Comment on PR |
| `L` | Edit labels |
| `A` | Edit assignees |
| `m` | Merge PR (confirms first) |
| `x` | Close PR (confirms first) |
| `o` | Checkout PR branch |
| `v` | Open review panel |
| `<C-n>` | Next page |
| `<C-p>` | Previous page |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

### Detail View

| Key | Action |
| --- | --- |
| `b` | Back to list |
| `C` | Comment on PR |
| `L` | Edit labels |
| `A` | Edit assignees |
| `m` | Merge PR (confirms first) |
| `x` | Close PR (confirms first) |
| `o` | Checkout PR branch |
| `v` | Open review panel |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## PR Review Mode

PR review mode opens a dedicated tabpage with a persistent file list on
the left and a normal editing area on the right. Files opened from the
list display the actual working-tree file with inline PR diff
annotations (added lines highlighted, removed lines as virtual lines,
hunk markers).

Toggle with `<leader>gG` (or `:Gitflow pr-review`). Switch between the
file list and the editing area with the standard `<C-w>w` motion.

<!-- keys: review_files -->

### File list pane

| Key | Action |
| --- | --- |
| `<CR>` / `o` / `<Tab>` / `<2-LeftMouse>` | Open the file under cursor in the right pane, or fold/unfold a folder row |
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
| `x` | On a **Drafts** row: delete the draft under cursor (confirms first) |
| `X` | Delete all off-diff drafts (confirms first) |
| `e` | On a **Drafts** row: edit the draft; on a file row: edit a draft on that file |
| `r` | Refresh PR metadata, diff, and threads |
| `?` | Key help for review mode |
| `q` | Close review mode (confirms if pending comments exist) |

Files that carry review comments show a `[n]` badge (remote threads, from
any author) and `●n` for your unsubmitted drafts; collapsed folders roll
those counts up, and the **Files** header shows the total (`[threads in
files]`). Use `]C` / `[C` to walk straight through every comment.

On a draft row in the **Drafts** section: `<CR>` jumps to the comment,
`e` edits the draft body, `x` deletes it, `X` deletes all off-diff drafts.
`e` on a **file row** edits any draft on that file (file-level or line
comment); if the file has more than one draft you're asked which to edit.

<!-- keys: review_diff -->

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
| `<CR>` / `<leader>t` | View, or fold / unfold, the reply thread on the current line (threads with no replies are unaffected) |
| `<leader>c` | Comments overview — picker listing every comment thread in the PR, jump on select |
| `<leader>e` | Edit the draft comment on the current line |
| `<leader>x` | Delete the comment on the current line (draft, or remote if you authored it) |
| `<leader>i` | Toggle inline comment body lines (collapsed vs. expanded) |
| `<leader>d` | Toggle the diff overlay: PR changes ↔ the file as it is in the branch |
| `?` | Key help for review mode |

### Thread popup

Opened by `<CR>` on a commented line in the editing pane. Its own keys, not
part of either review key surface: `R` replies to the thread (remote threads
only), `q` / `<Esc>` closes the popup.

Pending comments are persisted to
`stdpath('data')/gitflow/review/<repo>/<pr>.json` and rehydrated when
the same PR is reopened, so a crashed editor doesn't lose drafts.

## Conflict Resolution

### Conflict List Panel

Buffer-local bindings in the conflict list (`:Gitflow conflicts`).

<!-- keys: conflict -->

| Key | Action |
| --- | --- |
| `<CR>` | Open the conflict resolver for the file under the cursor |
| `C` | Continue active merge/rebase/cherry-pick |
| `X` | Abort active operation (confirms first) |
| `r` | Refresh conflict list |
| `?` | Key help for this panel |
| `q` | Close |

### Merge Conflict Resolver

Buffer-local bindings in the single-pane conflict editor. Resolution actions
are `c`-prefixed so plain vim motions (`o`, `a`, `e`, `b`, `t`, `r`, …) keep
working while you hand-edit a hunk.

<!-- keys: conflict_resolver -->

| Key | Action |
| --- | --- |
| `co` | Take OURS (current) for the hunk |
| `ct` | Take THEIRS (incoming) for the hunk |
| `cb` | Keep BOTH sides for the hunk |
| `cB` | Take BASE version for the hunk |
| `ca` | Resolve all hunks (prompts for side) |
| `ce` | Enter manual edit mode for hunk |
| `cD` | Reset the file to its original conflicted state — discards all edits and hunk choices (confirms first) |
| `cr` | Refresh from disk |
| `]c` | Jump to next conflict hunk |
| `[c` | Jump to previous conflict hunk |
| `c?` | Key help for the resolver (`?` stays vim's reverse search — this pane is editable) |
| `q` | Save & close conflict view |

## Label Panel

Buffer-local bindings active in the label panel (`:Gitflow label list`).

<!-- keys: labels -->

| Key | Action |
| --- | --- |
| `c` | Create new label |
| `d` | Delete label under cursor (confirms first) |
| `<C-n>` | Next page |
| `<C-p>` | Previous page |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Revert Panel

Buffer-local bindings active in the revert panel (`:Gitflow revert`).

<!-- keys: revert -->

| Key | Action |
| --- | --- |
| `<CR>` | Revert commit under cursor (confirms first) |
| `1-9` | Revert commit by position (confirms first) |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Tag Panel

Buffer-local bindings active in the tag panel (`:Gitflow tag list`).

<!-- keys: tag -->

| Key | Action |
| --- | --- |
| `c` | Create tag |
| `D` | Delete local tag (confirms first) |
| `X` | Delete remote tag (confirms first) |
| `P` | Push tag to remote |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Worktree Panel

Buffer-local bindings active in the worktree panel (`:Gitflow worktree`).

<!-- keys: worktree -->

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
| `?` | Key help for this panel |
| `q` | Close |

## Blame Panel

Buffer-local bindings active in the blame panel (`:Gitflow blame`).

<!-- keys: blame -->

| Key | Action |
| --- | --- |
| `<CR>` | Open diff for commit under cursor |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Reflog Panel

Buffer-local bindings active in the reflog panel (`:Gitflow reflog`).

<!-- keys: reflog -->

| Key | Action |
| --- | --- |
| `<CR>` | Checkout entry under cursor |
| `1-9` | Select entry by position |
| `H` | Hard reset to entry under cursor (confirms first, defaults to Cancel) |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Cherry-Pick Panel

Buffer-local bindings active in the cherry-pick panel (`:Gitflow cherry-pick-panel`).

<!-- keys: cherry_pick -->

| Key | Action |
| --- | --- |
| `<CR>` | Cherry-pick commit under cursor |
| `b` | Pick source branch |
| `B` | Cherry-pick into branch |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

`1`-`9` also cherry-pick by position; they are bound but not advertised.

## Rebase Panel

Buffer-local bindings active in the rebase panel (`:Gitflow rebase-interactive`).
The panel opens on a base-branch picker, then a plain (non-interactive) rebase
preview. Press `i` from the preview to switch to the interactive editor.

<!-- keys: rebase -->

Base picker:

| Key | Action |
| --- | --- |
| `<CR>` | Select base branch |
| `q` | Close |

Normal rebase preview:

| Key | Action |
| --- | --- |
| `X` | Execute plain rebase onto base (confirms first) |
| `i` | Switch to interactive rebase |
| `P` | Toggle diff preview for commit under cursor |
| `b` | Change base branch |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

Interactive rebase editor:

| Key | Action |
| --- | --- |
| `<CR>` | Cycle action for commit under cursor |
| `p` | Set action to pick |
| `w` | Set action to reword (not `r` — `r` is refresh in every panel) |
| `e` | Set action to edit |
| `s` | Set action to squash |
| `f` | Set action to fixup |
| `d` | Set action to drop |
| `J` | Move commit down |
| `K` | Move commit up |
| `X` | Execute interactive rebase (confirms first) |
| `P` | Toggle diff preview for commit under cursor |
| `b` | Change base branch |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

Editing the plan touches nothing: `d` only marks a commit for dropping, `p`
un-marks it, and the plan is applied only by `X`, which confirms.

## Actions Panel

Buffer-local bindings active in the actions panel (`:Gitflow actions`). Keys
apply to the run under cursor in the list, or the open run in detail view;
`J`/job-scoped `l` require the cursor on a job line in detail view.

Bindings are per view — a key a view does not use is not mapped there, so
plain vim motions keep working. The log view is a text buffer and maps only
`<BS>`, `]e`, `r` and `q`.

<!-- keys: actions -->

| Key | Action | Views |
| --- | --- | --- |
| `<CR>` | View run detail (list) / dispatch the workflow under cursor (workflow list, confirms first) | list, detail, workflow list |
| `l` | View log — full run log, or the job under cursor's log in detail view | list, detail |
| `f` | Filter by workflow, status, event, or actor | list |
| `b` | Toggle branch scope: current branch / all branches | list |
| `L` | Load more runs past the current page | list |
| `W` | Open the workflow list | list |
| `R` | Rerun the run (confirms first) | list, detail |
| `F` | Rerun failed jobs only (confirms first) | list, detail |
| `J` | Rerun the job under cursor (confirms first) | detail |
| `C` | Cancel the run (confirms first) | list, detail |
| `w` | Toggle live watch — polls until the run finishes | detail |
| `]e` | Jump to the first error line | log |
| `o` | Open in browser | list, detail |
| `<BS>` | Back (log → its parent view, workflow list/detail → list) | detail, log, workflow list |
| `r` | Refresh | all |
| `?` | Key help for this panel | all |
| `q` | Close | all |

A very large log is capped at the last 20 000 lines, with the number of
omitted lines stated in the buffer, so a pathological log cannot block the
editor while it paints.

## Notifications Panel

Buffer-local bindings active in the notifications panel (`:Gitflow notifications`).

<!-- keys: notifications -->

| Key | Action |
| --- | --- |
| `<CR>` | Open context |
| `1` | Filter by error |
| `2` | Filter by warning |
| `3` | Filter by info |
| `0` | Show all |
| `c` | Clear all |
| `r` | Refresh |
| `?` | Key help for this panel |
| `q` | Close |

## Command Palette

Bindings active in the command palette (`:Gitflow palette`). The palette is a
text-entry surface, so `?` is a character you type here, not a help key — the
footer of each pane carries its keys instead.

<!-- keys: palette -->

### Prompt (Insert/Normal Mode)

| Key | Action |
| --- | --- |
| `<CR>` | Select highlighted command |
| `<Esc>` | Close palette |
| `<Down>` / `<C-n>` / `<Tab>` / `<C-j>` | Move selection down |
| `<Up>` / `<C-p>` / `<S-Tab>` / `<C-k>` | Move selection up |
| `1-9` | Run the numbered command directly (see the index shown next to the first 9 entries) |

### List (Normal Mode)

| Key | Action |
| --- | --- |
| `<CR>` | Select highlighted command |
| `j` / `<C-n>` | Move selection down |
| `k` / `<C-p>` | Move selection up |
| `1-9` | Run the numbered command directly |
| `q` / `<Esc>` | Close palette |

## Cross-Panel Key Rules

Panel keys are buffer-local, so nothing in Neovim stops the same key meaning
different things in different panels. Muscle memory does not know which buffer
it is in, so gitflow constrains itself:

- **`r` refreshes, `q` closes, `?` opens this panel's key help.** In every
  panel, without exception.
- **No key is destructive in one panel and benign in another.** The destructive
  verbs live on `d` `D` `x` `X` `H` (and `cD` in the merge resolver), and those
  keys are never a harmless action anywhere. `scripts/test_keymap_contract.lua`
  fails the build if that stops being true.
- **Every destructive verb confirms**, and declining does nothing at all — no
  partial write, no refresh, no side effect. `scripts/test_confirm_gates.lua`
  drives each gate with the answer NO and asserts the underlying git/gh call was
  never made.
- **The prompt defaults to Cancel** for anything that discards work.

Keys that legitimately differ across panels are all benign: `A` is apply
(stash) or assignees (PR/issue lists); `S` is submit, sort direction, stash
push or soft reset; `P` is pop, push or preview; `o` is open, checkout or saved
views. None of them can lose anything.

`<C-n>` / `<C-p>` page in the PR and Label lists and move the selection in
pickers. Both mean "the next one", on different things. They shadow Neovim's
own `CTRL-N` / `CTRL-P` there; `j` / `k` still move the cursor, and keeping `n`
free for `/` search-next matters more in a buffer you search.

"Back to list" is `b` (Issue List, PR List) or `<BS>` (Actions Panel). `<Esc>`
never does it — it cancels a log-panel range selection, or closes the palette
or a review thread popup.

## Migration from the pre-v2 keymaps

v2 is a **breaking change**. Everything below can be put back through
configuration.

### Global mappings

Gitflow no longer claims any bare `g` sequence that Neovim itself defines.

| Action | Old | New | Why |
| --- | --- | --- | --- |
| `refresh` | `gr` | `<leader>gz` | `gr` is Neovim 0.11's LSP prefix (`grn`/`gra`/`gri`/`grr`) |
| `status` | `gs` | `<leader>gs` | `gs` sleeps |
| `commit` | `gc` | `<leader>gc` | `gc` is the built-in comment operator |
| `diff` | `gD` | `<leader>gd` | `gD` goes to declaration |
| `palette` | `gP` | `<leader>gx` | `gP` pastes before |
| `revert` | `gV` | `<leader>gv` | `gV` avoids reselecting |
| `tag` | `gT` | `<leader>gt` | `gT` is previous tab |
| `reflog` | `gF` | `<leader>gF` | `gF` edits the file under cursor at its line |
| `rebase_interactive` | `gI` | `<leader>gI` | `gI` inserts at column 1 |
| `notifications` | `gN` | `<leader>gn` | `gN` is a search-match text object |

The bare mappings that remain (`gl` `gS` `gZ` `gX` `gB` `gW` `gC` `gA`) shadow
no built-in command. Put any old key back:

```lua
require("gitflow").setup({ keybindings = { commit = "gc", refresh = "gr" } })
```

### Panel keys

| Panel | Old | New |
| --- | --- | --- |
| Branch List | `r` rename | `M` rename — `r` is refresh |
| Branch List | `R` refresh (with fetch) | `r` refresh (with fetch) |
| Conflict List | `A` abort | `X` abort — `A` is assignees/apply elsewhere |
| Conflict List | `R` refresh alias | removed; `r` refreshes |
| Merge Resolver | `cx` reset file | `cD` reset file — `cx` opens the resolver from the status panel |
| Reflog Panel | `R` reset | `H` hard reset — matches the Reset Panel |
| Issue List | `X` clear filters | `F` clear filters — `X` is a destructive key |
| Issue List | `D` inside `o`/`O`/`D` | `D` on its own, and it now confirms |
| Rebase editor | `r` reword | `w` reword — `r` is refresh |
| PR Review file list | `dd` / `x` delete draft | `x` delete draft — `dd` is diff in the status panel |

Newly confirmed: deleting an already-merged branch (Branch List `d`), and
deleting a saved issue view (Issue List `D`).

Put a panel key back the way it was:

```lua
require("gitflow").setup({
  panel_keybindings = {
    conflict = { X = "A" },
    reflog   = { H = "R" },
  },
})
```

## Overriding Keybindings

### Global

Pass a `keybindings` table to `setup()`. Each entry is an action name (the
Config Key column of the Global table above) and the mapping to install.

```lua
require("gitflow").setup({
  keybindings = {
    status  = "<leader>gs",   -- remap status panel
    commit  = "<leader>gc",   -- remap commit
    push    = "gp",           -- remap push
  },
})
```

Only the keybindings you specify are changed; all others keep their defaults.

### Opting out

Global mappings are ordinary normal-mode mappings installed in every buffer, so
you can decline them. One action:

```lua
require("gitflow").setup({ keybindings = { commit = false } })
```

Or all of them. The `<Plug>` targets stay defined, so every action is still
reachable from a key you choose:

```lua
require("gitflow").setup({ keybindings = false })
vim.keymap.set("n", "<leader>c", "<Plug>(GitflowCommit)", { remap = true })
```

A duplicate mapping is a config error naming both actions; a disabled action
claims no key, so it cannot collide.

### Panel-local

`panel_keybindings` is keyed by the panel's registry name, then by the default
key label that panel advertises — exactly what `?` shows inside the panel and
what the tables above document. The value is the replacement key, or `false` to
unbind it.

```lua
require("gitflow").setup({
  panel_keybindings = {
    status = { X = "<leader>X" },   -- move "discard changes" out of reach
    tag    = { D = false },         -- remove "delete tag" entirely
  },
})
```

The hint bar, the float footer and the `?` overlay all follow the override, so
a panel never advertises a key it does not bind. Overriding a pair or range
entry (`s/u`, `1-9`) replaces the whole set with the single key you give. A
label that matches no key in that panel raises a warning when the panel opens,
rather than silently doing nothing.

Panel names: `status` `branch` `log` `blame` `stash` `tag` `reflog` `reset`
`revert` `cherry_pick` `rebase` `conflict` `conflict_resolver` `worktree`
`labels` `notifications` `diff` `diffview` `prs` `issues` `actions`
`review_files` `review_diff`.
