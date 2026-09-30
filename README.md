# dotfiles
My personal dotfiles and other configuration related items

## Snapshot the user-level Claude Code config

`tooling/snapshot-claude.ps1` copies the user-level Claude Code files from `~/.claude` into `.claude/` in this repository.

Requirements: PowerShell 7 (`pwsh`). Tested with PowerShell 7.6.6 on Windows 11. Other platforms are untested.

From the repository root:

```powershell
pwsh -NoProfile -File ./tooling/snapshot-claude.ps1
```

Then review and commit the result:

```powershell
git diff
git add .claude
git commit -m "chore: snapshot user claude config"
```

### What the script copies

| Source | Destination | Behaviour |
|---|---|---|
| `~/.claude/CLAUDE.md` | `.claude/CLAUDE.md` | Overwritten. |
| `~/.claude/settings.json` | `.claude/settings.json` | Overwritten, then every key whose name ends in `@synced` is removed at any depth. |
| `~/.claude/hooks/` | `.claude/hooks/` | Deleted and recreated. A file that exists only in `.claude/hooks/` is lost. |

The script does not modify anything under `~/.claude`. It does not touch `.claude/themes/` or any other file in `~/.claude`.

`~` is `$HOME`, which is `C:\Users\<name>` on Windows.

### Parameters

| Parameter | Default |
|---|---|
| `-Source` | `$HOME/.claude` |
| `-Destination` | `.claude/` in this repository |

```powershell
pwsh -NoProfile -File ./tooling/snapshot-claude.ps1 -Source D:/backup/.claude -Destination D:/out/.claude
```

### Before you push

This repository is public. The script removes only keys that end in `@synced`. It does not scan values, `CLAUDE.md`, or `hooks/` for secrets. Read `git diff` before every push.

To change which keys are removed, edit `$excludedKeys` at the top of `tooling/snapshot-claude.ps1`. It is a regular expression matched against key names.
