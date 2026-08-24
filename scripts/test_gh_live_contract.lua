-- scripts/test_gh_live_contract.lua — one non-stubbed contract test (#330)
--
-- Every other gh-touching test drives a fixture `gh` stub, so a real upstream
-- CLI JSON shape change (a renamed/removed field) would pass CI silently.
-- This script calls the REAL `gh` binary — no PATH stub, unlike the specs run
-- under tests/minimal_init.lua — against this repo's own label list, through
-- gitflow's actual production parsing path (gh/labels.lua -> gh.json).
--
-- It skips cleanly (exit 0) only when gh.classify_failure() says the
-- environment can't support a live call: gh missing/unauthenticated
-- (checked up front) or a network condition. Anything else gh rejects —
-- most notably a field this test's query no longer matches upstream — is
-- exactly the drift this test exists to catch, and fails loudly instead.

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

-- gh.classify_failure() classifies rate limiting but not 5xx (it falls to
-- "unknown"), so an upstream outage would otherwise fail() here looking like
-- drift. Detect that locally; rate limiting is skipped via `kind` below.
---@param output string
---@return string|nil reason
local function transient_upstream_reason(output)
	local text = (output or ""):lower()
	local status = text:match("%(http (%d%d%d)%)")
	if status and status:sub(1, 1) == "5" then
		return ("HTTP %s"):format(status)
	end
	if
		text:find("rate limit", 1, true)
		or text:find("rate_limited", 1, true)
	then
		return "rate limit"
	end
	return nil
end

local gh = require("gitflow.gh")

local ok, message = gh.ensure_prerequisites()
if not ok then
	skip(("gh prerequisites not satisfied — %s"):format(message or "unknown reason"))
end

local gh_labels = require("gitflow.gh.labels")

local done = false
local call_err, call_data, call_result

gh_labels.list(nil, nil, function(err, data, result)
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
	local output = gh.output(call_result)
	local kind = gh.classify_failure(output)
	-- Only a genuine environment condition skips. Anything else — most
	-- notably gh rejecting a field this test's own query no longer
	-- matches upstream ("Unknown JSON field") — is the drift this test
	-- exists to catch, and must fail loudly, not skip green.
	if kind == "network" or kind == "auth" or kind == "rate_limit" then
		skip(("gh label list exited %d (%s) — %s"):format(
			call_result.code, kind, output
		))
	end
	local transient = transient_upstream_reason(output)
	if transient then
		skip(("gh label list exited %d (upstream %s) — %s"):format(
			call_result.code, transient, output
		))
	end
	fail(("gh label list exited %d (%s) — %s"):format(call_result.code, kind, output))
	return
end

if call_err then
	-- Exit was 0 but gitflow's own JSON decode failed: this IS the drift
	-- this test exists to catch.
	fail(("gh label list returned unparsable JSON: %s"):format(call_err))
	return
end

if type(call_data) ~= "table" then
	fail(("gh label list did not decode to a table (got %s)"):format(type(call_data)))
	return
end

if #call_data == 0 then
	-- An empty result asserts nothing about the shape; skip rather than
	-- claim a pass the data can't back up.
	skip("gh label list returned zero labels — nothing to shape-check")
end

for i, label in ipairs(call_data) do
	if type(label) ~= "table" then
		fail(("label #%d is not an object (got %s)"):format(i, type(label)))
		return
	end
	if type(label.name) ~= "string" or label.name == "" then
		fail(("label #%d has no string 'name' field"):format(i))
		return
	end
	if type(label.color) ~= "string" then
		fail(("label #%d has no string 'color' field"):format(i))
		return
	end
	-- Assert every field gitflow's production query requests
	-- (gh/labels.lua LABEL_FIELDS), not just what this test happens to use.
	if type(label.description) ~= "string" then
		fail(("label #%d has no string 'description' field"):format(i))
		return
	end
	if type(label.isDefault) ~= "boolean" then
		fail(("label #%d has no boolean 'isDefault' field"):format(i))
		return
	end
end

print(("PASS: gh label list live-contract — %d label(s), shape matches"):format(#call_data))
