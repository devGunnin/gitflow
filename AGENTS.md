# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## UI rendering conventions

- Panels render via the `ui_render.builder()` chunk builder plus the shared
  helpers in `lua/gitflow/ui/components.lua`. Prefer these over ad-hoc line
  arrays so every surface shares one visual language.
- Shared state feedback lives in `components`: `loading()`/`loading_lines()`,
  `error_state()`, the enriched `empty(B, text, { icon, hint })`, and
  `hint_group()`. New highlight groups for these are in `highlights.lua`
  (`GitflowLoading*`, `GitflowState*`, `GitflowEmpty*`, `GitflowHintGroupLabel`)
  and link to standard semantic groups so they follow the user's colorscheme.
- Key hints: floats advertise keys in the window footer; splits get an in-buffer
  bar via `components.split_hint_bar(B, render_opts, pairs)`, which renders
  nothing when `ui_render.is_floating(render_opts)` is true. Keep the panel's
  required last line (e.g. status' `Current branch: <branch>`) after it.

## Testing

- Gates are the lists in `.github/workflows/e2e.yml`: every `tests/e2e/*.lua`
  spec (run with `-u tests/minimal_init.lua`) plus the enumerated
  `scripts/test_*.lua` stage tests (run with `-u NONE`). A new `scripts/`
  test only runs in CI if it is added to that `passing_stages` array.
- `scripts/test_stage3.lua` has a pre-existing failure in its branch-rename
  section and is intentionally NOT in the CI gate list — do not treat it as a
  regression signal.
- There is no `stylua.toml`; the repo hand-formats (tabs, manual line wraps) and
  is not stylua-default-clean, so match surrounding style rather than running
  `stylua --write` across files.
- Some specs assert panel text substrings (e.g. `gear_system_spec`,
  `test_stage6` check the conflict summary). When changing presentation copy,
  update those assertions to the new wording.
