#!/usr/bin/env bash
#
# Install the VS Code extensions listed in
# /usr/share/developer-platform/extensions.txt into the current user's home.
#
# They are not baked into the image because toolbx and distrobox mount the
# host's home directory over the image's, which would shadow
# $HOME/.vscode/extensions. Run this once in a new container:
#
#   dev-install-extensions
#
# It is idempotent: VS Code skips an extension that is already present.

set -euo pipefail

readonly LIST=/usr/share/developer-platform/extensions.txt

if [[ ! -r "${LIST}" ]]; then
  echo "missing extension list: ${LIST}" >&2
  exit 1
fi

mapfile -t extensions < <(
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "${LIST}" | grep -v '^$'
)

if [[ "${#extensions[@]}" -eq 0 ]]; then
  echo "no extensions listed in ${LIST}"
  exit 0
fi

echo "installing ${#extensions[@]} VS Code extensions into ${HOME}"

code_args=(--force)

# VS Code refuses to start as a super user without these. Running as root is
# not how this is normally used -- an interactive toolbx or distrobox session
# is the developer's own account -- but it is how the image gets exercised in
# a container, and failing there with VS Code's own message is unhelpful.
if [[ "$(id -u)" == "0" ]]; then
  code_args+=(--no-sandbox --user-data-dir="$(mktemp -d)")
fi

failed=()
for extension in "${extensions[@]}"; do
  if code --install-extension "${extension}" "${code_args[@]}"; then
    printf '  ok      %s\n' "${extension}"
  else
    printf '  FAILED  %s\n' "${extension}"
    failed+=("${extension}")
  fi
done

if [[ "${#failed[@]}" -gt 0 ]]; then
  echo "could not install: ${failed[*]}" >&2
  exit 1
fi

echo "done"
