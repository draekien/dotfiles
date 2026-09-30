#!/usr/bin/env bash

IFS= read -r -d '' input

[[ $input == *'"tool_name":"Bash"'* ]] || exit 0

shopt -s nocasematch
pattern='(pwsh|powershell)(\.exe)?[[:space:]]([^;&|]*[[:space:]])?-(c|command)[[:space:]].*[^[:alnum:]_./-]/tmp([^[:alnum:]_.-]|$)'
[[ $input =~ $pattern ]] || exit 0

cat >&2 <<'EOF'
Blocked: `/tmp` inside a `pwsh -Command` string in a Bash tool command.

Git Bash converts `/tmp` to `C:\Users\<name>\AppData\Local\Temp` only for arguments it passes
to a native program. Inside the `-Command` string, PowerShell resolves `/tmp` itself, against
the current drive, so `Set-Content /tmp/x.txt` writes `F:\tmp\x.txt` and Bash never sees it.

Use one of:

  pwsh -NoProfile -Command 'Set-Content "$env:TEMP/x.txt" hi'
  pwsh -NoProfile -File /tmp/x.ps1
  the PowerShell tool, with `$env:TEMP`
EOF

exit 2
