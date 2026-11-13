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

# Hosts an image build (or the Ansible checks) has to reach. A restricted
# network policy that blocks any of these turns a build into a confusing
# mid-build failure, so they are named here and in CLAUDE.md.
readonly BUILD_HOSTS=(
  registry.fedoraproject.org          # fedora-toolbox base image
  mirrors.fedoraproject.org           # dnf metalink
  download.fedoraproject.org          # dnf packages
  copr.fedorainfracloud.org           # starship COPR metadata
  download.copr.fedorainfracloud.org  # starship COPR packages
  packages.microsoft.com              # VS Code
  dl.k8s.io                           # kubectl
  github.com                          # argocd, ot
  objects.githubusercontent.com       # GitHub release assets
  galaxy.ansible.com                  # ansible-galaxy collections
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

# Probed in parallel: this runs as a SessionStart hook, so a serial sweep of
# ten hosts would visibly delay the start of every session.
blocked=()
if command -v curl >/dev/null 2>&1; then
  probe_dir="$(mktemp -d)"
  trap 'rm -rf "${probe_dir}"' EXIT

  for host in "${BUILD_HOSTS[@]}"; do
    (
      # Any HTTP answer means the host is reachable; only a transport failure
      # or a proxy policy denial counts as blocked. curl writes 000 and exits
      # non-zero when a CONNECT is refused, so the exit status has to be
      # captured outside the substitution.
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
                "https://${host}/" 2>/dev/null)" || code="000"
      case "${code}" in
        000|403|407) : >"${probe_dir}/${host}" ;;
      esac
    ) &
  done
  wait

  for host in "${BUILD_HOSTS[@]}"; do
    [[ -e "${probe_dir}/${host}" ]] && blocked+=("${host}")
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
    printf 'Blocked build hosts (%d): %s\n' \
      "${#blocked[@]}" "${blocked[*]}"
    printf 'An image build will fail partway through until the environment\n'
    printf "network policy allows these. Everything in scripts/validate.sh\n"
    printf 'still works offline.\n'
  else
    printf 'All hosts an image build needs are reachable.\n'
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
