#!/usr/bin/env bash

set -euo pipefail

PODMAN_MACHINE="${PODMAN_MACHINE:-podman-machine-default}"
PODMAN_CPUS="${PODMAN_CPUS:-6}"
PODMAN_MEMORY="${PODMAN_MEMORY:-8192}"
CONTAINER_NAME="${CONTAINER_NAME:-microshift-okd}"
OWNER="${OWNER:-microshift-io}"
REPO="${REPO:-microshift}"
TAG="${TAG:-latest}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args...]

Commands:
  start           Configure/start the Podman machine and bootstrap or reuse MicroShift
  stop            Remove the MicroShift container and cluster resources
  shutdown        Stop MicroShift and then stop the Podman machine
  status          Show Podman machine state and MicroShift cluster status
  kubectl ...     Run kubectl inside the MicroShift container
  shell           Open an interactive shell in the MicroShift container
  help            Show this help

Environment overrides:
  PODMAN_MACHINE  Podman machine name (default: podman-machine-default)
  PODMAN_CPUS     Podman machine CPUs (default: 6)
  PODMAN_MEMORY   Podman machine memory in MiB (default: 8192)
  CONTAINER_NAME  MicroShift container name (default: microshift-okd)
  OWNER           MicroShift GitHub owner for quickstart scripts (default: microshift-io)
  REPO            MicroShift GitHub repo for quickstart scripts (default: microshift)
  TAG             MicroShift image tag (default: latest)

Notes:
  - This helper is for macOS with Podman machine.
  - It intentionally uses 'sudo podman exec ... kubectl ...' because the
    kubeconfig generated inside the MicroShift container points at localhost:6443.
EOF
}

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
}

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This helper currently supports macOS only." >&2
    exit 1
  fi
}

run_quickstart() {
  curl -fsSL "https://${OWNER}.github.io/${REPO}/quickstart.sh" \
    | sudo env \
        SUDO_USER="${USER}" \
        OWNER="${OWNER}" \
        REPO="${REPO}" \
        TAG="${TAG}" \
        CONTAINER_NAME="${CONTAINER_NAME}" \
        bash
}

run_quickclean() {
  curl -fsSL "https://${OWNER}.github.io/${REPO}/quickclean.sh" \
    | sudo env \
        OWNER="${OWNER}" \
        REPO="${REPO}" \
        CONTAINER_NAME="${CONTAINER_NAME}" \
        bash
}

machine_exists() {
  podman machine inspect "${PODMAN_MACHINE}" >/dev/null 2>&1
}

ensure_machine() {
  if ! machine_exists; then
    echo "Podman machine '${PODMAN_MACHINE}' does not exist." >&2
    echo "Create it first with: podman machine init ${PODMAN_MACHINE}" >&2
    exit 1
  fi

  podman machine stop "${PODMAN_MACHINE}" >/dev/null 2>&1 || true
  podman machine set \
    --rootful \
    --cpus "${PODMAN_CPUS}" \
    --memory "${PODMAN_MEMORY}" \
    "${PODMAN_MACHINE}"
  podman machine start "${PODMAN_MACHINE}"
}

container_exists() {
  sudo podman container exists "${CONTAINER_NAME}" >/dev/null 2>&1
}

container_running() {
  sudo podman inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -qx "true"
}

cmd_start() {
  require_macos
  require_tool podman
  require_tool curl
  require_tool sudo

  ensure_machine

  if container_running; then
    echo "MicroShift container '${CONTAINER_NAME}' is already running."
  elif container_exists; then
    echo "Reusing existing MicroShift container '${CONTAINER_NAME}'."
    sudo podman start "${CONTAINER_NAME}" >/dev/null
  else
    echo "Bootstrapping a new MicroShift container '${CONTAINER_NAME}'."
    run_quickstart
  fi

  cmd_status
}

cmd_stop() {
  require_tool curl
  require_tool sudo

  if container_exists; then
    run_quickclean
  else
    echo "MicroShift container '${CONTAINER_NAME}' does not exist."
  fi
}

cmd_shutdown() {
  cmd_stop || true
  podman machine stop "${PODMAN_MACHINE}" >/dev/null 2>&1 || true
  echo "Podman machine '${PODMAN_MACHINE}' stopped."
}

cmd_status() {
  require_tool podman
  require_tool sudo

  echo "== Podman machine =="
  podman machine inspect "${PODMAN_MACHINE}" | jq '.[0] | {Name,State,Rootful,Resources,LastUp}'

  echo
  echo "== MicroShift container =="
  if container_exists; then
    sudo podman ps -a --filter "name=${CONTAINER_NAME}"
  else
    echo "Container '${CONTAINER_NAME}' not found."
    return 0
  fi

  if ! container_running; then
    echo
    echo "Container '${CONTAINER_NAME}' is not running."
    return 0
  fi

  echo
  echo "== Cluster nodes =="
  sudo podman exec "${CONTAINER_NAME}" kubectl get nodes

  echo
  echo "== Cluster pods =="
  sudo podman exec "${CONTAINER_NAME}" kubectl get pods -A
}

cmd_kubectl() {
  require_tool sudo
  if [[ $# -eq 0 ]]; then
    echo "Usage: $(basename "$0") kubectl <args...>" >&2
    exit 1
  fi
  sudo podman exec "${CONTAINER_NAME}" kubectl "$@"
}

cmd_shell() {
  require_tool sudo
  sudo podman exec -it "${CONTAINER_NAME}" /bin/bash -l
}

main() {
  require_tool jq

  local cmd="${1:-help}"
  shift || true

  case "${cmd}" in
    start)
      cmd_start "$@"
      ;;
    stop)
      cmd_stop "$@"
      ;;
    shutdown)
      cmd_shutdown "$@"
      ;;
    status)
      cmd_status "$@"
      ;;
    kubectl)
      cmd_kubectl "$@"
      ;;
    shell)
      cmd_shell "$@"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Unknown command: ${cmd}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
