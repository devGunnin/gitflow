-- scripts/test_real_git.lua — ensure real git is available for script tests
--
-- Script tests that create temporary repositories (git init) need the real
-- git binary. When run via tests/minimal_init.lua the stub is prepended to
-- PATH, so this helper detects the stub and sets GITFLOW_GIT_REAL to the
-- real binary, which the stub honours as a pass-through signal.
--
-- Usage (add after project_root is defined):
--   dofile(project_root .. "/scripts/test_real_git.lua")

local git_path = vim.fn.exepath("git")
if git_path and git_path ~= "" then
	local ok, lines = pcall(vim.fn.readfile, git_path, "", 2)
	if ok and lines[2] and lines[2]:find("deterministic git stub", 1, true) then
		local stub_dir = vim.fn.fnamemodify(git_path, ":h")
		for dir in vim.env.PATH:gmatch("[^:]+") do
			if dir ~= stub_dir then
				local candidate = dir .. "/git"
				if vim.fn.executable(candidate) == 1 then
					vim.env.GITFLOW_GIT_REAL = candidate
					break
				end
			end
		end
	end
end
