# Modular Issue Plan

Chronological issue breakdown for building the unified Neovim git + GitHub workflow.

## [Stage 1] Core Plugin Skeleton and Command Runtime

- Suggested title: `[Stage 1] Bootstrap plugin architecture and async command runtime`
- Goal: establish plugin structure and a reusable process layer for `git` and `gh`.
- Deliverables:
  - plugin entrypoint and setup API
  - async job runner with stdout/stderr handling
  - command abstraction for `git` and `gh` calls
  - health check for dependencies (`git`, `gh`, auth status)
- Acceptance criteria:
  - commands run without blocking UI
  - failures are surfaced with actionable messages
  - module boundaries are documented
- Dependencies: none

## [Stage 2] Git Primitive Workflows

- Suggested title: `[Stage 2] Implement core git workflows in Neovim UI`
- Goal: cover day-to-day local git actions.
- Deliverables:
  - status view (staged/unstaged/untracked)
  - stage/unstage helpers (file + hunk)
  - commit flow (message entry and validation)
  - push/pull/fetch/rebase/merge commands
  - branch switch/create/delete helpers
- Acceptance criteria:
  - core git tasks are executable without leaving Neovim
  - command outcomes refresh state immediately
- Dependencies: Stage 1

## [Stage 3] GitHub Data Layer and Sync

- Suggested title: `[Stage 3] Add GitHub integration layer and single-stroke sync`
- Goal: integrate `gh` workflows and unified refresh.
- Deliverables:
  - issue and PR list retrieval
  - labels, assignees, and metadata fetch
  - single action to sync local git + remote GitHub state
  - caching and refresh invalidation rules
- Acceptance criteria:
  - issue/PR data appears inside Neovim views
  - sync action updates both git and GitHub surfaces
- Dependencies: Stage 1, Stage 2

## [Stage 4] Issue Management Interface

- Suggested title: `[Stage 4] Build issue management UI (create, edit, label, comment)`
- Goal: support GitHub issue lifecycle from Neovim.
- Deliverables:
  - issue dashboard and filters
  - create/edit/close/reopen issue actions
  - label and assignee management
  - comment and thread reply actions
- Acceptance criteria:
  - full issue workflow works via `gh` backend
  - update operations are reflected after sync
- Dependencies: Stage 3

## [Stage 5] Pull Request and Review Workflows

- Suggested title: `[Stage 5] Build PR dashboard and review interactions`
- Goal: add complete PR lifecycle operations.
- Deliverables:
  - PR list/detail views
  - open/update PR, request reviewers, merge actions
  - diff navigator with file and hunk movement
  - inline comment, review submission, and reply support
  - approve/request changes/comment-only review modes
- Acceptance criteria:
  - PR creation and review actions map to GitHub correctly
  - diff interactions support code review parity use-cases
- Dependencies: Stage 3

## [Stage 6] Merge Conflict Center

- Suggested title: `[Stage 6] Implement merge conflict center and resolution helpers`
- Goal: streamline conflict handling inside Neovim.
- Deliverables:
  - conflict dashboard with conflicted files
  - marker navigation and choose-ours/theirs helpers
  - resolve+stage shortcuts
  - merge continuation helpers
- Acceptance criteria:
  - common merge conflicts can be resolved without shell fallback
  - conflict status and staging state stay synchronized
- Dependencies: Stage 2

## [Stage 7] UI Theme System and Visual Polish

- Suggested title: `[Stage 7] Add Neovim-native theming, highlights, and UX polish`
- Goal: deliver a traditional Neovim style with modern readability.
- Deliverables:
  - highlight groups and palette presets
  - semantic colors for status/review/conflict states
  - typography/layout tuning for dense code workflows
  - accessibility pass for contrast and color overrides
- Acceptance criteria:
  - theming is configurable and stable across views
  - color semantics remain consistent in all workflows
- Dependencies: Stage 2, Stage 5, Stage 6

## [Stage 8] Documentation, Defaults, and Hardening

- Suggested title: `[Stage 8] Finalize docs, default binds, tests, and release readiness`
- Goal: lock defaults and publish contributor-facing docs.
- Deliverables:
  - README wiki sections: config, functionality map, keybinds
  - migration notes and troubleshooting section
  - end-to-end validation checklist and automated tests
  - release checklist for first public tag
- Acceptance criteria:
  - docs match implemented behavior
  - key workflows are covered by automated tests
- Dependencies: all prior stages

