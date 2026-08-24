-- scripts/test_gh_live_contract.lua — one non-stubbed contract test (#330)
--
-- Every other gh-touching test drives a fixture `gh` stub, so a real upstream
-- CLI JSON shape change (a renamed/removed field) would pass CI silently.
-- This script calls the REAL `gh` binary — no PATH stub, unlike the specs run
-- under tests/minimal_init.lua — against this repo's own label list, through
-- gitflow's actual production parsing path (gh/labels.lua -> gh.json).
--
-- It skips cleanly (exit 0) whenever the environment can't support a live
-- call: gh missing, unauthenticated, or unreachable. It fails loudly only for
-- what it's meant to catch: a JSON shape gitflow's own code can't parse, or a
-- shape assertion on real data.

local script_path = debug.getinfo(1, "S").source:sub(2)
local project_root = vim.fn.fnamemodify(script_path, ":p:h:h")
vim.opt.runtimepath:append(project_root)

local function skip(reason)
	print(("SKIP: %s"):format(reason))
	os.exit(0)
end

local function fail(message)
	print(("FAIL: %s"):format(message))
	vim.cmd("cquit! 1")
end

local gh = require("gitflow.gh")

local ok, message = gh.ensure_prerequisites()
if not ok then
	skip(("gh prerequisites not satisfied — %s"):format(message or "unknown reason"))
end

local gh_labels = require("gitflow.gh.labels")

local done = false
local call_err, call_data, call_result

gh_labels.list(nil, function(err, data, result)
	call_err, call_data, call_result = err, data, result
	done = true
end)

local completed = vim.wait(15000, function()
	return done
end, 50)

if not completed then
	skip("gh label list did not respond within 15s (network condition)")
end

if call_result and call_result.code ~= 0 then
	-- Nonzero exit with no parse attempt made: an environment condition
	-- (auth expired mid-run, rate limit, network), not a code bug.
	skip(("gh label list exited %d — %s"):format(
		call_result.code, gh.output(call_result)
	))
end

if call_err then
	-- Exit was 0 but gitflow's own JSON decode failed: this IS the drift
	-- this test exists to catch.
	fail(("gh label list returned unparsable JSON: %s"):format(call_err))
end

if type(call_data) ~= "table" then
	fail(("gh label list did not decode to a table (got %s)"):format(type(call_data)))
end

for i, label in ipairs(call_data) do
	if type(label) ~= "table" then
		fail(("label #%d is not an object (got %s)"):format(i, type(label)))
	end
	if type(label.name) ~= "string" or label.name == "" then
		fail(("label #%d has no string 'name' field"):format(i))
	end
	if type(label.color) ~= "string" then
		fail(("label #%d has no string 'color' field"):format(i))
	end
end

print(("PASS: gh label list live-contract — %d label(s), shape matches"):format(#call_data))
