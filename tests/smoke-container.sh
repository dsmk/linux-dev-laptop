#!/usr/bin/env bash
#
# Smoke test run INSIDE a freshly built developer platform image.
#
#   bash tests/smoke-container.sh [toolbx|distrobox]
#
# containers/build.sh --smoke mounts tests/ read-only and runs this. It checks
# that every tool the image promises is present and actually starts; it is not
# a functional test suite.
#
# These run as root, unlike an interactive toolbx or distrobox session.

set -euo pipefail

flavor="${1:-${IMAGE_FLAVOR:-toolbx}}"

case "${flavor}" in
  toolbx|distrobox) ;;
  *) echo "unknown flavour: ${flavor}" >&2; exit 2 ;;
esac

echo "== smoke test: ${flavor} =="

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

echo "-- commands from containers/packages/common.txt"
require \
  ansible ansible-playbook argocd aws cargo chezmoi cmake code curl \
  fd fzf gcc gh git go jq just kind kubectl make ninja node npm \
  podman python3 rg rustc ssh starship tar tofu unzip wget yq

echo "-- commands for the ${flavor} flavour"
case "${flavor}" in
  toolbx)
    # flatpak-spawn is how a toolbx session reaches the host.
    require flatpak-spawn
    ;;
  distrobox)
    # distrobox shells out to these for host integration, home mounting and
    # `distrobox-export`. A missing one degrades the container silently, so
    # they are checked explicitly.
    require \
      bc diff find gpg hostname ip less logname lsof mount passwd \
      pinentry ps rsync sudo tree useradd which xauth zip
    ;;
esac

# ot publishes amd64 binaries only; see containers/dev/Containerfile.
if [[ "$(uname -m)" == "x86_64" ]]; then
  require ot
else
  echo "  skip    ot (no $(uname -m) build published upstream)"
fi

# Stop here when anything is missing: the version checks below would other-
# wise fail with a confusing "command not found" instead of the list above.
if [[ "${fail}" -ne 0 ]]; then
  echo "== smoke test FAILED: ${flavor} (missing commands above) ==" >&2
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

echo "== smoke test passed: ${flavor} =="
