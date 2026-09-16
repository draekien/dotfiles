## Rules

1. Think before coding: State assumptions explicitly. Ask rather than guess. Push back when a simpler approach exists. Stop when confused.
2. Simplicity first: Minimum code that solves a problem. Nothing speculative. No abstractions for single-use code.
3. Surgical changes: Touch only what you must. Don't improve adjacent code. Match existing style. Don't refactor what isn't broken.
4. Goal-driven execution: Define success criteria. Loop until verified. Strong success criteria let Claude loop independently.

## Conventions

- use conventional commit messages everywhere, including PR titles.
- do not write comments except when documenting public facing API surfaces.
- match multi-line string syntax to the shell of the tool actually running the command. The Bash tool is POSIX sh: use a heredoc (`git commit -F - <<'EOF' … EOF`) or a plain quoted `-m`. The PowerShell tool uses a here-string (`@'…'@`). Never use PowerShell here-string syntax in the Bash tool — `@'…'@` there is not a here-string; `@` is taken literally and leaks stray `@` lines into commit messages. A hook blocks any Bash command containing `"@` on that same reading, so content with a quoted scoped package name (`"@membank/dashboard": patch`) cannot go through a heredoc at all — write the file with the Write tool instead.

## Model Selection

Use the `picking-models` skill when choosing a model for a subagent,
workflow step, or agent team member. Classify the task's role, then take the
cheapest model that clears that role's bar. Never leave the model field to
inherit from the parent.
