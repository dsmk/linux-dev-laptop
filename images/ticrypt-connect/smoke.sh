#!/usr/bin/env bash
#
# Smoke test for ticrypt-connect, run INSIDE a freshly built image:
#
#   podman run --rm -v "$PWD/images/ticrypt-connect:/src:ro" \
#     <image> bash /src/smoke.sh
#
# scripts/build-image.sh --smoke does that for you.

set -euo pipefail

echo "== smoke test: ticrypt-connect =="

fail=0

require() {
  local command path
  for command in "$@"; do
    if path="$(command -v "${command}" 2>/dev/null)"; then
      printf '  ok      %-20s %s\n' "${command}" "${path}"
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

echo "-- distrobox host integration"
# The minimum distrobox needs inside a container. Anything missing here makes
# `distrobox create` or `distrobox-export` degrade silently.
require \
  bc diff find gpg hostname less lsof mount passwd pinentry ps \
  sudo useradd which xauth

echo "-- tiCrypt Connect"
require ticrypt-connect
require_file \
  /usr/share/applications/ticrypt-connect.desktop \
  /usr/share/icons/hicolor/256x256/apps/ticrypt-connect.png

echo "-- GTK/WebKit runtime the application links against"
require_file \
  /usr/lib64/libgtk-3.so.0 \
  /usr/lib64/libwebkit2gtk-4.1.so.0 \
  /usr/lib64/libcryptsetup.so.12

if [[ "${fail}" -ne 0 ]]; then
  echo "== smoke test FAILED: ticrypt-connect (missing items above) ==" >&2
  exit 1
fi

echo "-- the binary resolves every shared library it needs"
if ldd /usr/bin/ticrypt-connect | grep 'not found'; then
  echo "== smoke test FAILED: unresolved shared libraries ==" >&2
  exit 1
fi
echo "  ok      ldd reports no missing libraries"

echo "-- desktop entry is the shape distrobox-export expects"
grep -qx 'Type=Application' /usr/share/applications/ticrypt-connect.desktop
grep -qx 'Exec=ticrypt-connect' /usr/share/applications/ticrypt-connect.desktop
grep -qx 'Icon=ticrypt-connect' /usr/share/applications/ticrypt-connect.desktop
echo "  ok      Type/Exec/Icon"

echo "-- installed version"
rpm -q ticrypt-connect

echo "== smoke test passed: ticrypt-connect =="
