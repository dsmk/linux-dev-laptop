#!/usr/bin/env bash
set -euo pipefail

for command in \
  ansible ansible-playbook code fd fzf \
  gcc git go jq make node npm python3 \
  rg ssh yq 
do
  command -v "$command"
done
echo "Check versions to make certain they start"
ansible --version
gh --version
go version
node --version
npm --version
python3 --version
rustc --version 
tofu --version 

# Image smoke tests run as root, unlike interactive toolbx sessions.
# --no-sandbox is used only for this root-run version check.
code --no-sandbox --user-data-dir=/tmp/vscode-smoke --version

# Claude checks are at the end 
command -v "claude"
claude --version
