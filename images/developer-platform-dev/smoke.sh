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

echo "-- stays slim"
# These guard the size work. Each one silently cost hundreds of megabytes
# before, and each would come back without anyone noticing.
rpm_present() {
  local package
  for package in "$@"; do
    if rpm -q "${package}" >/dev/null 2>&1; then
      printf '  ok      %s is installed\n' "${package}"
    else
      printf '  MISSING package %s\n' "${package}"
      fail=1
    fi
  done
}

rpm_absent() {
  local package
  for package in "$@"; do
    if rpm -q "${package}" >/dev/null 2>&1; then
      printf '  PRESENT %s (should not be installed)\n' "${package}"
      fail=1
    else
      printf '  ok      %s is absent\n' "${package}"
    fi
  done
}

# kind requires "(docker-cli or podman-docker)". Satisfied from the podman
# side, the whole Moby stack stays out. podman-docker ships /usr/bin/docker
# as a shim rather than a command of its own, so both are checked.
rpm_present podman-docker
require docker
rpm_absent moby-engine containerd docker-cli glibc-all-langpacks \
  mesa-vulkan-drivers

# mesa-dri-drivers stays: VS Code renders through GL, and llvmpipe is the
# software fallback.
rpm_present mesa-dri-drivers

# glibc-all-langpacks carries a 222 MB locale-archive. Removing it in favour
# of glibc-langpack-en leaves per-locale directories and no archive at all;
# a large archive here means the removal regressed.
if [[ -f /usr/lib/locale/locale-archive ]]; then
  archive_mb=$(( $(stat -c %s /usr/lib/locale/locale-archive) / 1048576 ))
  if [[ "${archive_mb}" -lt 60 ]]; then
    printf '  ok      locale-archive is %s MB\n' "${archive_mb}"
  else
    printf '  TOO BIG locale-archive is %s MB; expected under 60\n' "${archive_mb}"
    fail=1
  fi
else
  echo "  ok      no locale-archive (only the en langpack is installed)"
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
