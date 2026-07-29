-- tests/e2e/diffview_spec.lua — diffview panel async-guard tests
--
-- Run: nvim --headless -u tests/minimal_init.lua -l tests/e2e/diffview_spec.lua
--
-- Verifies:
--   1. Two racing opens leave exactly one, correctly-titled tab
--   2. A response arriving after close does not resurrect a tab
--   3. The file-list buffer does not leak across repeated open/close

local T = _G.T
local cfg = _G.TestConfig

local git = require("gitflow.git")
local diffview = require("gitflow.panels.diffview")

---Replace `git.git` with a stub that queues callbacks instead of running them,
---so the test decides the completion order.
---@param fn fun(queue: fun(result: table)[])
local function with_queued_git(fn)
	local original = git.git
	local queue = {}
	git.git = function(_, _, on_exit)
		queue[#queue + 1] = on_exit
	end

	local ok, err = xpcall(function()
		fn(queue)
	end, debug.traceback)

	git.git = original

	if not ok then
		error(err, 0)
	end
end

---@param path string
---@return table  a successful git result carrying a one-hunk diff
local function diff_result(path)
	return {
		code = 0,
		signal = 0,
		stdout = table.concat({
			("diff --git a/%s b/%s"):format(path, path),
			("--- a/%s"):format(path),
			("+++ b/%s"):format(path),
			"@@ -1 +1 @@",
			"-old",
			"+new",
			"",
		}, "\n"),
		stderr = "",
	}
end

---@return integer[]  every live file-list buffer, leaked or not
local function file_list_bufnrs()
	local found = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local ft = vim.api.nvim_get_option_value("filetype", { buf = bufnr })
		if ft == "gitflow-diffview" then
			found[#found + 1] = bufnr
		end
	end
	return found
end

---@return integer[]  every tabpage currently showing a diffview file list
local function diffview_tabpages()
	local seen = {}
	local tabs = {}
	for _, bufnr in ipairs(file_list_bufnrs()) do
		for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
			local tab = vim.api.nvim_win_get_tabpage(winid)
			if not seen[tab] then
				seen[tab] = true
				tabs[#tabs + 1] = tab
			end
		end
	end
	return tabs
end

---Hard-reset diffview state, including tabs/buffers a bug may have orphaned,
---so one failing test cannot cascade into the next.
local function reset()
	pcall(diffview.close)
	vim.cmd("silent! tabonly!")
	for _, bufnr in ipairs(file_list_bufnrs()) do
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

T.run_suite("diffview async guards", {
	["racing opens leave exactly one correctly-titled tab"] = function()
		reset()
		local tabs_before = #vim.api.nvim_list_tabpages()

		with_queued_git(function(queue)
			diffview.open_commit(cfg, "aaaaaaa1")
			diffview.open_commit(cfg, "bbbbbbb2")
			T.assert_equals(#queue, 2, "both opens should issue a git call")
			-- Stale response lands first, newest second.
			queue[1](diff_result("alpha.txt"))
			queue[2](diff_result("beta.txt"))
		end)

		-- Counted over ALL tabpages, not just those still holding a file-list
		-- buffer: the losing open orphans a tab whose buffer got replaced.
		T.assert_equals(
			#vim.api.nvim_list_tabpages() - tabs_before,
			1,
			"racing opens should add exactly one tabpage"
		)
		T.assert_equals(
			#diffview_tabpages(),
			1,
			"racing opens should leave exactly one diffview tab"
		)

		local bufnrs = file_list_bufnrs()
		T.assert_equals(
			#bufnrs,
			1,
			"racing opens should leave exactly one file-list buffer"
		)

		local rendered = table.concat(T.buf_lines(bufnrs[1]), "\n")
		T.assert_contains(
			rendered,
			"Commit bbbbbbb2",
			"the surviving tab should carry the newest title"
		)
		T.assert_contains(
			rendered,
			"beta.txt",
			"the surviving tab should show the newest diff"
		)
		T.assert_false(
			rendered:find("alpha.txt", 1, true) ~= nil,
			"the superseded diff must not be rendered"
		)

		reset()
	end,

	["a response arriving after close does not open a tab"] = function()
		reset()

		with_queued_git(function(queue)
			diffview.open_commit(cfg, "deadbeef")
			diffview.close()
			T.assert_equals(#queue, 1, "open should issue one git call")
			queue[1](diff_result("alpha.txt"))
		end)

		T.assert_equals(
			#diffview_tabpages(),
			0,
			"a post-close response must not build a tab"
		)
		T.assert_equals(
			#file_list_bufnrs(),
			0,
			"a post-close response must not create a file-list buffer"
		)

		reset()
	end,

	["file-list buffers do not accumulate across open/close"] = function()
		reset()

		with_queued_git(function(queue)
			for i = 1, 3 do
				diffview.open_commit(cfg, ("c0mmit%d0"):format(i))
				queue[#queue](diff_result("alpha.txt"))
				diffview.close()
			end
		end)

		T.assert_equals(
			#file_list_bufnrs(),
			0,
			"close should delete the file-list buffer, not hide it"
		)
		T.assert_equals(
			#diffview_tabpages(),
			0,
			"close should leave no diffview tab behind"
		)

		reset()
	end,

	["close is idempotent"] = function()
		reset()

		with_queued_git(function(queue)
			diffview.open_commit(cfg, "feedface")
			queue[1](diff_result("alpha.txt"))
		end)

		diffview.close()
		diffview.close()

		T.assert_equals(
			#file_list_bufnrs(),
			0,
			"a second close should be a no-op, not an error"
		)

		reset()
	end,
})

print("E2E diffview panel tests passed")
