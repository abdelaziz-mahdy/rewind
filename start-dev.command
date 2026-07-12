#!/bin/bash
# Rewind dev launcher: opens the repo in VS Code and starts Claude Code.
cd "$(dirname "$0")"

# Open in VS Code (prefer the `code` CLI, fall back to `open -a`)
if command -v code >/dev/null 2>&1; then
  code .
else
  open -a "Visual Studio Code" . 2>/dev/null || echo "VS Code not found — open the folder manually."
fi

echo ""
echo "Rewind repo: $(pwd)"
echo "Kickoff prompt: docs/IMPLEMENTATION_KICKOFF.md"
echo ""

# Start Claude Code in this repo
if command -v claude >/dev/null 2>&1; then
  exec claude
else
  echo "Claude Code CLI ('claude') not on PATH."
  echo "Install it, then run 'claude' from this folder."
  exec "$SHELL"
fi
