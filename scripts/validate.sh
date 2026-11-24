#!/usr/bin/env bash
#
# Everything that can be checked WITHOUT building an image or reaching the
# network. This is the check to run after editing anything in this repository,
# and the one CI runs first.
#
#   scripts/validate.sh                 # run every check that can run here
#   scripts/validate.sh --install-tools # pip install the optional linters
#
# Optional tools (yamllint, ansible-lint, ansible-playbook, shellcheck) are
# reported as SKIP when absent rather than failing, so the script is useful in
# a bare container. CI installs them, so nothing is skipped there.

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
cd "${REPO_ROOT}" || exit 1

# Images are discovered, not registered: anything under images/ with a
# Containerfile is one. Adding an image means adding a directory.
mapfile -t IMAGES < <(
  for dir in images/*/; do
    [[ -f "${dir}Containerfile" ]] && basename "${dir}"
  done | LC_ALL=C sort
)

failures=0
skips=0

pass()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
fail()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; failures=$((failures + 1)); }
skip()  { printf '  \033[33mSKIP\033[0m  %s\n' "$*"; skips=$((skips + 1)); }
group() { printf '\n== %s\n' "$*"; }

if [[ "${1:-}" == "--install-tools" ]]; then
  echo "installing optional linters"
  pip install --quiet --break-system-packages \
    yamllint ansible-core ansible-lint
  ansible-galaxy collection install -r ansible/requirements.yml
  exit $?
fi

# ---------------------------------------------------------------------------
group "shell scripts"
# ---------------------------------------------------------------------------
mapfile -t shell_scripts < <(git ls-files --cached --others --exclude-standard '*.sh' | sort -u)

for script in "${shell_scripts[@]}"; do
  if bash -n "${script}" 2>/dev/null; then
    pass "bash -n ${script}"
  else
    fail "bash -n ${script}"
    bash -n "${script}" || true
  fi
done

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "${shell_scripts[@]}"; then
    pass "shellcheck (${#shell_scripts[@]} scripts)"
  else
    fail "shellcheck"
  fi
else
  skip "shellcheck not installed"
fi

# ---------------------------------------------------------------------------
group "images"
# ---------------------------------------------------------------------------
if [[ "${#IMAGES[@]}" -eq 0 ]]; then
  fail "no images found under images/"
else
  pass "found ${#IMAGES[@]} images: ${IMAGES[*]}"
fi

# Strip comments and blanks the same way each Containerfile does.
manifest_entries() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$'
}

check_sorted_list() {
  local file="$1" what="$2" entries duplicates

  entries="$(manifest_entries "${file}")"
  if [[ -z "${entries}" ]]; then
    fail "${file} lists no ${what}"
    return
  fi

  if duplicates="$(printf '%s\n' "${entries}" | sort | uniq -d)" \
     && [[ -n "${duplicates}" ]]; then
    fail "${file} has duplicates: ${duplicates//$'\n'/ }"
  else
    pass "${file} has no duplicates"
  fi

  if diff -q <(printf '%s\n' "${entries}") \
             <(printf '%s\n' "${entries}" | LC_ALL=C sort) >/dev/null; then
    pass "${file} is sorted"
  else
    fail "${file} is not sorted (LC_ALL=C sort)"
    diff <(printf '%s\n' "${entries}") \
         <(printf '%s\n' "${entries}" | LC_ALL=C sort) | head -10
  fi
}

for image in "${IMAGES[@]}"; do
  dir="images/${image}"

  # Each image must stand on its own: a Containerfile, the package list it
  # installs and a smoke test that proves the result.
  for required in Containerfile packages.txt smoke.sh; do
    if [[ -f "${dir}/${required}" ]]; then
      pass "${image}/${required} exists"
    else
      fail "${image}/${required} is missing"
    fi
  done

  if [[ -x "${dir}/smoke.sh" ]]; then
    pass "${image}/smoke.sh is executable"
  else
    fail "${image}/smoke.sh is not executable"
  fi

  [[ -f "${dir}/packages.txt" ]] && check_sorted_list "${dir}/packages.txt" packages

  # A standalone image cannot reach outside its own directory for build
  # context, so nothing may COPY from a parent.
  if [[ -f "${dir}/Containerfile" ]] \
     && grep -qE '^\s*COPY\s+(--[^ ]+\s+)*\.\.' "${dir}/Containerfile"; then
    fail "${image}/Containerfile copies from outside its own directory"
  else
    pass "${image} builds from its own directory alone"
  fi

  # Each image needs a workflow that builds it.
  if grep -rqlF "images/${image}/" .github/workflows/ 2>/dev/null; then
    pass "${image} is referenced by a workflow"
  else
    fail "${image} has no workflow under .github/workflows/"
  fi
done

if [[ -f images/developer-platform-dev/extensions.txt ]]; then
  check_sorted_list images/developer-platform-dev/extensions.txt extensions
fi

# ---------------------------------------------------------------------------
group "Containerfiles"
# ---------------------------------------------------------------------------
for image in "${IMAGES[@]}"; do
  containerfile="images/${image}/Containerfile"
  [[ -f "${containerfile}" ]] || continue

  # Every version installed from outside dnf must be pinned, so that a
  # rebuild of an old commit produces the same image.
  while read -r arg; do
    if grep -qE "^ARG ${arg}=.+" "${containerfile}"; then
      pass "${image}: ${arg} is pinned"
    else
      fail "${image}: ARG ${arg} is declared but not pinned"
    fi
  done < <(grep -oE '^ARG [A-Z0-9_]+_VERSION' "${containerfile}" | awk '{ print $2 }')

  # Upstream publishes no checksum file for tiCrypt Connect, so the pinned
  # digest is the only thing tying that build to a known artefact.
  while read -r arg; do
    if grep -qE "^ARG ${arg}=[0-9a-f]{64}$" "${containerfile}"; then
      pass "${image}: ${arg} is a full sha256"
    else
      fail "${image}: ARG ${arg} must pin a 64-character sha256"
    fi
  done < <(grep -oE '^ARG [A-Z0-9_]+_SHA256' "${containerfile}" | awk '{ print $2 }')

  for arg in DNF_BASEURL PROXY_CA_CERT; do
    if ! grep -qE "^ARG ${arg}" "${containerfile}"; then
      continue
    fi
    if grep -qE "^ARG ${arg}=$" "${containerfile}"; then
      pass "${image}: ${arg} defaults to empty"
    else
      fail "${image}: ARG ${arg} must default to empty; it changes what is built"
    fi
  done

  if grep -qE '^ARG BASE_IMAGE=.*:[A-Za-z0-9._-]+$' "${containerfile}"; then
    pass "${image}: BASE_IMAGE carries an explicit tag"
  else
    fail "${image}: BASE_IMAGE must name an explicit tag, not a floating one"
  fi

  if grep -qE '^(FROM|ARG BASE_IMAGE=).*:latest' "${containerfile}"; then
    fail "${image}: Containerfile refers to a :latest tag"
  else
    pass "${image}: no :latest tags"
  fi

  if grep -q 'com.github.containers.toolbox="true"' "${containerfile}"; then
    pass "${image}: toolbx label is set"
  else
    fail "${image}: com.github.containers.toolbox=true label is missing"
  fi
done

# Every image must resolve through the build helper.
if [[ -x scripts/build-image.sh ]]; then
  for image in "${IMAGES[@]}"; do
    if scripts/build-image.sh "${image}" --dry-run >/dev/null 2>&1; then
      pass "scripts/build-image.sh ${image} resolves"
    elif ! command -v podman >/dev/null 2>&1 \
         && ! command -v docker >/dev/null 2>&1; then
      skip "scripts/build-image.sh ${image} (no container engine)"
    else
      fail "scripts/build-image.sh ${image} fails"
      scripts/build-image.sh "${image}" --dry-run || true
    fi
  done
else
  fail "scripts/build-image.sh is missing or not executable"
fi

# ---------------------------------------------------------------------------
group "YAML and JSON"
# ---------------------------------------------------------------------------
mapfile -t yaml_files < <(git ls-files --cached --others --exclude-standard '*.yml' '*.yaml' | sort -u)

# Configuration lives in .yamllint at the repository root, so this command
# and the one in .github/workflows/verify.yml cannot drift apart.
if command -v yamllint >/dev/null 2>&1; then
  if yamllint "${yaml_files[@]}" .yamllint; then
    pass "yamllint (${#yaml_files[@]} files)"
  else
    fail "yamllint"
  fi
else
  skip "yamllint not installed"
fi

# Parsing is cheap and needs no extra tool, so it runs even when yamllint is
# unavailable.
for yaml_file in "${yaml_files[@]}"; do
  if python3 -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' \
       "${yaml_file}" 2>/dev/null; then
    pass "parses: ${yaml_file}"
  else
    fail "does not parse as YAML: ${yaml_file}"
  fi
done

mapfile -t json_files < <(git ls-files --cached --others --exclude-standard '*.json' | sort -u)
for json_file in "${json_files[@]}"; do
  if python3 -c 'import sys,json; json.load(open(sys.argv[1]))' \
       "${json_file}" 2>/dev/null; then
    pass "parses: ${json_file}"
  else
    fail "does not parse as JSON: ${json_file}"
  fi
done

# ---------------------------------------------------------------------------
group "Ansible"
# ---------------------------------------------------------------------------
readonly PLAYBOOKS=(
  ansible/silverblue.yml
  ansible/macos.yml
  ansible/winapps-instance.yml
)

# The playbooks use modules from community.general, so a checkout without the
# collections installed cannot be syntax-checked at all. That is an
# environment gap, not a repository fault, so it is a SKIP: CI installs the
# collections and therefore always runs these for real.
# `ansible-galaxy collection list <name>` exits 0 even when the collection is
# absent, so the name has to be looked for in the output.
collections_installed=false
if command -v ansible-galaxy >/dev/null 2>&1 \
   && ansible-galaxy collection list 2>/dev/null \
      | grep -q '^community\.general[[:space:]]'; then
  collections_installed=true
fi

if ! command -v ansible-playbook >/dev/null 2>&1; then
  skip "ansible-playbook not installed"
elif [[ "${collections_installed}" != true ]]; then
  skip "ansible checks (run: ansible-galaxy collection install -r ansible/requirements.yml)"
else
  for playbook in "${PLAYBOOKS[@]}"; do
    if ansible-playbook -i ansible/inventory.example.yml \
         --syntax-check "${playbook}" >/dev/null 2>&1; then
      pass "syntax-check ${playbook}"
    else
      fail "syntax-check ${playbook}"
      ansible-playbook -i ansible/inventory.example.yml \
        --syntax-check "${playbook}" 2>&1 | tail -20 || true
    fi
  done

  if ! command -v ansible-lint >/dev/null 2>&1; then
    skip "ansible-lint not installed"
  elif ansible-lint "${PLAYBOOKS[@]}"; then
    pass "ansible-lint"
  else
    fail "ansible-lint"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n== summary\n'
printf '  %d failed, %d skipped\n' "${failures}" "${skips}"

if [[ "${skips}" -gt 0 ]]; then
  printf '  run scripts/validate.sh --install-tools to cover the skips\n'
fi

[[ "${failures}" -eq 0 ]]
