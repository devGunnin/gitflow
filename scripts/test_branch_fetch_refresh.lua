-- scripts/test_branch_fetch_refresh.lua — #427 regression
--
-- #427 reported that seeing branches a fetch had just brought in required
-- closing and reopening the panel. This drives a real fetch against a real
-- remote and asserts the open panel repaints in place — for the keymapped
-- fetch (f / R), the `:Gitflow fetch` command, and a prune.
--
-- It is green on overhaul/v2 as well: the reported symptom does not reproduce
-- there, so this locks the behaviour down rather than proving a fix. It is the
-- guard the panel-base rewrite of the refresh path needed.
--
-- Every case runs in BOTH layouts: the float is where the base changed the
-- geometry and generated the footer, so a split-only run would not cover it.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)
dofile(project_root .. "/scripts/test_real_git.lua")

local passed, failed = 0, 0

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

---@param cwd string
---@param args string[]
---@return string
local function git(cwd, args)
	local cmd = { "git" }
	vim.list_extend(cmd, args)
	local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
	if result.code ~= 0 then
		error(("git %s failed: %s"):format(
			table.concat(args, " "), (result.stderr or "") .. (result.stdout or "")
		))
	end
	return result.stdout or ""
end

-- ── fixture: a bare remote, our clone, and a peer that pushes to it ───

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local remote_dir = root .. "/remote.git"
local repo_dir = root .. "/work"
local peer_dir = root .. "/peer"

git(root, { "init", "--bare", "-b", "main", remote_dir })
git(root, { "clone", remote_dir, repo_dir })
git(repo_dir, { "config", "user.email", "test@example.com" })
git(repo_dir, { "config", "user.name", "Test" })
vim.fn.writefile({ "seed" }, repo_dir .. "/seed.txt")
git(repo_dir, { "add", "seed.txt" })
git(repo_dir, { "commit", "-m", "seed" })
git(repo_dir, { "push", "-u", "origin", "main" })

git(root, { "clone", remote_dir, peer_dir })
git(peer_dir, { "config", "user.email", "peer@example.com" })
git(peer_dir, { "config", "user.name", "Peer" })

vim.fn.chdir(repo_dir)

local gitflow = require("gitflow")
gitflow.setup({
	ui = {
		default_layout = "split",
		split = { orientation = "vertical", size = 60 },
	},
})
local base_cfg = require("gitflow.config").current
local branch_panel = require("gitflow.panels.branch")
local commands = require("gitflow.commands")

---@param layout string  "split" or "float"
---@return GitflowConfig
local function layout_cfg(layout)
	return vim.tbl_deep_extend("force", vim.deepcopy(base_cfg), {
		ui = { default_layout = layout },
	})
end

---@param needle string
---@param timeout_ms integer
---@return boolean
local function wait_for_line(needle, timeout_ms)
	return vim.wait(timeout_ms or 10000, function()
		local bufnr = branch_panel.state.bufnr
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return false
		end
		for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
			if line:find(needle, 1, true) then
				return true
			end
		end
		return false
	end, 25)
end

---Push a new branch from the peer clone so a fetch has something to find.
---@param name string
local function peer_pushes_branch(name)
	git(peer_dir, { "checkout", "-b", name })
	vim.fn.writefile({ name }, peer_dir .. "/" .. name .. ".txt")
	git(peer_dir, { "add", "." })
	git(peer_dir, { "commit", "-m", name })
	git(peer_dir, { "push", "origin", name })
	git(peer_dir, { "checkout", "main" })
end

---Every case, against one layout. The panel is opened fresh each time so the
---float really goes through window.open_float and its generated footer.
---@param layout string
local function run_layout(layout)
	local cfg = layout_cfg(layout)
	local function case(name)
		return ("%s [%s]"):format(name, layout)
	end
	local function branch_name(name)
		return ("%s-%s"):format(name, layout)
	end

	branch_panel.open(cfg)
	assert_true(
		wait_for_line("origin/main", 10000),
		case("panel should list the seed branch")
	)
	local panel_bufnr = branch_panel.state.bufnr
	local winid = branch_panel.state.winid
	assert_true(winid ~= nil, case("the panel should have a window"))
	local is_float = vim.api.nvim_win_get_config(winid).relative ~= ""
	assert_true(
		is_float == (layout == "float"),
		case("the panel should open in the layout under test")
	)

	test(case("f picks up a new remote branch without reopening the panel"), function()
		local name = branch_name("from-keymap")
		peer_pushes_branch(name)
		branch_panel.fetch_remotes()
		assert_true(
			wait_for_line("origin/" .. name, 15000),
			"fetch from the panel should repaint it with the new branch"
		)
		assert_true(
			branch_panel.state.bufnr == panel_bufnr,
			"the panel should refresh in place, not be torn down and rebuilt"
		)
	end)

	test(case("R (fetch + refresh) picks up a new remote branch in place"), function()
		local name = branch_name("from-refresh")
		peer_pushes_branch(name)
		branch_panel.refresh_with_fetch()
		assert_true(
			wait_for_line("origin/" .. name, 15000),
			"R should fetch and repaint the open panel"
		)
	end)

	test(case(":Gitflow fetch repaints the open branch panel"), function()
		local name = branch_name("from-command")
		peer_pushes_branch(name)
		commands.dispatch({ "fetch" }, cfg)
		assert_true(
			wait_for_line("origin/" .. name, 15000),
			"the fetch command should repaint the open panel"
		)
	end)

	test(case("a pruned remote branch disappears from the open panel"), function()
		local name = branch_name("from-command")
		git(peer_dir, { "push", "origin", "--delete", name })
		branch_panel.fetch_remotes()
		local gone = vim.wait(15000, function()
			local lines = vim.api.nvim_buf_get_lines(panel_bufnr, 0, -1, false)
			for _, line in ipairs(lines) do
				if line:find("origin/" .. name, 1, true) then
					return false
				end
			end
			return true
		end, 25)
		assert_true(gone, "fetch --prune should drop the deleted branch from the panel")
	end)

	test(case("a fetch landing after the panel closed does not resurrect it"), function()
		branch_panel.close()
		branch_panel.fetch_remotes()
		vim.wait(2000, function()
			return false
		end)
		assert_true(
			not branch_panel.is_open(),
			"a fetch completing after close must not reopen the panel"
		)
	end)
end

run_layout("split")
run_layout("float")

vim.fn.delete(root, "rf")

print(("=== Results: %d passed, %d failed ==="):format(passed, failed))
if failed > 0 then
	os.exit(1)
end
