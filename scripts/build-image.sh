#!/usr/bin/env bash
#
# Convenience wrapper for building one image from images/.
#
# Every image is standalone, so this is optional -- `podman build
# images/<name>` works on its own. What this adds is engine detection, the
# toolbx label check, running the image's own smoke.sh, and the two build
# args a restricted network needs.
#
#   scripts/build-image.sh developer-platform-dev --smoke
#   scripts/build-image.sh ticrypt-connect --smoke
#
# Engine: podman if present, otherwise docker. CI uses podman.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly IMAGES_DIR="${REPO_ROOT}/images"

usage() {
  cat <<'USAGE'
Usage: scripts/build-image.sh <image> [options]

  <image>           a directory name under images/

Options:
  --arch ARCH       amd64 | arm64; default is the host architecture
  --tag REF         image reference to tag; default localhost/<image>:dev
  --base IMAGE      override the Containerfile's BASE_IMAGE
  --engine NAME     podman | docker; default is whichever is installed
  --dnf-baseurl URL pin dnf to one Fedora mirror instead of the metalink,
                    for building behind a restrictive network policy. Changes
                    image contents (see the Containerfile); not for publishing
  --proxy-ca FILE   PEM file of a CA to trust during the build, for a
                    TLS-terminating proxy. A certificate only, never a key
  --smoke           run the image's smoke.sh against the result
  --push            push the tag after a successful build
  --dry-run         print the build command without running it
  -h, --help        this message

Environment: BASE_IMAGE, DNF_BASEURL, PROXY_CA, EXTRA_BUILD_ARGS
USAGE
}

list_images() {
  local dir
  for dir in "${IMAGES_DIR}"/*/; do
    [[ -f "${dir}Containerfile" ]] && basename "${dir}"
  done
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }

case "$1" in
  -h|--help) usage; exit 0 ;;
  -*) echo "first argument must be an image name" >&2; usage >&2; exit 2 ;;
esac

image="$1"
shift

arch=""
tag=""
base="${BASE_IMAGE:-}"
dnf_baseurl="${DNF_BASEURL:-}"
proxy_ca="${PROXY_CA:-}"
engine=""
smoke=false
push=false
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)        arch="${2:?--arch needs a value}"; shift 2 ;;
    --tag)         tag="${2:?--tag needs a value}"; shift 2 ;;
    --base)        base="${2:?--base needs a value}"; shift 2 ;;
    --engine)      engine="${2:?--engine needs a value}"; shift 2 ;;
    --dnf-baseurl) dnf_baseurl="${2:?--dnf-baseurl needs a value}"; shift 2 ;;
    --proxy-ca)    proxy_ca="${2:?--proxy-ca needs a value}"; shift 2 ;;
    --smoke)       smoke=true; shift ;;
    --push)        push=true; shift ;;
    --dry-run)     dry_run=true; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

context="${IMAGES_DIR}/${image}"
if [[ ! -f "${context}/Containerfile" ]]; then
  echo "no such image: ${image}" >&2
  echo "known images: $(list_images | tr '\n' ' ')" >&2
  exit 2
fi

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
    x86_64)        arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "unsupported host architecture: $(uname -m); pass --arch" >&2; exit 2 ;;
  esac
fi

[[ -n "${tag}" ]] || tag="localhost/${image}:dev"

# --file is explicit because docker looks for "Dockerfile" by default and
# would not find the Containerfile; podman finds it either way.
build=(
  "${engine}" build
  --platform "linux/${arch}"
  --file "${context}/Containerfile"
  --tag "${tag}"
)

[[ -n "${base}" ]] && build+=(--build-arg "BASE_IMAGE=${base}")

if [[ -n "${dnf_baseurl}" ]]; then
  build+=(--build-arg "DNF_BASEURL=${dnf_baseurl}")
fi

if [[ -n "${proxy_ca}" ]]; then
  if [[ ! -r "${proxy_ca}" ]]; then
    echo "cannot read --proxy-ca file: ${proxy_ca}" >&2
    exit 2
  fi
  if grep -qi 'PRIVATE KEY' "${proxy_ca}"; then
    echo "--proxy-ca must be a certificate, not a private key: ${proxy_ca}" >&2
    exit 2
  fi
  # The value is passed as a build arg, so a full system trust bundle
  # overflows the engine's argument list with an unhelpful "Argument list too
  # long". Only the proxy's own CA is needed.
  ca_bytes="$(wc -c < "${proxy_ca}")"
  if (( ca_bytes > 32768 )); then
    echo "--proxy-ca is ${ca_bytes} bytes; pass only the proxy's own CA" >&2
    exit 2
  fi
  build+=(--build-arg "PROXY_CA_CERT=$(cat "${proxy_ca}")")
fi

if [[ -n "${EXTRA_BUILD_ARGS:-}" ]]; then
  # Word splitting is intended here: EXTRA_BUILD_ARGS is a list of flags.
  # shellcheck disable=SC2206
  build+=(${EXTRA_BUILD_ARGS})
fi

build+=("${context}")

printf 'image   : %s\n' "${image}"
printf 'arch    : %s\n' "${arch}"
printf 'engine  : %s\n' "${engine}"
printf 'tag     : %s\n' "${tag}"
[[ -n "${dnf_baseurl}" ]] && printf 'dnf     : pinned to %s (not for publishing)\n' "${dnf_baseurl}"
[[ -n "${proxy_ca}" ]] && printf 'proxy CA: %s\n' "${proxy_ca}"
printf 'command : %s\n' "${build[*]}"

if [[ "${dry_run}" == true ]]; then
  exit 0
fi

"${build[@]}"

# toolbx will not create a container from an image without this label, so a
# missing one is a build regression rather than a cosmetic problem.
label="$("${engine}" inspect \
  --format '{{ index .Config.Labels "com.github.containers.toolbox" }}' \
  "${tag}" 2>/dev/null || true)"
if [[ "${label}" != "true" ]]; then
  echo "built image is missing com.github.containers.toolbox=true" >&2
  exit 1
fi

if [[ "${smoke}" == true ]]; then
  echo "running smoke tests for ${image}"
  "${engine}" run --rm \
    --platform "linux/${arch}" \
    --volume "${context}:/src:ro" \
    "${tag}" \
    bash /src/smoke.sh
fi

if [[ "${push}" == true ]]; then
  "${engine}" push "${tag}"
fi

echo "built ${tag}"
