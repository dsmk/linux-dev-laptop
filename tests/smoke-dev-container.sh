#!/usr/bin/env bash
set -euo pipefail

for command in \
  git gcc make python3 node npm go \
  jq rg fd fzf ssh ansible code 
do
  command -v "$command"
done
echo "Check versions to make certain they start"
python3 --version
node --version
go version
ansible --version

# Image smoke tests run as root, unlike interactive toolbx sessions.
# --no-sandbox is used only for this root-run version check.
code --no-sandbox --user-data-dir=/tmp/vscode-smoke --version

# Claude checks are at the end 
command -v "claude"
claude --version
