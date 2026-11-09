#!/usr/bin/env bash
set -euo pipefail

for command in \
  ansible ansible-playbook aws code fd fzf \
  gcc git go jq kubectl make node npm python3 \
  rg rustc ssh tofu yq 
do
  command -v "$command"
done
echo "Check versions to make certain they start"
ansible --version
aws --version
gh --version
go version
node --version
npm --version
kubectl version --client
python3 --version
rustc --version 
tofu --version 

# Image smoke tests run as root, unlike interactive toolbx sessions.
# --no-sandbox is used only for this root-run version check.
code --no-sandbox --user-data-dir=/tmp/vscode-smoke --version

# The keyring client library VS Code dlopen()s at runtime.  Nothing declares
# it as a dependency -- the `code` RPM dropped its libsecret requirement in
# 1.83 -- so a base-image or package-list change can drop it silently and the
# only symptom is a dialog in the editor, long after the build is green.
# ldconfig rather than a path test, so this holds on x86_64 and aarch64 alike.
echo "Check the VS Code keyring client library is present"
ldconfig -p | grep -q 'libsecret-1\.so\.0' || ls /usr/lib64/libsecret-1.so.0

# Claude checks are at the end 
#command -v "claude"
#claude --version
