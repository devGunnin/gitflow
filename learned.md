# Repository Learnings

Durable, repository-specific guidance for future implementation rounds.

## BUDDY_REPO_INSIGHTS

- Add new `:Gitflow <name>` commands through `commands.register_subcommand(name, subcommand)`;
  do not patch command internals directly.
- `lua/gitflow/ui/buffer.lua` preserves cursor position by line number. If a panel needs
  semantic focus preservation, add a logical-cursor layer in the panel itself.
- Use `ui.input.prompt` for freeform capture (for example commit messages) and
  `ui.input.confirm` for yes/no flows.
- Keep headless validation aligned with existing patterns:
  `nvim --headless -u NONE -i NONE -n "+set runtimepath^=." +"luafile scripts/test_stageN.lua" +qa`.
- Stage 1 has no async infrastructure. Shared git-runner behavior is a critical dependency
  for Stage 2+ features and should be implemented and validated early.
