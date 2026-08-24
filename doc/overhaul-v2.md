# gitflow v2 overhaul — campaign roadmap

Full GitHub coverage (Actions insight/rerun/cancel/watch, PR + issue lifecycle)
and a UI overhaul onto one design system — clean, crisp, minimal, fast. Nine
tasks land on this integration branch in four waves; main gets one final merge
when the operator says so.

## Waves

```
wave 0   T8 test-ci-hardening        T1 ui-core
                                        |
wave 1                               T2 panel-base
                                    /      |      \
wave 2   T3 github-panels-ui   T4 review-diff-ui   T5 actions-complete
              \                                    /
wave 3         T6 pr-issue-lifecycle      T7 keymaps-discoverability
                                                |
                                          T9 pickers+palette
```

T8 and T1 run in wave 0 (independent). T2 is the wave-1 chokepoint — every
later task depends on it. T3/T4/T5 are disjoint files and run concurrently in
wave 2. T6 touches the same panel files as T3, so it must not run concurrently
with it; T7 can run alongside T6 but sequence after if the worker reports
overlap. T9 (deferred, cleanup-depth) rides after T7.

## Tasks

| Task | Scope |
|---|---|
| T1 ui-core | Collapse render APIs onto the builder, diffing `render()`, extmark spans, spacing/color token tables, retire dead render helpers |
| T2 panel-base | Extract `ui/panel.lua` (open/close/refresh, stale-request guard, keymap registry, mandatory loading/empty/error), adopt in 16 panels |
| T3 github-panels-ui | Migrate prs/issues/labels onto the panel base, stale-request guards, pagination, cached-first-paint, dedupe helpers |
| T4 review-diff-ui | Split `panels/review.lua` (3.5k lines) onto the base/components; async the two blocking `gh` calls |
| T5 actions-complete | Rerun/cancel/logs/watch/filters/pagination for GitHub Actions — the operator's headline ask |
| T6 pr-issue-lifecycle | PR checks rollup, reopen, draft toggle, auto-merge, `--delete-branch`; issue reopen, milestones, comment edit, 429 handling |
| T7 keymaps-discoverability | One verb→key registry, resolve key collisions, confirm-gate destructive verbs, generated `?` help overlay, opt-out |
| T8 test-ci-hardening | Glob-based CI stage discovery, revive rotted test scripts, lint job, one live `gh` contract test, fix draft-cache poisoning |
| T9 pickers+palette (deferred) | Unify `list_picker`/`label_picker` into one widget; put the palette on the window layer with proper nil-guards |

## Settled decisions

- Sub-PRs target `overhaul/v2` and merge there; final merge to `main` is the
  operator's call.
- Core-vim-motion keymap shadows (`gc`, `gr`, `V`) are fixed outright, with an
  opt-out and migration notes — not left colliding.
- Neovim floor: 0.11.
- GraphQL usage is minimal, scoped to review-thread resolution only.
- Standalone git-feature issues (#328, #331–#338, #379, #424) are deferred —
  out of scope for this campaign.
