#!/usr/bin/env bash
#
# Build one flavour of the developer platform image.
#
# This is the only supported way to build: it sets the build context to
# containers/ (the package manifests are shared), picks the right base image
# for the flavour and passes the build args the Containerfile expects.
#
#   containers/build.sh                                  # toolbx, host arch
#   containers/build.sh --flavor distrobox --smoke
#   containers/build.sh --flavor toolbx --arch arm64 --tag ghcr.io/me/x:1
#
# Engine: podman if present, otherwise docker. Both are supported; CI uses
# podman, cloud sessions generally have docker.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly CONTEXT="${REPO_ROOT}/containers"
readonly CONTAINERFILE="${CONTEXT}/dev/Containerfile"

# Default base image per flavour. Override with --base or BASE_IMAGE= when the
# network policy in use cannot reach registry.fedoraproject.org; see
# containers/README.md for the host list.
base_for_flavor() {
  case "$1" in
    toolbx)    echo "registry.fedoraproject.org/fedora-toolbox:44" ;;
    distrobox) echo "registry.fedoraproject.org/fedora-toolbox:44" ;;
    *)         return 1 ;;
  esac
}

# Published image name per flavour. 'toolbx' keeps the historical name so
# existing deployments that pull developer-platform-dev keep working.
image_for_flavor() {
  case "$1" in
    toolbx)    echo "developer-platform-dev" ;;
    distrobox) echo "developer-platform-distrobox" ;;
    *)         return 1 ;;
  esac
}

usage() {
  sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

Options:
  --flavor NAME     toolbx (default) or distrobox
  --arch ARCH       amd64 | arm64; default is the host architecture
  --tag REF         full image reference to tag; default
                    localhost/<image>:dev
  --base IMAGE      override the base image for this flavour
  --engine NAME     podman | docker; default is whichever is installed
  --smoke           run tests/smoke-container.sh against the built image
  --push            push the tag after a successful build
  --dry-run         print the build command without running it
  -h, --help        this message

Environment:
  BASE_IMAGE        same as --base
  EXTRA_BUILD_ARGS  extra words appended to the engine's build command, e.g.
                    EXTRA_BUILD_ARGS='--network=host --build-arg https_proxy=...'
USAGE
}

flavor=toolbx
arch=""
tag=""
base="${BASE_IMAGE:-}"
engine=""
smoke=false
push=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flavor)  flavor="${2:?--flavor needs a value}"; shift 2 ;;
    --arch)    arch="${2:?--arch needs a value}"; shift 2 ;;
    --tag)     tag="${2:?--tag needs a value}"; shift 2 ;;
    --base)    base="${2:?--base needs a value}"; shift 2 ;;
    --engine)  engine="${2:?--engine needs a value}"; shift 2 ;;
    --smoke)   smoke=true; shift ;;
    --push)    push=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! image="$(image_for_flavor "${flavor}")"; then
  echo "unknown flavour: ${flavor} (expected toolbx or distrobox)" >&2
  exit 2
fi

if [[ ! -f "${CONTEXT}/packages/${flavor}.txt" ]]; then
  echo "missing package list: containers/packages/${flavor}.txt" >&2
  exit 2
fi

[[ -n "${base}" ]] || base="$(base_for_flavor "${flavor}")"

if [[ -z "${engine}" ]]; then
  for candidate in podman docker; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      engine="${candidate}"
      break
    fi
  done
fi

if [[ -z "${engine}" ]]; then
  echo "no container engine found: install podman, or start dockerd" >&2
  echo "in a cloud session run scripts/dev-env-setup.sh first" >&2
  exit 1
fi

if ! "${engine}" info >/dev/null 2>&1; then
  echo "${engine} is installed but not usable (is the daemon running?)" >&2
  echo "in a cloud session run scripts/dev-env-setup.sh first" >&2
  exit 1
fi

if [[ -z "${arch}" ]]; then
  case "$(uname -m)" in
    x86_64)          arch=amd64 ;;
    aarch64|arm64)   arch=arm64 ;;
    *) echo "unsupported host architecture: $(uname -m); pass --arch" >&2; exit 2 ;;
  esac
fi

[[ -n "${tag}" ]] || tag="localhost/${image}:dev"

build=(
  "${engine}" build
  --platform "linux/${arch}"
  --file "${CONTAINERFILE}"
  --build-arg "FLAVOR=${flavor}"
  --build-arg "BASE_IMAGE=${base}"
  --tag "${tag}"
)

if [[ -n "${EXTRA_BUILD_ARGS:-}" ]]; then
  # Word splitting is intended here: EXTRA_BUILD_ARGS is a list of flags.
  # shellcheck disable=SC2206
  build+=(${EXTRA_BUILD_ARGS})
fi

build+=("${CONTEXT}")

printf 'flavour : %s\n' "${flavor}"
printf 'base    : %s\n' "${base}"
printf 'arch    : %s\n' "${arch}"
printf 'engine  : %s\n' "${engine}"
printf 'tag     : %s\n' "${tag}"
printf 'command : %s\n' "${build[*]}"

if [[ "${dry_run}" == true ]]; then
  exit 0
fi

"${build[@]}"

# toolbx will not create a container from an image without this label, so a
# missing one is a build regression rather than a cosmetic problem.
label="$("${engine}" inspect --format '{{ index .Config.Labels "com.github.containers.toolbox" }}' "${tag}" 2>/dev/null || true)"
if [[ "${label}" != "true" ]]; then
  echo "built image is missing com.github.containers.toolbox=true" >&2
  exit 1
fi

if [[ "${smoke}" == true ]]; then
  echo "running smoke tests for ${flavor}"
  "${engine}" run --rm \
    --platform "linux/${arch}" \
    --volume "${REPO_ROOT}/tests:/tests:ro" \
    "${tag}" \
    bash /tests/smoke-container.sh "${flavor}"
fi

if [[ "${push}" == true ]]; then
  "${engine}" push "${tag}"
fi

echo "built ${tag}"
