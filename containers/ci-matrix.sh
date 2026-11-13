#!/usr/bin/env bash
#
# Emit the GitHub Actions matrices for containers/flavours.conf, so that
# adding a flavour there is enough to get it built and published.
#
#   containers/ci-matrix.sh --build      one entry per flavour/architecture
#   containers/ci-matrix.sh --manifest   one entry per flavour
#
# Output is a JSON object for `fromJSON(...)` in a `strategy.matrix`.
# scripts/validate.sh checks it parses and agrees with flavours.conf.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly FLAVOURS_CONF="${REPO_ROOT}/containers/flavours.conf"

# Native runners only: emulating aarch64 would make the dnf step
# unreasonably slow, and free arm64 runners are available to public repos.
runner_for_arch() {
  case "$1" in
    amd64) echo "ubuntu-24.04" ;;
    arm64) echo "ubuntu-24.04-arm" ;;
    *) echo "no runner known for architecture: $1" >&2; return 1 ;;
  esac
}

mode="${1:?usage: ci-matrix.sh --build|--manifest}"

entries=()

# The package-list field is not needed here.
while IFS='|' read -r name _ image arches kind; do
  [[ "${name}" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${name// }" ]] && continue
  [[ -z "${image:-}" ]] && continue

  name="${name// }"
  image="${image// }"
  kind="${kind// }"
  arches="$(echo "${arches}")"

  case "${mode}" in
    --build)
      for arch in ${arches}; do
        runner="$(runner_for_arch "${arch}")"
        entries+=("{\"flavor\":\"${name}\",\"image\":\"${image}\",\"arch\":\"${arch}\",\"runner\":\"${runner}\",\"kind\":\"${kind}\"}")
      done
      ;;
    --manifest)
      entries+=("{\"flavor\":\"${name}\",\"image\":\"${image}\",\"arches\":\"${arches}\"}")
      ;;
    *)
      echo "unknown mode: ${mode}" >&2
      exit 2
      ;;
  esac
done < "${FLAVOURS_CONF}"

if [[ "${#entries[@]}" -eq 0 ]]; then
  echo "no flavours found in ${FLAVOURS_CONF}" >&2
  exit 1
fi

printf '{"include":['
printf '%s' "${entries[0]}"
for entry in "${entries[@]:1}"; do printf ',%s' "${entry}"; done
printf ']}\n'
