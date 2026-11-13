#!/usr/bin/env bash
#
# Smoke test run INSIDE a freshly built developer platform image.
#
#   bash tests/smoke-container.sh <flavour> [--lists "a b"] [--kind dev|app]
#
# containers/build.sh --smoke mounts tests/ read-only and runs this, passing
# the package lists and kind straight from containers/flavours.conf, so the
# checks follow what was actually installed rather than a second copy of the
# flavour table. Run by hand, it assumes the usual "common <flavour>" / dev.
#
# It checks that every tool the flavour promises is present and starts; it is
# not a functional test suite. These run as root, unlike an interactive
# toolbx or distrobox session.

set -euo pipefail

flavor="${1:?usage: smoke-container.sh <flavour> [--lists LISTS] [--kind KIND]}"
shift || true

lists="common ${flavor}"
kind=dev

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lists) lists="${2:?--lists needs a value}"; shift 2 ;;
    --kind)  kind="${2:?--kind needs a value}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

has_list() { printf '%s\n' ${lists} | grep -qx "$1"; }

echo "== smoke test: ${flavor} (kind ${kind}, lists: ${lists}) =="

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

require_file() {
  local target
  for target in "$@"; do
    if [[ -e "${target}" ]]; then
      printf '  ok      %s\n' "${target}"
    else
      printf '  MISSING %s\n' "${target}"
      fail=1
    fi
  done
}

if has_list common; then
  echo "-- commands from containers/packages/common.txt"
  require \
    ansible ansible-playbook aws cargo chezmoi cmake curl \
    fd fzf gcc gh git go jq just kind make ninja node npm \
    podman python3 rg rustc ssh starship tar tofu unzip wget yq
fi

if has_list toolbx; then
  # flatpak-spawn is how a toolbx session reaches the host.
  echo "-- commands from containers/packages/toolbx.txt"
  require flatpak-spawn
fi

if has_list distrobox; then
  # distrobox shells out to these for host integration, home mounting and
  # `distrobox-export`. A missing one degrades the container silently, so
  # they are checked explicitly.
  echo "-- commands from containers/packages/distrobox.txt"
  require \
    bc diff find gpg hostname ip less logname lsof mount passwd \
    pinentry ps rsync sudo tree useradd which xauth zip
fi

if has_list ticrypt; then
  # The point of this flavour: the binary, plus the desktop entry and icon
  # that `distrobox-export --app ticrypt-connect` needs in order to put a
  # working launcher on the host menu.
  echo "-- tiCrypt Connect"
  require ticrypt-connect
  require_file \
    /usr/share/applications/ticrypt-connect.desktop \
    /usr/share/icons/hicolor/256x256/apps/ticrypt-connect.png
fi

if [[ "${kind}" == "dev" ]]; then
  echo "-- developer tooling installed from upstream releases"
  require argocd code kubectl

  # ot publishes amd64 binaries only; see containers/dev/Containerfile.
  if [[ "$(uname -m)" == "x86_64" ]]; then
    require ot
  else
    echo "  skip    ot (no $(uname -m) build published upstream)"
  fi
fi

# Stop here when anything is missing: the version checks below would other-
# wise fail with a confusing "command not found" instead of the list above.
if [[ "${fail}" -ne 0 ]]; then
  echo "== smoke test FAILED: ${flavor} (missing items above) ==" >&2
  exit 1
fi

if has_list common; then
  echo "-- versions start cleanly"
  ansible --version | head -1
  aws --version
  gh --version | head -1
  go version
  jq --version
  node --version
  npm --version
  python3 --version
  rustc --version
  tofu --version
fi

if [[ "${kind}" == "dev" ]]; then
  argocd version --client | head -1
  kubectl version --client | head -1
  # --no-sandbox is needed only because this check runs as root.
  code --no-sandbox --user-data-dir=/tmp/vscode-smoke --version
fi

if has_list ticrypt; then
  # The application needs a display, so it cannot be started here. Check the
  # desktop entry is the shape distrobox-export expects instead.
  echo "-- desktop entry"
  grep -qx 'Type=Application' /usr/share/applications/ticrypt-connect.desktop
  grep -qx 'Exec=ticrypt-connect' /usr/share/applications/ticrypt-connect.desktop
  grep -qx 'Icon=ticrypt-connect' /usr/share/applications/ticrypt-connect.desktop
  echo "  ok      Type/Exec/Icon are as distrobox-export expects"
  ticrypt-connect --version 2>/dev/null | head -1 || \
    echo "  note    ticrypt-connect has no --version; binary presence checked above"
fi

echo "== smoke test passed: ${flavor} =="
