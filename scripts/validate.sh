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

readonly FLAVOURS=(toolbx distrobox)

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
group "package manifests"
# ---------------------------------------------------------------------------
# Strip comments and blanks the same way containers/dev/Containerfile does.
manifest_entries() {
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$1" | grep -v '^$'
}

all_manifests=(containers/packages/common.txt)
for flavour in "${FLAVOURS[@]}"; do
  all_manifests+=("containers/packages/${flavour}.txt")
done

for manifest in "${all_manifests[@]}"; do
  if [[ ! -f "${manifest}" ]]; then
    fail "${manifest} is missing"
    continue
  fi

  entries="$(manifest_entries "${manifest}")"

  if [[ -z "${entries}" ]]; then
    fail "${manifest} lists no packages"
    continue
  fi

  if duplicates="$(printf '%s\n' "${entries}" | sort | uniq -d)" \
     && [[ -n "${duplicates}" ]]; then
    fail "${manifest} has duplicates: ${duplicates//$'\n'/ }"
  else
    pass "${manifest} has no duplicates"
  fi

  if diff -q <(printf '%s\n' "${entries}") \
             <(printf '%s\n' "${entries}" | LC_ALL=C sort) >/dev/null; then
    pass "${manifest} is sorted"
  else
    fail "${manifest} is not sorted (LC_ALL=C sort)"
    diff <(printf '%s\n' "${entries}") \
         <(printf '%s\n' "${entries}" | LC_ALL=C sort) | head -10
  fi

  if bad="$(printf '%s\n' "${entries}" | grep -vE '^[A-Za-z0-9][A-Za-z0-9._+-]*$')" \
     && [[ -n "${bad}" ]]; then
    fail "${manifest} has implausible package names: ${bad//$'\n'/ }"
  else
    pass "${manifest} package names look like RPM names"
  fi
done

# A package in both common.txt and a flavour list would be installed twice and
# is a sign the lists have drifted.
for flavour in "${FLAVOURS[@]}"; do
  manifest="containers/packages/${flavour}.txt"
  [[ -f "${manifest}" ]] || continue
  if overlap="$(comm -12 \
        <(manifest_entries containers/packages/common.txt | LC_ALL=C sort) \
        <(manifest_entries "${manifest}" | LC_ALL=C sort))" \
     && [[ -n "${overlap}" ]]; then
    fail "${flavour} repeats packages from common.txt: ${overlap//$'\n'/ }"
  else
    pass "${flavour} does not repeat common.txt"
  fi
done

# ---------------------------------------------------------------------------
group "Containerfile"
# ---------------------------------------------------------------------------
readonly CONTAINERFILE=containers/dev/Containerfile

if [[ -f "${CONTAINERFILE}" ]]; then
  pass "${CONTAINERFILE} exists"

  # Every version installed from outside dnf must be pinned, so a rebuild of
  # an old commit produces the same image.
  for arg in KUBECTL_VERSION ARGOCD_VERSION OT_VERSION; do
    if grep -qE "^ARG ${arg}=.+" "${CONTAINERFILE}"; then
      pass "${arg} is pinned"
    else
      fail "${arg} is not pinned in ${CONTAINERFILE}"
    fi
  done

  if grep -qE '^ARG DNF_BASEURL=$' "${CONTAINERFILE}"; then
    pass "DNF_BASEURL defaults to empty"
  else
    fail "ARG DNF_BASEURL must default to empty; a pinned mirror changes image contents"
  fi

  if grep -qE '^ARG PROXY_CA_CERT=$' "${CONTAINERFILE}"; then
    pass "PROXY_CA_CERT defaults to empty"
  else
    fail "ARG PROXY_CA_CERT must default to empty; no CA is baked into published images"
  fi

  if grep -qE '^ARG BASE_IMAGE=.*:[A-Za-z0-9._-]+$' "${CONTAINERFILE}"; then
    pass "BASE_IMAGE carries an explicit tag"
  else
    fail "BASE_IMAGE must name an explicit tag, not a floating one"
  fi

  if grep -qE '^(FROM|ARG BASE_IMAGE=).*:latest' "${CONTAINERFILE}"; then
    fail "${CONTAINERFILE} refers to a :latest tag"
  else
    pass "no :latest tags"
  fi

  if grep -q 'com.github.containers.toolbox="true"' "${CONTAINERFILE}"; then
    pass "toolbx label is set"
  else
    fail "com.github.containers.toolbox=true label is missing; toolbx will refuse the image"
  fi
else
  fail "${CONTAINERFILE} is missing"
fi

# Both flavours must be buildable from this checkout.
if [[ -x containers/build.sh ]]; then
  for flavour in "${FLAVOURS[@]}"; do
    if containers/build.sh --flavor "${flavour}" --dry-run >/dev/null 2>&1; then
      pass "containers/build.sh --flavor ${flavour} resolves"
    else
      # A missing engine is an environment problem, not a repository one.
      if ! command -v podman >/dev/null 2>&1 \
         && ! command -v docker >/dev/null 2>&1; then
        skip "containers/build.sh --flavor ${flavour} (no container engine)"
      else
        fail "containers/build.sh --flavor ${flavour} fails"
        containers/build.sh --flavor "${flavour}" --dry-run || true
      fi
    fi
  done
else
  fail "containers/build.sh is missing or not executable"
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
