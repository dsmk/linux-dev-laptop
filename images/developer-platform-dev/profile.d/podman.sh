# shellcheck shell=bash
#
# Installed as /etc/profile.d/podman.sh. Sourced, not executed, so it
# deliberately has no shebang.
#
# Points the in-container podman client at the host's rootless podman
# socket when toolbx/distrobox has forwarded one.

if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  PODMAN_SOCKET="$XDG_RUNTIME_DIR/podman/podman.sock"

  if [[ -S "$PODMAN_SOCKET" ]]; then
    export CONTAINER_HOST="unix://$PODMAN_SOCKET"
  else
    unset CONTAINER_HOST
  fi
fi
