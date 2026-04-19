#!/usr/bin/env bash
set -euo pipefail

trap 'printf "[arroz] setup failed on line %s\n" "${BASH_LINENO[0]}" >&2' ERR

log() {
  printf '[arroz] %s\n' "$*"
}

main() {
  log "Bootstrap entrypoint reached."
  log "This installer is still a scaffold."
  log "Replace this stub with your Arch package, config, and service setup steps."
}

main "$@"
