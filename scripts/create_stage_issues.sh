#!/usr/bin/env bash

set -euo pipefail

REPO="${1:-devGunnin/gitflow}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required but not installed." >&2
  exit 1
fi

create_issue() {
  local title="$1"
  local body_file
  body_file="$(mktemp)"
  cat >"$body_file"
  gh issue create --repo "$REPO" --title "$title" --body-file "$body_file"
  rm -f "$body_file"
}

create_issue "[Stage 1] Bootstrap plugin architecture and async command runtime" <<'EOF'
Goal
- Establish plugin structure and reusable async command layer for `git` and `gh`.

Deliverables
- Setup entrypoint and module boundaries
- Async process runner (stdout/stderr, exit handling)
- Unified command wrapper for `git` and `gh`
- Dependency health check (`git`, `gh`, auth)

Acceptance Criteria
- Commands execute without blocking Neovim
- Errors include actionable context
- Architecture docs added for contributors

Dependencies
- None
EOF

create_issue "[Stage 2] Implement core git workflows in Neovim UI" <<'EOF'
Goal
- Cover daily local git actions inside Neovim.

Deliverables
- Status UI (staged/unstaged/untracked)
- Stage/unstage helpers (file + hunk)
- Commit flow with validation
- Push/pull/fetch/rebase/merge actions
- Branch create/switch/delete helpers

Acceptance Criteria
- Core git tasks run without shell fallback
- State refresh occurs after every action

Dependencies
- Stage 1
EOF

create_issue "[Stage 3] Add GitHub integration layer and single-stroke sync" <<'EOF'
Goal
- Integrate `gh` workflows and a one-keystroke sync entrypoint.

Deliverables
- Issue + PR list/data retrieval
- Labels/assignees metadata fetch
- Unified sync action for local + remote state
- Cache/refresh rules

Acceptance Criteria
- GitHub entities render in Neovim views
- Sync action reconciles local git and GitHub state

Dependencies
- Stage 1
- Stage 2
EOF

create_issue "[Stage 4] Build issue management UI (create, edit, label, comment)" <<'EOF'
Goal
- Support full issue lifecycle from Neovim.

Deliverables
- Issue dashboard and filters
- Create/edit/close/reopen actions
- Label/assignee management
- Comment/reply workflow

Acceptance Criteria
- End-to-end issue management works via `gh`
- Post-action sync shows updated state

Dependencies
- Stage 3
EOF

create_issue "[Stage 5] Build PR dashboard and review interactions" <<'EOF'
Goal
- Implement full pull request and code review workflows.

Deliverables
- PR list/detail views
- Open/update PR actions and reviewer requests
- Merge actions
- Diff navigation (file/hunk)
- Inline comments, review submit, review reply
- Review modes: approve / request changes / comment

Acceptance Criteria
- PR and review actions map correctly to GitHub
- Diff review flow is practical for daily use

Dependencies
- Stage 3
EOF

create_issue "[Stage 6] Implement merge conflict center and resolution helpers" <<'EOF'
Goal
- Resolve merge conflicts directly in Neovim.

Deliverables
- Conflicted-files dashboard
- Conflict marker navigation
- Choose-ours/theirs shortcuts
- Resolve+stage helpers
- Merge continuation helpers

Acceptance Criteria
- Typical merge conflicts can be resolved without shell commands
- Staging/conflict state remains consistent after actions

Dependencies
- Stage 2
EOF

create_issue "[Stage 7] Add Neovim-native theming, highlights, and UX polish" <<'EOF'
Goal
- Provide traditional Neovim visual style with modern clarity.

Deliverables
- Highlight groups and palette presets
- Semantic color states (status/review/conflict)
- Layout and density polish
- Accessibility checks for contrast and override support

Acceptance Criteria
- Theming is configurable and stable across all views
- Visual semantics are consistent in every workflow

Dependencies
- Stage 2
- Stage 5
- Stage 6
EOF

create_issue "[Stage 8] Finalize docs, keybind defaults, tests, and release readiness" <<'EOF'
Goal
- Harden project for initial release.

Deliverables
- README wiki sections (config/functionality/keybinds)
- Troubleshooting and migration notes
- End-to-end checklist and automated tests
- Release checklist and first-tag criteria

Acceptance Criteria
- Documentation matches implemented behavior
- High-value workflows are covered by tests

Dependencies
- Stage 1 through Stage 7
EOF

echo "Created staged issues in ${REPO}."
