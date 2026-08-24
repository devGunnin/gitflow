-- scripts/test_review_modules.lua — per-module contracts for the split
-- gitflow.review.* units.
--
-- panels/review.lua used to be one 3,480-line module, so everything about it
-- could only be tested through a whole open review tabpage. These are the
-- units that came out of it, tested on their own:
--   * state    the model's reset, draft scoping and diff-line resolution
--   * tree     the file list's directory model
--   * keymaps  the single key declaration behind both key surfaces
--   * threads  folding GitHub's flat comment list, and comment ordering
--   * file_list  what the pane actually paints
--
-- Run: nvim --headless -u NONE -l scripts/test_review_modules.lua

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local passed, failed = 0, 0

---@param name string
---@param fn fun()
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("  PASS: " .. name)
	else
		failed = failed + 1
		print("  FAIL: " .. name .. " — " .. tostring(err))
	end
end

local function assert_true(condition, message)
	if not condition then
		error(message, 2)
	end
end

local function assert_equals(actual, expected, message)
	if actual ~= expected then
		error(("%s (expected=%s, actual=%s)"):format(
			message, vim.inspect(expected), vim.inspect(actual)), 2)
	end
end

local panel = require("gitflow.ui.panel")
local rstate = require("gitflow.review.state")
local tree = require("gitflow.review.tree")
local keymaps = require("gitflow.review.keymaps")
local threads = require("gitflow.review.threads")
local file_list = require("gitflow.review.file_list")
local state = rstate.state

---A two-hunk file diff: new-side lines 10-11, old-side line 20 deleted.
---@return table
local function sample_file_diff(path)
	return {
		path = path,
		status = "M",
		hunks = {
			{
				header = "@@ -18,3 +9,3 @@",
				lines = {
					{ kind = "ctx", old_line = 19, new_line = 10, text = "keep" },
					{ kind = "del", old_line = 20, new_line = nil, text = "gone" },
					{ kind = "add", old_line = nil, new_line = 11, text = "added" },
				},
			},
		},
	}
end

-- ── state ──────────────────────────────────────────────────────────────

