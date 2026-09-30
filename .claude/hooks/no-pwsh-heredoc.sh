#!/usr/bin/env bash

IFS= read -r -d '' input

[[ $input == *'"tool_name":"Bash"'* ]] || exit 0

case $input in
  *"@'\\n"*)
    matched="here-string opener @'" ;;
  *"\\n'@"*)
    matched="here-string terminator '@" ;;
  *"\\n\\\"@"*)
    matched='here-string terminator "@' ;;
  *[!\$]"@\\\"\\n"*)
    matched='here-string opener @"' ;;
  *) exit 0 ;;
esac

cat >&2 <<EOF
Blocked: PowerShell $matched found in a Bash tool command.

The Bash tool runs Git Bash (POSIX sh), which has no here-strings. Bash does not reject the
@ delimiters -- it passes them through as literal text, so this fails silently and corrupts
the content instead of erroring.

Use a POSIX heredoc:

  git commit -F - <<'EOF'
  subject line

  body
  EOF

Or, if you actually need PowerShell, use the PowerShell tool -- here-strings are valid there.
EOF

exit 2
