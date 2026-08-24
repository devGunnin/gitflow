-- .luacheckrc — lint config for gitflow.nvim (added by the T8 CI-hardening task)
std = "max"
globals = { "vim" }

-- Callback-heavy async code (git/gh exit handlers, panel event listeners,
-- command dispatch) keeps a fixed parameter list even when a given callback
-- ignores part of it; this repo has no underscore-prefix convention for
-- that, so flagging it is noise, not signal.
unused_args = false

-- tests/minimal_init.lua exposes tests/helpers.lua as the global `T` for
-- every e2e spec to share.
files["tests/e2e/"] = { globals = { "vim", "T" } }
files["tests/e2e_smoke_test.lua"] = { globals = { "vim", "T" } }
