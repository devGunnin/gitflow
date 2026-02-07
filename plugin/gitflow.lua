if vim.g.loaded_gitflow == 1 then
	return
end

vim.g.loaded_gitflow = 1
require("gitflow").setup()
