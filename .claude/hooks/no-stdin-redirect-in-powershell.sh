#!/usr/bin/env bash

IFS= read -r -d '' input

pattern='<[[:space:]]*/dev/null'
[[ $input == *'"tool_name":"PowerShell"'* && $input =~ $pattern ]] || exit 0

cat >&2 <<'EOF'
Blocked: `< /dev/null` in a PowerShell tool command.

PowerShell reserves the `<` operator and fails to parse the command:
"The '<' operator is reserved for future use." The command does not run.

Pipe an empty string to supply empty stdin:

  '' | bash -c $command *> $null

`> /dev/null` and `2>/dev/null` do parse in PowerShell 7. If the `< /dev/null` is inside a
`bash -c` string, put that command in a .sh file and run the file.
EOF

exit 2
