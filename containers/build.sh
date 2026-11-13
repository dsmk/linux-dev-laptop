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

readonly FLAVOURS_CONF="${CONTEXT}/flavours.conf"

# containers/flavours.conf is the single source of truth for what a flavour
# is. Fields: name | package lists | published image | architectures | kind.
flavour_field() {
  local name="$1" field="$2"
  awk -F'|' -v name="${name}" -v field="${field}" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1) }
    $1 == name { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $field); print $field; found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' "${FLAVOURS_CONF}"
}

known_flavours() {
  awk -F'|' '!/^[[:space:]]*#/ && NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1 }' \
    "${FLAVOURS_CONF}"
}

# Base image. Every flavour currently starts from fedora-toolbox: it carries
# the integration pieces both toolbx and distrobox expect. Override with
# --base or BASE_IMAGE when a network policy cannot reach that registry.
readonly DEFAULT_BASE_IMAGE="registry.fedoraproject.org/fedora-toolbox:44"

usage() {
  sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'

Options:
  --flavor NAME     a flavour from containers/flavours.conf
                    (toolbx, the default, distrobox or ticrypt)
  --arch ARCH       amd64 | arm64; default is the host architecture
  --tag REF         full image reference to tag; default
                    localhost/<image>:dev
  --base IMAGE      override the base image for this flavour
  --dnf-baseurl URL pin dnf to one Fedora mirror instead of the metalink,
                    for building behind a restrictive network policy. Changes
                    image contents (see the Containerfile); not for publishing
  --proxy-ca FILE   PEM file of a CA to trust during the build, for a
                    TLS-terminating proxy. A certificate only, never a key
  --engine NAME     podman | docker; default is whichever is installed
  --smoke           run tests/smoke-container.sh against the built image
  --push            push the tag after a successful build
  --dry-run         print the build command without running it
  -h, --help        this message

Environment:
  BASE_IMAGE        same as --base
  DNF_BASEURL       same as --dnf-baseurl
  PROXY_CA          same as --proxy-ca
  EXTRA_BUILD_ARGS  extra words appended to the engine's build command, e.g.
                    EXTRA_BUILD_ARGS='--network=host --build-arg https_proxy=...'
USAGE
}

flavor=toolbx
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
    --flavor)  flavor="${2:?--flavor needs a value}"; shift 2 ;;
    --arch)    arch="${2:?--arch needs a value}"; shift 2 ;;
    --tag)     tag="${2:?--tag needs a value}"; shift 2 ;;
    --base)    base="${2:?--base needs a value}"; shift 2 ;;
    --dnf-baseurl) dnf_baseurl="${2:?--dnf-baseurl needs a value}"; shift 2 ;;
    --proxy-ca) proxy_ca="${2:?--proxy-ca needs a value}"; shift 2 ;;
    --engine)  engine="${2:?--engine needs a value}"; shift 2 ;;
    --smoke)   smoke=true; shift ;;
    --push)    push=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "${FLAVOURS_CONF}" ]]; then
  echo "missing ${FLAVOURS_CONF}" >&2
  exit 2
fi

if ! package_lists="$(flavour_field "${flavor}" 2)"; then
  echo "unknown flavour: ${flavor}" >&2
  echo "known flavours: $(known_flavours | tr '\n' ' ')" >&2
  exit 2
fi

image="$(flavour_field "${flavor}" 3)"
flavour_arches="$(flavour_field "${flavor}" 4)"
image_kind="$(flavour_field "${flavor}" 5)"

for list in ${package_lists}; do
  if [[ ! -f "${CONTEXT}/packages/${list}.txt" ]]; then
    echo "flavour ${flavor} names a missing package list: packages/${list}.txt" >&2
    exit 2
  fi
done

[[ -n "${base}" ]] || base="${DEFAULT_BASE_IMAGE}"

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

if [[ " ${flavour_arches} " != *" ${arch} "* ]]; then
  echo "flavour ${flavor} is not built for ${arch} (flavours.conf says: ${flavour_arches})" >&2
  exit 2
fi

[[ -n "${tag}" ]] || tag="localhost/${image}:dev"

build=(
  "${engine}" build
  --platform "linux/${arch}"
  --file "${CONTAINERFILE}"
  --build-arg "FLAVOR=${flavor}"
  --build-arg "PACKAGE_LISTS=${package_lists}"
  --build-arg "IMAGE_KIND=${image_kind}"
  --build-arg "BASE_IMAGE=${base}"
  --tag "${tag}"
)

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
  ca_count="$(grep -c 'BEGIN CERTIFICATE' "${proxy_ca}" || true)"
  if (( ca_bytes > 32768 )); then
    echo "--proxy-ca is ${ca_bytes} bytes holding ${ca_count} certificates;" >&2
    echo "pass only the proxy's own CA certificate, not a full trust bundle" >&2
    exit 2
  fi
  build+=(--build-arg "PROXY_CA_CERT=$(cat "${proxy_ca}")")
fi

if [[ -n "${EXTRA_BUILD_ARGS:-}" ]]; then
  # Word splitting is intended here: EXTRA_BUILD_ARGS is a list of flags.
  # shellcheck disable=SC2206
  build+=(${EXTRA_BUILD_ARGS})
fi

build+=("${CONTEXT}")

printf 'flavour : %s (%s)\n' "${flavor}" "${image_kind}"
printf 'packages: %s\n' "${package_lists}"
printf 'base    : %s\n' "${base}"
printf 'arch    : %s\n' "${arch}"
printf 'engine  : %s\n' "${engine}"
printf 'tag     : %s\n' "${tag}"
if [[ -n "${dnf_baseurl}" ]]; then
  printf 'dnf     : pinned to %s (not for publishing)\n' "${dnf_baseurl}"
fi
if [[ -n "${proxy_ca}" ]]; then
  printf 'proxy CA: %s\n' "${proxy_ca}"
fi
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
    bash /tests/smoke-container.sh "${flavor}" \
      --lists "${package_lists}" --kind "${image_kind}"
fi

if [[ "${push}" == true ]]; then
  "${engine}" push "${tag}"
fi

echo "built ${tag}"
