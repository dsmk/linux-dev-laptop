#!/usr/bin/env bash
#
# Smoke test for developer-platform-dev, run INSIDE a freshly built image:
#
#   podman run --rm -v "$PWD/images/developer-platform-dev:/src:ro" \
#     <image> bash /src/smoke.sh
#
# scripts/build-image.sh --smoke does that for you. It checks every tool the
# image promises is present and starts; it is not a functional test suite.
# These run as root, unlike an interactive toolbx or distrobox session.

set -euo pipefail

echo "== smoke test: developer-platform-dev =="

fail=0

require() {
  local command path
  for command in "$@"; do
    if path="$(command -v "${command}" 2>/dev/null)"; then
      printf '  ok      %-24s %s\n' "${command}" "${path}"
    else
      printf '  MISSING %s\n' "${command}"
      fail=1
    fi
  done
}

echo "-- development toolchain"
require \
  ansible ansible-playbook aws cargo chezmoi cmake curl \
  fd fzf gcc gh git go jq just kind make ninja node npm \
  podman python3 rg rustc ssh starship tar tofu unzip wget yq

echo "-- installed from upstream releases"
require argocd code kubectl

# ot publishes amd64 binaries only; see the Containerfile.
if [[ "$(uname -m)" == "x86_64" ]]; then
  require ot
else
  echo "  skip    ot (no $(uname -m) build published upstream)"
fi

echo "-- distrobox host integration"
# distrobox shells out to these for host integration, home mounting and
# `distrobox-export`. A missing one degrades the container silently.
require \
  bc diff find gpg hostname ip less logname lsof mount passwd \
  pinentry ps rsync sudo tree useradd which xauth zip

echo "-- toolbx host integration"
require flatpak-spawn

echo "-- VS Code extension helper"
require dev-install-extensions
if [[ -r /usr/share/developer-platform/extensions.txt ]]; then
  printf '  ok      %s (%d extensions listed)\n' \
    /usr/share/developer-platform/extensions.txt \
    "$(sed -e 's/#.*//' -e 's/[[:space:]]//g' \
         /usr/share/developer-platform/extensions.txt | grep -c '^..*$')"
else
  echo "  MISSING /usr/share/developer-platform/extensions.txt"
  fail=1
fi

# Stop here when anything is missing: the version checks below would other-
# wise fail with a confusing "command not found" instead of the list above.
if [[ "${fail}" -ne 0 ]]; then
  echo "== smoke test FAILED: developer-platform-dev (missing items above) ==" >&2
  exit 1
fi

echo "-- versions start cleanly"
ansible --version | head -1
argocd version --client | head -1
aws --version
gh --version | head -1
go version
jq --version
kubectl version --client | head -1
node --version
npm --version
python3 --version
rustc --version
tofu --version

# --no-sandbox is needed only because this check runs as root.
code --no-sandbox --user-data-dir=/tmp/vscode-smoke --version

echo "== smoke test passed: developer-platform-dev =="
