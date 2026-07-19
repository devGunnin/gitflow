-- tests/e2e/pr_reply_spec.lua — gh/prs.lua reply_to_review_comment E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/pr_reply_spec.lua
--
-- Regression coverage: `gh api ... --field body=...` treats a leading "@" in
-- the value as a FILENAME to read (gh's documented --field vs -f semantics),
-- so a reply beginning with "@username" — the common case for review replies
-- — must reach gh as a raw (-f) field like every other call in this file.

local T = _G.T
local gh_prs = require("gitflow.gh.prs")

---@param fn fun(log_path: string)
local function with_temp_gh_log(fn)
	local log_path = vim.fn.tempname()
	local previous = vim.env.GITFLOW_GH_LOG
	vim.env.GITFLOW_GH_LOG = log_path

	local ok, err = xpcall(function()
		fn(log_path)
	end, debug.traceback)

	vim.env.GITFLOW_GH_LOG = previous
	pcall(vim.fn.delete, log_path)

	if not ok then
		error(err, 0)
	end
end

T.run_suite("E2E: PR review comment replies", {

	-- ── @-mention reply must use raw -f, not typed --field ─────────────

	["a reply starting with @mention reaches gh as a raw -f field"] = function()
		with_temp_gh_log(function(log_path)
			local err_result = nil
			gh_prs.reply_to_review_comment(
				42, 900, "@alice good catch, fixing now", {},
				function(err)
					err_result = err
				end
			)
			T.drain_jobs(3000)

			T.assert_true(
				err_result == nil,
				"reply should not error: " .. tostring(err_result)
			)

			local lines = T.read_file(log_path)
			local invocation = nil
			for _, line in ipairs(lines) do
				if line:find("comments/900/replies", 1, true) then
					invocation = line
				end
			end

			T.assert_true(
				invocation ~= nil,
				"gh log should record the reply invocation"
			)
			T.assert_contains(
				invocation,
				"-f body=@alice good catch, fixing now",
				"body must be passed via raw -f, unmangled, even with a "
					.. "leading @mention"
			)
			T.assert_true(
				not invocation:find("--field", 1, true),
				"reply must not use typed --field (it reads a leading @ "
					.. "as a filename)"
			)
		end)
	end,

	-- ── A plain reply (no leading @) still uses -f, matching the file's
	--    stated convention (every other call site in prs.lua uses -f) ──

	["a plain reply also uses raw -f like every other call in the file"] = function()
		with_temp_gh_log(function(log_path)
			gh_prs.reply_to_review_comment(
				42, 901, "sounds good", {}, function() end
			)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			local invocation = nil
			for _, line in ipairs(lines) do
				if line:find("comments/901/replies", 1, true) then
					invocation = line
				end
			end

			T.assert_true(
				invocation ~= nil,
				"gh log should record the reply invocation"
			)
			T.assert_contains(
				invocation, "-f body=sounds good",
				"reply body should be passed via raw -f"
			)
		end)
	end,
})

print("E2E PR review comment reply tests passed")
