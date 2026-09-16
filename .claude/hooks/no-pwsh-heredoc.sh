#!/usr/bin/env bash
# PreToolUse/Bash guard: reject PowerShell here-string syntax in Bash tool commands.
#
# The Bash tool runs Git Bash (POSIX sh), which has no here-strings. A command written as
# `git commit -m @'...'@` does not error -- bash passes the @ delimiters through as literal
# text, so the mistake surfaces later as corrupted content (e.g. a commit subject of "@").
# Blocking it here forces a POSIX heredoc instead.
#
# Matches against the raw hook JSON on stdin, where a newline inside the command is the
# two-character sequence \n and a double quote is \". No jq, python, or node required.

input=$(cat)

case $input in
  *'"tool_name":"Bash"'*) ;;
  *) exit 0 ;;
esac

matched=""

case $input in
  *"@'\\n"*)
    matched="here-string opener @'" ;;
  *"\\n'@"*)
    matched="here-string terminator '@" ;;
  *"\\n\\\"@"*)
    matched='here-string terminator "@' ;;
  *[!\$]"@\\\"\\n"*)
    matched='here-string opener @"' ;;
esac

if [ -z "$matched" ]; then
  exit 0
fi

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
