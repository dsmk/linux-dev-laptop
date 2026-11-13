#!/usr/bin/env bash
#
# Prepare a session for working on this repository, and report what it can
# actually do. Safe and idempotent; it never fails a session.
#
#   scripts/dev-env-setup.sh          human-readable report
#   scripts/dev-env-setup.sh --hook   JSON for a SessionStart hook
#
# In a Claude Code cloud session the container ships the docker client but no
# running daemon, so image builds fail with a confusing socket error until
# dockerd is started. This starts it (as root only) and then says plainly
# whether builds are possible here.

set -uo pipefail

readonly DOCKERD_LOG="${TMPDIR:-/tmp}/dockerd-dev-env.log"

# What an image build has to reach, as "label|probe URL" pairs.
#
# Root URLs are not good enough: download.copr.fedorainfracloud.org answers
# 200 on / but 301s repository content to packages.redhat.com, so a root-only
# probe calls a blocked repository reachable. Each entry therefore probes a
# URL the build actually fetches, with redirects followed, and is labelled
# with the host that has to be allowed.
#
# This is a heuristic, not a guarantee: dnf resolves Fedora mirrors through
# the metalink, so the mirror it eventually picks is not a fixed host.
readonly BUILD_PROBES=(
  "registry.fedoraproject.org|https://registry.fedoraproject.org/v2/"
  "mirrors.fedoraproject.org|https://mirrors.fedoraproject.org/metalink?repo=fedora-44&arch=x86_64"
  "copr.fedorainfracloud.org|https://copr.fedorainfracloud.org/api_3/"
  "packages.redhat.com (COPR content)|https://download.copr.fedorainfracloud.org/results/atim/starship/fedora-44-x86_64/repodata/repomd.xml"
  "packages.microsoft.com|https://packages.microsoft.com/yumrepos/vscode/repodata/repomd.xml"
  "dl.k8s.io|https://dl.k8s.io/release/stable.txt"
  "release-assets.githubusercontent.com|https://github.com/argoproj/argo-cd/releases/download/v3.5.4/cli_checksums.txt"
  "galaxy.ansible.com|https://galaxy.ansible.com/api/"
)

mode=report
case "${1:-}" in
  --hook) mode=hook ;;
  "")     ;;
  *)      echo "usage: $0 [--hook]" >&2; exit 2 ;;
esac

engine=""
engine_state="none"

engine_usable() {
  command -v "$1" >/dev/null 2>&1 && "$1" info >/dev/null 2>&1
}

detect_engine() {
  local candidate
  for candidate in podman docker; do
    if engine_usable "${candidate}"; then
      engine="${candidate}"
      engine_state="ready"
      return 0
    fi
  done
  return 1
}

start_dockerd() {
  # Only worth attempting as root with the daemon binary present.
  [[ "$(id -u)" == "0" ]] || return 1
  command -v dockerd >/dev/null 2>&1 || return 1

  nohup dockerd >"${DOCKERD_LOG}" 2>&1 &
  disown || true

  local waited=0
  while (( waited < 30 )); do
    waited=$(( waited + 1 ))
    if docker info >/dev/null 2>&1; then
      engine="docker"
      engine_state="started"
      return 0
    fi
    sleep 1
  done
  return 1
}

if ! detect_engine; then
  if start_dockerd; then
    :
  else
    engine_state="unavailable"
  fi
fi

# Probed in parallel: this runs as a SessionStart hook, so a serial sweep
# would visibly delay the start of every session.
blocked=()
if command -v curl >/dev/null 2>&1; then
  probe_dir="$(mktemp -d)"
  trap 'rm -rf "${probe_dir}"' EXIT

  index=0
  for probe in "${BUILD_PROBES[@]}"; do
    (
      # Any HTTP answer means the resource is reachable; only a transport
      # failure or a proxy policy denial counts as blocked. curl writes 000
      # and exits non-zero when a CONNECT is refused, so the exit status has
      # to be captured outside the substitution.
      code="$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 10 \
                "${probe#*|}" 2>/dev/null)" || code="000"
      case "${code}" in
        000|403|407) : >"${probe_dir}/${index}" ;;
      esac
    ) &
    index=$(( index + 1 ))
  done
  wait

  index=0
  for probe in "${BUILD_PROBES[@]}"; do
    [[ -e "${probe_dir}/${index}" ]] && blocked+=("${probe%%|*}")
    index=$(( index + 1 ))
  done
fi

summary() {
  case "${engine_state}" in
    ready)
      printf 'Container engine: %s (already running).\n' "${engine}" ;;
    started)
      printf 'Container engine: docker (daemon started by this script; log %s).\n' \
        "${DOCKERD_LOG}" ;;
    unavailable)
      printf 'Container engine: NONE usable. Image builds cannot run here;\n'
      printf 'validate with scripts/validate.sh and let CI build the images.\n' ;;
  esac

  if [[ "${#blocked[@]}" -gt 0 ]]; then
    printf 'Blocked build hosts (%d):\n' "${#blocked[@]}"
    printf '  - %s\n' "${blocked[@]}"
    printf 'An image build will fail partway through until the environment\n'
    printf "network policy allows these. Everything in scripts/validate.sh\n"
    printf 'still works offline.\n'
  else
    printf 'Every URL an image build fetches is reachable.\n'
  fi

  printf 'Validate with: scripts/validate.sh\n'
  printf 'Build with:    containers/build.sh --flavor toolbx|distrobox --smoke\n'
}

if [[ "${mode}" == "report" ]]; then
  summary
  exit 0
fi

# Hook mode: a single JSON object on stdout and nothing else, so that a
# malformed line cannot break the session.
if ! command -v python3 >/dev/null 2>&1; then
  exit 0
fi

summary | python3 -c '
import json, sys
context = sys.stdin.read().strip()
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": context,
    },
    "suppressOutput": True,
}))
'
