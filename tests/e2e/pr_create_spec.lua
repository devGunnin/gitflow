-- tests/e2e/pr_create_spec.lua — PR creation flow E2E tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/pr_create_spec.lua
--
-- Verifies:
--   1. PR create form opens via panel keymap
--   2. Form fields match expected PR creation fields
--   3. Submission invokes gh stub with correct arguments
--   4. Success notification rendered after creation
--   5. Buffer refreshes after creation
--   6. Draft PR creation
--   7. Creation failure path (stub returns error)

local T = _G.T
local cfg = _G.TestConfig

local ui = require("gitflow.ui")
local commands = require("gitflow.commands")
local gh_prs = require("gitflow.gh.prs")
local gh_labels = require("gitflow.gh.labels")
local form = require("gitflow.ui.form")
local input = require("gitflow.ui.input")
local utils = require("gitflow.utils")
local prs_panel = require("gitflow.panels.prs")

---@param patches table[]
---@param fn fun()
local function with_temporary_patches(patches, fn)
	local originals = {}
	for index, patch in ipairs(patches) do
		originals[index] = patch.table[patch.key]
		patch.table[patch.key] = patch.value
	end

	local ok, err = xpcall(fn, debug.traceback)

	for index = #patches, 1, -1 do
		local patch = patches[index]
		patch.table[patch.key] = originals[index]
	end

	if not ok then
		error(err, 0)
	end
end

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

