#!/bin/bash
# Rewind dev launcher: opens the repo in VS Code and starts Claude Code.
cd "$(dirname "$0")"

# Warn about a stale git lock instead of deleting it blindly: a live git
# process may hold it, and commits are made deliberately (atomic), not on launch.
if [ -f .git/index.lock ]; then
  echo "Warning: .git/index.lock exists. If no git process is running, remove it manually."
fi

# Open in VS Code (prefer the `code` CLI, fall back to `open -a`).
if command -v code >/dev/null 2>&1; then
  code .
else
  open -a "Visual Studio Code" . 2>/dev/null || echo "VS Code not found — open the folder manually."
fi

echo ""
echo "Rewind repo: $(pwd)"
echo "Kickoff prompt for Claude Code: docs/IMPLEMENTATION_KICKOFF.md"
echo ""

# Start Claude Code in this repo.
if command -v claude >/dev/null 2>&1; then
  exec claude
else
  echo "Claude Code CLI ('claude') not on PATH. Install it, then run 'claude' here."
  exec "$SHELL"
fi
