if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
  PODMAN_SOCKET="$XDG_RUNTIME_DIR/podman/podman.sock"

  if [[ -S "$PODMAN_SOCKET" ]]; then
    export CONTAINER_HOST="unix://$PODMAN_SOCKET"
  else
    unset CONTAINER_HOST
  fi
fi