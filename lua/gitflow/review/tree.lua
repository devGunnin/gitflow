--- The review file list's directory tree: pure model, no rendering.
---
--- `build` turns the PR's flat file list into a nested tree; the counters
--- answer the questions the rendered rows ask of a folded folder ("how many
--- files, how much unread discussion is hidden in there?").

local state = require("gitflow.review.state")

local M = {}

--- Build a nested directory tree from the flat file list. Each node has
--- `dirs` (name → child), `dir_order` (insertion order) and `files` (leaf
--- entries carrying the original 1-based index into state.files).
---@param files GitflowPrReviewFile[]
---@return table root
function M.build(files)
	local root = { dirs = {}, dir_order = {}, files = {} }
	for idx, f in ipairs(files) do
		local parts = vim.split(f.path, "/", { plain = true })
		local node = root
		for i = 1, #parts - 1 do
			local part = parts[i]
			local child = node.dirs[part]
			if not child then
				child = { dirs = {}, dir_order = {}, files = {} }
				node.dirs[part] = child
				node.dir_order[#node.dir_order + 1] = part
			end
			node = child
		end
		node.files[#node.files + 1] = {
			idx = idx, name = parts[#parts], file = f,
		}
	end
	return root
end

---@param node table
---@return integer
function M.leaf_count(node)
	local n = #node.files
	for _, d in ipairs(node.dir_order) do
		n = n + M.leaf_count(node.dirs[d])
	end
	return n
end

--- Sum remote threads and pending drafts across every file under `node`.
---@param node table
---@param threads table<string, integer>
---@param pending table<string, integer>
---@return integer, integer  total threads, total drafts
function M.comment_totals(node, threads, pending)
	local t, p = 0, 0
	for _, e in ipairs(node.files) do
		t = t + (threads[e.file.path] or 0)
		p = p + (pending[e.file.path] or 0)
	end
	for _, d in ipairs(node.dir_order) do
		local ct, cp = M.comment_totals(node.dirs[d], threads, pending)
		t, p = t + ct, p + cp
	end
	return t, p
end

--- Per-path counts of pending drafts and remote threads.
---@return table<string, integer>, table<string, integer>
function M.counts_by_path()
	local pending, threads = {}, {}
	for _, pc in ipairs(state.state.pending_comments) do
		if pc.path then
			pending[pc.path] = (pending[pc.path] or 0) + 1
		end
	end
	for _, t in ipairs(state.state.comment_threads) do
		if t.path then
			threads[t.path] = (threads[t.path] or 0) + 1
		end
	end
	return pending, threads
end

return M