T.run_suite("E2E: PR Creation Flow", {

	-- ── PR panel opens and shows PR list ──────────────────────────────

	["pr panel opens with PR list from stub"] = function()
		prs_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("prs")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"prs buffer should exist after open"
		)

		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "#42") ~= nil,
			"PR list should contain PR #42 from stub"
		)
		T.assert_true(
			T.find_line(lines, "Add dark mode support") ~= nil,
			"PR list should contain PR #42 title"
		)

		T.cleanup_panels()
	end,

	-- ── PR panel has create keymap ────────────────────────────────────

	["pr panel has c keymap for create"] = function()
		prs_panel.open(cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("prs")
		T.assert_true(bufnr ~= nil, "prs buffer should exist")
		T.assert_keymaps(bufnr, { "c" })

		T.cleanup_panels()
	end,

	-- ── create_interactive opens form ─────────────────────────────────

	["create_interactive opens form with correct fields"] = function()
		local form_opened = false
		local form_fields = {}

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					form_opened = true
					form_fields = opts.fields or {}
					return {
						bufnr = nil,
						winid = nil,
						fields = form_fields,
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.state.cfg = cfg
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				form_opened,
				"create_interactive should open a form"
			)

			-- Verify expected fields
			local field_names = {}
			for _, f in ipairs(form_fields) do
				field_names[#field_names + 1] = f.key
			end

			T.assert_true(
				T.contains(field_names, "title"),
				"form should have a title field"
			)
			T.assert_true(
				T.contains(field_names, "body"),
				"form should have a body field"
			)
			T.assert_true(
				T.contains(field_names, "base"),
				"form should have a base branch field"
			)
			T.assert_true(
				T.contains(field_names, "labels"),
				"form should have a labels field"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Title field is required ───────────────────────────────────────

	["create form title field is marked required"] = function()
		local title_required = false

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					for _, f in ipairs(opts.fields or {}) do
						if f.key == "title" and f.required then
							title_required = true
						end
					end
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.state.cfg = cfg
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				title_required,
				"title field should be marked as required"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Body field is multiline ───────────────────────────────────────

	["create form body field is multiline"] = function()
		local body_multiline = false

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					for _, f in ipairs(opts.fields or {}) do
						if f.key == "body" and f.multiline then
							body_multiline = true
						end
					end
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.state.cfg = cfg
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				body_multiline,
				"body field should be marked as multiline"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Submission invokes gh pr create with correct args ─────────────

	["form submission invokes gh pr create with title and body"] = function()
		local create_called = false
		local create_input = nil

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = gh_prs,
				key = "create",
				value = function(inp, _, cb)
					create_called = true
					create_input = inp
					cb(nil, {
						url = "https://github.com/test/repo/pull/99",
					})
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					-- Immediately submit with test values
					opts.on_submit({
						title = "Test PR title",
						body = "Test PR body\nWith multiple lines",
						base = "main",
						reviewers = "user1,user2",
						labels = "bug,enhancement",
					})
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.state.cfg = cfg
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				create_called,
				"gh_prs.create should be called on form submission"
			)
			T.assert_true(
				create_input ~= nil,
				"create input should not be nil"
			)
			T.assert_equals(
				create_input.title,
				"Test PR title",
				"create input should have correct title"
			)
			T.assert_equals(
				create_input.body,
				"Test PR body\nWith multiple lines",
				"create input should have correct body"
			)
			T.assert_equals(
				create_input.base,
				"main",
				"create input should have correct base branch"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Submission passes labels and reviewers ────────────────────────

	["form submission passes parsed labels and reviewers"] = function()
		local create_input = nil

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = gh_prs,
				key = "create",
				value = function(inp, _, cb)
					create_input = inp
					cb(nil, { url = "https://example.com/pull/1" })
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					opts.on_submit({
						title = "Labeled PR",
						body = "",
						base = "",
						reviewers = "alice, bob",
						labels = "bug, docs",
					})
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.state.cfg = cfg
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				create_input ~= nil,
				"create input should not be nil"
			)
			T.assert_deep_equals(
				create_input.reviewers,
				{ "alice", "bob" },
				"reviewers should be parsed as list"
			)
			T.assert_deep_equals(
				create_input.labels,
				{ "bug", "docs" },
				"labels should be parsed as list"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Success notification after creation ───────────────────────────

	["success notification rendered after PR creation"] = function()
		local notified_message = nil

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = gh_prs,
				key = "create",
				value = function(_, _, cb)
					cb(nil, {
						url = "https://github.com/test/repo/pull/50",
					})
				end,
			},
			{
				table = utils,
				key = "notify",
				value = function(msg)
					notified_message = msg
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					opts.on_submit({
						title = "Notify test",
						body = "",
						base = "",
						reviewers = "",
						labels = "",
					})
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.state.cfg = cfg
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				notified_message ~= nil,
				"a notification should be sent after creation"
			)
			T.assert_contains(
				notified_message,
				"pull/50",
				"notification should contain the PR URL"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Creation failure shows error notification ─────────────────────

	["creation failure shows error notification"] = function()
		local error_msg = nil
		local error_level = nil

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = gh_prs,
				key = "create",
				value = function(_, _, cb)
					cb("gh pr create failed: permission denied")
				end,
			},
			{
				table = utils,
				key = "notify",
				value = function(msg, level)
					error_msg = msg
					error_level = level
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					opts.on_submit({
						title = "Fail test",
						body = "",
						base = "",
						reviewers = "",
						labels = "",
					})
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.state.cfg = cfg
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				error_msg ~= nil,
				"error notification should be sent on failure"
			)
			T.assert_contains(
				error_msg,
				"permission denied",
				"error should contain the failure message"
			)
			T.assert_equals(
				error_level,
				vim.log.levels.ERROR,
				"error should be at ERROR level"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── gh pr create API call via stub logs invocation ─────────────────

	["gh stub invoked with correct pr create arguments"] = function()
		with_temp_gh_log(function(log_path)
			prs_panel.state.cfg = cfg

			with_temporary_patches({
				{
					table = gh_labels,
					key = "list",
					value = function(_, cb)
						cb(nil, {})
					end,
				},
				{
					table = form,
					key = "open",
					value = function(opts)
						opts.on_submit({
							title = "Logged PR",
							body = "Body text",
							base = "develop",
							reviewers = "",
							labels = "",
						})
						return {
							bufnr = nil,
							winid = nil,
							fields = opts.fields or {},
							field_lines = {},
							on_submit = opts.on_submit,
							active_field = 1,
						}
					end,
				},
			}, function()
				prs_panel.create_interactive()
				T.drain_jobs(3000)

				local lines = T.read_file(log_path)
				local found_create = false
				local found_title = false
				local found_base = false
				for _, line in ipairs(lines) do
					if line:find("pr create", 1, true) then
						found_create = true
					end
					if line:find("Logged PR", 1, true) then
						found_title = true
					end
					if line:find("develop", 1, true) then
						found_base = true
					end
				end

				T.assert_true(
					found_create,
					"gh log should contain 'pr create'"
				)
				T.assert_true(
					found_title,
					"gh log should contain the PR title"
				)
				T.assert_true(
					found_base,
					"gh log should contain the base branch"
				)
			end)
		end)

		T.cleanup_panels()
	end,

	-- ── Draft PR creation ─────────────────────────────────────────────

	["draft PR creation passes --draft flag"] = function()
		with_temp_gh_log(function(log_path)
			gh_prs.create({
				title = "Draft PR",
				body = "WIP changes",
				draft = true,
			}, {}, function(err)
				T.assert_true(
					err == nil,
					"draft PR create should not error: "
						.. tostring(err)
				)
			end)
			T.drain_jobs(3000)

			local lines = T.read_file(log_path)
			local found_draft = false
			for _, line in ipairs(lines) do
				if line:find("--draft", 1, true) then
					found_draft = true
				end
			end

			T.assert_true(
				found_draft,
				"gh log should contain --draft flag"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── PR create via :Gitflow pr create command dispatch ─────────────

	["pr create dispatches without crash"] = function()
		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					-- Cancel immediately to avoid dangling state
					if opts.on_cancel then
						opts.on_cancel()
					end
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			local ok, err = T.pcall_message(function()
				commands.dispatch({ "pr", "create" }, cfg)
			end)
			T.drain_jobs(3000)

			T.assert_true(
				ok,
				"pr create dispatch should not crash: "
					.. (err or "")
			)
		end)

		T.cleanup_panels()
	end,

	-- ── Label fetch failure still opens form ──────────────────────────

	["label fetch failure still opens form with empty labels"] = function()
		local form_opened = false

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb("network error")
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					form_opened = true
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.state.cfg = cfg
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				form_opened,
				"form should open even when label fetch fails"
			)
		end)

		T.cleanup_panels()
	end,

	-- ── PR panel view mode renders detail ─────────────────────────────

	["pr panel view mode renders PR details"] = function()
		prs_panel.open_view(42, cfg)
		T.drain_jobs(3000)

		local bufnr = ui.buffer.get("prs")
		T.assert_true(
			bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr),
			"prs buffer should exist in view mode"
		)

		local lines = T.buf_lines(bufnr)
		T.assert_true(
			T.find_line(lines, "PR #42") ~= nil,
			"view should show PR number"
		)
		T.assert_true(
			T.find_line(lines, "Add dark mode support") ~= nil,
			"view should show PR title"
		)
		T.assert_true(
			T.find_line(lines, "octocat") ~= nil,
			"view should show PR author"
		)
		T.assert_true(
			T.find_line(lines, "Body") ~= nil,
			"view should show Body section"
		)

		T.cleanup_panels()
	end,

	-- ── Buffer updates after creation ─────────────────────────────────

	["buffer refreshes to list mode after PR creation"] = function()
		local refreshed = false

		with_temporary_patches({
			{
				table = gh_labels,
				key = "list",
				value = function(_, cb)
					cb(nil, {})
				end,
			},
			{
				table = gh_prs,
				key = "create",
				value = function(_, _, cb)
					cb(nil, {
						url = "https://github.com/test/repo/pull/55",
					})
				end,
			},
			{
				table = gh_prs,
				key = "list",
				value = function(_, _, cb)
					refreshed = true
					cb(nil, {
						{
							number = 55,
							title = "New PR",
							state = "OPEN",
							headRefName = "feat",
							baseRefName = "main",
						},
					})
				end,
			},
			{
				table = form,
				key = "open",
				value = function(opts)
					opts.on_submit({
						title = "New PR",
						body = "",
						base = "",
						reviewers = "",
						labels = "",
					})
					return {
						bufnr = nil,
						winid = nil,
						fields = opts.fields or {},
						field_lines = {},
						on_submit = opts.on_submit,
						active_field = 1,
					}
				end,
			},
		}, function()
			prs_panel.open(cfg)
			T.drain_jobs(3000)
			prs_panel.create_interactive()
			T.drain_jobs(3000)

			T.assert_true(
				refreshed,
				"PR list should refresh after successful creation"
			)
		end)

		T.cleanup_panels()
	end,
})

print("E2E PR creation flow tests passed")