test("state: reset clears the model but leaves the panel's fields alone", function()
	state.pr_number = 7
	state.files = { { path = "a.lua", status = "M" } }
	state.pending_comments = { { id = 1, path = "a.lua", body = "hi" } }
	state.collapsed_dirs = { lua = true }
	state.bufnr = 4242
	state.request_id = 9

	rstate.reset()

	assert_equals(state.pr_number, nil, "pr_number should be cleared")
	assert_equals(#state.files, 0, "files should be emptied")
	assert_equals(#state.pending_comments, 0, "drafts should be emptied")
	assert_equals(next(state.collapsed_dirs), nil, "folds should be forgotten")
	-- The panel base owns these: a request generation that reset to 0 would
	-- let a response from the review we just closed match the next one.
	assert_equals(state.bufnr, 4242, "reset must not touch the panel's buffer")
	assert_equals(state.request_id, 9, "reset must not rewind the generation")
	state.bufnr = nil
end)

test("state: diff_has_line resolves each side against the PR diff", function()
	rstate.reset()
	state.file_diffs = { ["a.lua"] = sample_file_diff("a.lua") }

	assert_true(rstate.diff_has_line("a.lua", 11, "RIGHT"), "added line is on RIGHT")
	assert_true(rstate.diff_has_line("a.lua", 20, "LEFT"), "deleted line is on LEFT")
	assert_true(not rstate.diff_has_line("a.lua", 20, "RIGHT"),
		"a deleted line is not on the new side")
	assert_true(not rstate.diff_has_line("a.lua", 999, "RIGHT"),
		"a line outside every hunk is off-diff")
	assert_true(not rstate.diff_has_line("missing.lua", 11, "RIGHT"),
		"a file with no diff resolves nothing")
	assert_true(not rstate.diff_has_line("a.lua", nil, "RIGHT"),
		"a nil line resolves nothing")
end)

test("state: draft_in_scope flags exactly the drafts GitHub would reject", function()
	rstate.reset()
	state.file_diffs = { ["a.lua"] = sample_file_diff("a.lua") }

	assert_true(rstate.draft_in_scope({ path = "a.lua", file_level = true }),
		"a file-level draft has no line to resolve")
	assert_true(rstate.draft_in_scope({ path = "a.lua", new_line = 11 }),
		"a draft on an added line is in scope")
	assert_true(rstate.draft_in_scope({ path = "a.lua", old_line = 20 }),
		"a draft on a deleted line is in scope")
	assert_true(not rstate.draft_in_scope({ path = "a.lua", new_line = 999 }),
		"a draft off the diff is out of scope")
	assert_true(not rstate.draft_in_scope({ path = "a.lua" }),
		"a draft with no anchor at all is out of scope")
end)

test("state: next_pending_id never reuses a live draft id", function()
	rstate.reset()
	assert_equals(rstate.next_pending_id(), 1, "the first draft is #1")
	state.pending_comments = { { id = 1 }, { id = 7 }, { id = 3 } }
	assert_equals(rstate.next_pending_id(), 8, "ids continue past the highest")
end)

-- ── tree ───────────────────────────────────────────────────────────────

local TREE_FILES = {
	{ path = "lua/gitflow/panels/review.lua", status = "M" },
	{ path = "lua/gitflow/review/state.lua", status = "A" },
	{ path = "README.md", status = "M" },
}

test("tree: build nests directories and keeps the file-list index", function()
	local root = tree.build(TREE_FILES)
	assert_equals(#root.files, 1, "README.md is a root leaf")
	assert_equals(root.files[1].idx, 3, "leaves carry their state.files index")
	assert_equals(#root.dir_order, 1, "only lua/ is a root directory")
	local panels = root.dirs.lua.dirs.gitflow.dirs.panels
	assert_equals(panels.files[1].name, "review.lua", "leaf keeps its basename")
end)

test("tree: leaf_count sums the whole subtree", function()
	local root = tree.build(TREE_FILES)
	assert_equals(tree.leaf_count(root), 3, "every file is counted once")
	assert_equals(tree.leaf_count(root.dirs.lua), 2, "lua/ holds two files")
end)

test("tree: comment_totals rolls counts up to a folded folder", function()
	local root = tree.build(TREE_FILES)
	local threads_by_path = { ["lua/gitflow/panels/review.lua"] = 2 }
	local pending_by_path = { ["lua/gitflow/review/state.lua"] = 1, ["README.md"] = 4 }
	local t, p = tree.comment_totals(root.dirs.lua, threads_by_path, pending_by_path)
	assert_equals(t, 2, "threads under lua/ are summed")
	assert_equals(p, 1, "drafts outside lua/ are not counted")
end)

test("tree: counts_by_path counts drafts and threads per file", function()
	rstate.reset()
	state.pending_comments = {
		{ path = "a.lua" }, { path = "a.lua" }, { path = "b.lua" },
	}
	state.comment_threads = { { path = "b.lua" } }
	local pending, threads_by_path = tree.counts_by_path()
	assert_equals(pending["a.lua"], 2, "two drafts on a.lua")
	assert_equals(threads_by_path["b.lua"], 1, "one thread on b.lua")
	assert_equals(threads_by_path["a.lua"], nil, "no thread on a.lua")
end)

-- ── keymaps ────────────────────────────────────────────────────────────

for _, surface in ipairs({ "list", "diff" }) do
	local entries = keymaps.for_surface(surface)

	test(("keymaps: the %s surface binds every key it advertises"):format(
		surface
	), function()
		assert_true(#entries > 0, "the surface should declare keys")
		local bound = {}
		for _, entry in ipairs(entries) do
			if entry.bind ~= false then
				for _, key in ipairs(panel.bound_keys(entry)) do
					bound[(entry.mode or "n") .. " " .. key] = true
				end
			end
		end
		for _, entry in ipairs(entries) do
			if entry.desc then
				for _, key in ipairs(panel.bound_keys(entry)) do
					assert_true(
						bound[(entry.mode or "n") .. " " .. key] ~= nil,
						("%s advertises %s but never binds %s"):format(
							surface, entry.key, key)
					)
				end
			end
		end
	end)

	test(("keymaps: the %s surface binds each key once"):format(surface), function()
		local seen = {}
		for _, entry in ipairs(entries) do
			if entry.bind ~= false then
				for _, key in ipairs(panel.bound_keys(entry)) do
					local id = (entry.mode or "n") .. " " .. key
					assert_true(seen[id] == nil, ("%s binds %s twice — the "
						.. "second handler would silently shadow the first")
						:format(surface, id))
					seen[id] = true
				end
			end
		end
	end)

	test(("keymaps: every %s entry carries an action"):format(surface), function()
		for _, entry in ipairs(entries) do
			assert_true(type(entry.run) == "function",
				("%s: %s has no action"):format(surface, tostring(entry.key)))
		end
	end)
end

test("keymaps: the legend advertises only declared keys, without repeats", function()
	local declared = {}
	for _, surface in ipairs({ "list", "diff" }) do
		for _, entry in ipairs(keymaps.for_surface(surface)) do
			if entry.desc then
				declared[entry.key .. "\0" .. entry.desc] = true
			end
		end
	end

	local groups = {}
	for _, group in ipairs(keymaps.GROUPS) do
		groups[#groups + 1] = group.id
	end
	groups[#groups + 1] = keymaps.SESSION_GROUP

	local total, seen = 0, {}
	for _, group in ipairs(groups) do
		local hints = keymaps.hints_for_group(group)
		assert_true(#hints > 0, ("group %s advertises nothing"):format(group))
		for _, hint in ipairs(hints) do
			local id = hint[1] .. "\0" .. hint[2]
			assert_true(declared[id] ~= nil,
				("the legend advertises %q, which no surface declares"):format(
					hint[1]))
			assert_true(seen[id] == nil,
				("%q is advertised twice in the legend"):format(hint[1]))
			seen[id] = true
			total = total + 1
		end
	end
	assert_true(total >= 15, "the legend should cover the review's verbs")
end)

test("keymaps: panel.new accepts both surfaces", function()
	-- The base asserts its own invariants (essential and destructive are
	-- mutually exclusive); building a panel from each surface is what runs them.
	for _, surface in ipairs({ "list", "diff" }) do
		local built = panel.new({
			name = "review_keymap_probe_" .. surface,
			title = "probe",
			state = {},
			keymaps = keymaps.for_surface(surface),
		})
		assert_true(#built:hints() >= 0, "hints should be derivable")
	end
end)

-- ── threads ────────────────────────────────────────────────────────────

test("threads: build attaches a reply to its thread", function()
	local built = threads.build({
		{ id = 1, path = "a.lua", line = 10, body = "root", user = { login = "ann" } },
		{ id = 2, path = "a.lua", line = 10, body = "reply", user = { login = "bob" },
			in_reply_to_id = 1 },
	})
	assert_equals(#built, 1, "a reply does not start a thread")
	assert_equals(#built[1].comments, 2, "the reply joins the root's thread")
	assert_equals(built[1].comments[2].user, "bob", "the reply keeps its author")
end)

test("threads: a reply to a reply lands in the same thread", function()
	local built = threads.build({
		{ id = 1, path = "a.lua", line = 10, body = "root", user = { login = "ann" } },
		{ id = 2, body = "reply", user = { login = "bob" }, in_reply_to_id = 1 },
		{ id = 3, body = "reply2", user = { login = "cat" }, in_reply_to_id = 2 },
	})
	assert_equals(#built, 1, "the chain stays one thread")
	assert_equals(#built[1].comments, 3, "every comment is kept")
end)

test("threads: a reply whose parent was never seen still shows up", function()
	local built = threads.build({
		{ id = 5, path = "a.lua", line = 10, body = "orphan",
			user = { login = "ann" }, in_reply_to_id = 999 },
	})
	assert_equals(#built, 1, "an orphaned reply starts its own thread")
	assert_equals(built[1].comments[1].body, "orphan", "it is never dropped")
end)

test("threads: line falls back to original_line", function()
	local built = threads.build({
		{ id = 1, path = "a.lua", original_line = 42, body = "b", user = "ann" },
	})
	assert_equals(built[1].line, 42, "an outdated comment keeps its anchor")
end)

test("threads: comments_for_path folds replies out only when expanded", function()
	rstate.reset()
	state.comment_threads = threads.build({
		{ id = 1, path = "a.lua", line = 10, body = "root", user = { login = "ann" } },
		{ id = 2, body = "reply", user = { login = "bob" }, in_reply_to_id = 1 },
	})

	local collapsed = threads.comments_for_path("a.lua")
	assert_equals(#collapsed, 1, "one box per thread")
	assert_equals(#collapsed[1].replies, 0, "a folded thread hands over no replies")
	assert_equals(collapsed[1].count, 2, "but still reports the reply count")

	state.expanded_threads[1] = true
	local expanded = threads.comments_for_path("a.lua")
	assert_equals(#expanded[1].replies, 1, "an unfolded thread hands them over")
end)

test("threads: comments_for_path includes local drafts, marked pending", function()
	rstate.reset()
	state.pending_comments = { { id = 1, path = "a.lua", body = "draft", new_line = 3 } }
	local out = threads.comments_for_path("a.lua")
	assert_equals(#out, 1, "the draft is projected")
	assert_true(out[1].pending, "and is marked as unsubmitted")
	assert_equals(#threads.comments_for_path("b.lua"), 0, "other files are untouched")
end)

test("threads: anchors are ordered by file-list order then line", function()
	rstate.reset()
	state.files = { { path = "b.lua" }, { path = "a.lua" } }
	state.comment_threads = threads.build({
		{ id = 1, path = "a.lua", line = 5, body = "on a", user = "ann" },
		{ id = 2, path = "b.lua", line = 9, body = "on b late", user = "ann" },
		{ id = 3, path = "b.lua", line = 2, body = "on b early", user = "ann" },
	})
	local anchors = threads.collect_anchors()
	assert_equals(#anchors, 3, "every thread is an anchor")
	assert_equals(anchors[1].path .. anchors[1].line, "b.lua2", "b.lua comes first")
	assert_equals(anchors[2].path .. anchors[2].line, "b.lua9", "then its later line")
	assert_equals(anchors[3].path, "a.lua", "a.lua is second in the file list")
end)

test("threads: a file-level draft is still reachable, at the file's top", function()
	rstate.reset()
	state.files = { { path = "a.lua" } }
	state.pending_comments = {
		{ id = 1, path = "a.lua", body = "whole file", file_level = true },
	}
	local anchors = threads.collect_anchors()
	assert_equals(#anchors, 1, "the file-level draft is an anchor")
	assert_equals(anchors[1].line, 1, "listed at the top of its file")
end)

-- ── file_list ──────────────────────────────────────────────────────────

---Attach the pane to a scratch buffer in the current window, run `fn`, and
---always detach: the panel's buffer/window are real state.
---@param fn fun(bufnr: integer)
local function with_pane(fn)
	local bufnr = vim.api.nvim_create_buf(false, true)
	local winid = vim.api.nvim_get_current_win()
	local previous = vim.api.nvim_win_get_buf(winid)
	vim.api.nvim_win_set_buf(winid, bufnr)
	file_list.attach(bufnr, winid, require("gitflow.config").get())
	local ok, err = pcall(fn, bufnr)
	file_list.detach()
	pcall(vim.api.nvim_win_set_buf, winid, previous)
	pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	if not ok then
		error(err, 0)
	end
end

---@param bufnr integer
---@return string
local function pane_text(bufnr)
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

test("file_list: renders the PR header, the tree and the legend", function()
	rstate.reset()
	state.pr_number = 12
	state.pr_title = "Make it good"
	state.pr_author = "ann"
	state.pr_base = "main"
	state.pr_head = "feat/x"
	state.files_loaded = true
	state.files = {
		{ path = "lua/a.lua", status = "M", additions = 3, deletions = 1 },
		{ path = "README.md", status = "A", additions = 5, deletions = 0 },
	}

	with_pane(function(bufnr)
		file_list.render()
		local text = pane_text(bufnr)
		assert_true(text:find("PR REVIEW", 1, true) ~= nil, "the pane names the PR")
		assert_true(text:find("#12", 1, true) ~= nil, "and its number")
		assert_true(text:find("Make it good", 1, true) ~= nil, "and its title")
		assert_true(text:find("@ann", 1, true) ~= nil, "and its author")
		assert_true(text:find("Files (2)", 1, true) ~= nil, "the file count")
		assert_true(text:find("+8", 1, true) ~= nil, "the aggregate additions")
		assert_true(text:find("README.md", 1, true) ~= nil, "a root file row")
		assert_true(text:find("a.lua", 1, true) ~= nil, "a nested file row")
		assert_true(text:find("NAVIGATE", 1, true) ~= nil, "the legend")
		assert_true(text:find("q close", 1, true) ~= nil, "and the way out")
	end)
end)

test("file_list: the empty, loading and error states each render", function()
	with_pane(function(bufnr)
		rstate.reset()
		state.pr_number = 1
		file_list.render()
		assert_true(pane_text(bufnr):find("Loading changed files", 1, true) ~= nil,
			"a PR that has not answered yet says so")

		state.files_loaded = true
		file_list.render()
		assert_true(pane_text(bufnr):find("No changed files", 1, true) ~= nil,
			"an empty PR says so")

		state.files_error = "gh pr view failed: boom"
		file_list.render()
		local text = pane_text(bufnr)
		assert_true(text:find("Could not load changed files", 1, true) ~= nil,
			"a failed load is visible in the pane")
		assert_true(text:find("boom", 1, true) ~= nil,
			"and carries the real reason, not just a generic message")
	end)
end)

test("file_list: rows resolve back to the file, folder and draft under them", function()
	rstate.reset()
	state.pr_number = 3
	state.files_loaded = true
	state.files = { { path = "lua/a.lua", status = "M" } }
	state.file_diffs = { ["lua/a.lua"] = sample_file_diff("lua/a.lua") }
	state.pending_comments = {
		{ id = 1, path = "lua/a.lua", body = "please fix", new_line = 11 },
	}

	with_pane(function(bufnr)
		file_list.render()
		local winid = vim.api.nvim_get_current_win()

		local file_line = next(state.file_line_map)
		assert_true(file_line ~= nil, "a file row should be mapped")
		vim.api.nvim_win_set_cursor(winid, { file_line, 0 })
		assert_equals(file_list.file_idx_under_cursor(), 1,
			"the file row resolves to its index in state.files")
		assert_equals(file_list.draft_idx_under_cursor(), nil,
			"a file row is not a draft row")

		local draft_line = next(state.draft_line_map)
		assert_true(draft_line ~= nil, "a draft row should be mapped")
		vim.api.nvim_win_set_cursor(winid, { draft_line, 0 })
		assert_equals(file_list.draft_idx_under_cursor(), 1,
			"the draft row resolves to its index in state.pending_comments")

		local text = pane_text(bufnr)
		assert_true(text:find("Drafts (1)", 1, true) ~= nil, "drafts are listed")
		assert_true(text:find("please fix", 1, true) ~= nil, "with a preview")
	end)
end)

test("file_list: an off-diff draft is flagged in the Drafts header", function()
	rstate.reset()
	state.pr_number = 3
	state.files_loaded = true
	state.files = { { path = "a.lua", status = "M" } }
	state.file_diffs = { ["a.lua"] = sample_file_diff("a.lua") }
	state.pending_comments = {
		{ id = 1, path = "a.lua", body = "in scope", new_line = 11 },
		{ id = 2, path = "a.lua", body = "adrift", new_line = 900 },
	}

	with_pane(function(bufnr)
		file_list.render()
		local text = pane_text(bufnr)
		assert_true(text:find("Drafts (2)", 1, true) ~= nil, "both drafts are listed")
		assert_true(text:find("\u{2717}1 off-diff", 1, true) ~= nil,
			"the one GitHub would reject is counted in the header")
	end)
end)

test("file_list: folding a directory hides its files and is reversible", function()
	rstate.reset()
	state.pr_number = 4
	state.files_loaded = true
	state.files = {
		{ path = "lua/deep/a.lua", status = "M" },
		{ path = "README.md", status = "M" },
	}

	with_pane(function(bufnr)
		file_list.render()
		assert_true(pane_text(bufnr):find("a.lua", 1, true) ~= nil,
			"the nested file starts visible")

		file_list.collapse_all_dirs()
		assert_true(pane_text(bufnr):find("a.lua", 1, true) == nil,
			"folding the tree hides it")
		assert_true(pane_text(bufnr):find("README.md", 1, true) ~= nil,
			"root files stay put")

		file_list.expand_all_dirs()
		assert_true(pane_text(bufnr):find("a.lua", 1, true) ~= nil,
			"unfolding brings it back")
	end)
end)

test("file_list: a stale request is dropped once the pane is detached", function()
	rstate.reset()
	state.pr_number = 5
	with_pane(function()
		local token = file_list.next_request()
		assert_true(file_list.is_active(token, 5),
			"the live generation for the open PR is active")
		assert_true(not file_list.is_active(token, 6),
			"the same generation for another PR is not")
		file_list.next_request()
		assert_true(not file_list.is_active(token, 5),
			"a superseded generation is not")
	end)
	assert_true(not file_list.is_active(file_list.next_request(), 5),
		"and nothing is active once the pane is gone")
end)

rstate.reset()

print(string.rep("\u{2500}", 50))
print(("review modules: %d passed, %d failed"):format(passed, failed))
if failed > 0 then
	os.exit(1)
end
