#!/usr/bin/env bash
# Runs one source's import through import.sh with a deterministic environment.
#
#   run-import.sh <source> [import.sh arguments...]
#   run-import.sh entra start
#   run-import.sh hr status --receipt /srv/autonox/import-receipts/<id>/latest
#
# One import run imports one source system. This wrapper owns the only thing
# import.sh deliberately does not: the convention that maps a source name to a
# set of settings. import.sh stays a pure env-driven driver with no filesystem
# conventions of its own.
#
# Composition, in order, all from $AUTONOX_HOME:
#
#   images.env            image digests, shared with the warehouse workload
#   import.env            deployment-wide settings
#   sources/<source>.env  this source's settings
#
# The command runs with an ERASED environment (env -i) plus a small allow-list,
# so composition is identical from an interactive shell, cron, and systemd —
# and nothing leaks between two sources run back to back. That leak is not
# theoretical: `set -a; source a.env; source b.env` accumulates, so any variable
# the first source sets and the second does not is still live.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

usage() {
  cat <<'EOF'
Usage:
  run-import.sh <source> [import.sh arguments...]

Arguments after the source name are passed to import.sh unchanged; with none,
it runs `start`.

Requires AUTONOX_HOME. Reads $AUTONOX_HOME/images.env (optional),
$AUTONOX_HOME/import.env, and $AUTONOX_HOME/sources/<source>.env.

Environment variables passed through the isolation barrier: PATH, HOME,
AUTONOX_HOME, TERM, TZ, LANG, LC_ALL, DOCKER_HOST, DOCKER_CONTEXT,
CONTAINER_HOST, XDG_RUNTIME_DIR, SSL_CERT_FILE, SSL_CERT_DIR, and any name
listed in IMPORT_PASSTHROUGH_ENV (space-separated).
EOF
}

# ── Second phase ────────────────────────────────────────────────────────────
# Re-entered through `env -i` below. Everything here runs with the erased
# environment, which is the point: this is the only place settings are sourced.
if [[ "${AUTONOX_IMPORT_ISOLATED:-0}" == "1" ]]; then
  unset AUTONOX_IMPORT_ISOLATED
  source_name="$1"; shift

  set -a
  # Optional: a deployment may keep image digests in import.env instead.
  # import.sh fails clearly if they end up unset either way.
  [[ -f "${AUTONOX_HOME}/images.env" ]] && . "${AUTONOX_HOME}/images.env"
  . "${AUTONOX_HOME}/import.env"
  . "${AUTONOX_HOME}/sources/${source_name}.env"
  set +a

  [[ -n "${WORKSPACE_ID:-}" ]] || die "WORKSPACE_ID is unset after sourcing; check ${AUTONOX_HOME}/import.env"

  # Silver takes one lock per workspace — silver_workspace_locks has
  # workspace_id as its PRIMARY KEY — so two sources importing into the same
  # workspace cannot overlap, and the loser fails rather than waiting. This
  # flock makes a late-running import queue instead of colliding.
  #
  # It is a convenience, not the authority: the database lock is what actually
  # protects Silver, and it still applies across hosts, where this file cannot.
  # A host without flock therefore degrades to the database behaviour.
  lock_dir="${AUTONOX_HOME}/var/locks"
  lock_file="${lock_dir}/import-${WORKSPACE_ID}.lock"
  if command -v flock >/dev/null 2>&1; then
    mkdir -p "$lock_dir"
    exec {lock_fd}>"$lock_file" || die "cannot open lock file: $lock_file"
    # Held across the exec below: the descriptor survives, so the lock is held
    # for as long as import.sh runs.
    flock "$lock_fd" || die "cannot acquire lock: $lock_file"
  else
    printf 'note: flock is unavailable — concurrent imports into %s will collide on the Silver workspace lock instead of queueing\n' \
      "$WORKSPACE_ID" >&2
  fi

  exec "${SCRIPT_DIR}/import.sh" "$@"
fi

# ── First phase ─────────────────────────────────────────────────────────────
# Validate before erasing the environment, so failures name a file rather than
# surfacing as an unset variable inside the isolated shell.

case "${1:-}" in
  -h|--help|help|'') usage; [[ -n "${1:-}" ]] && exit 0 || exit 2 ;;
esac

SOURCE="$1"; shift
[[ "$SOURCE" != -* ]] || die "first argument must be a source name, not an option: $SOURCE"
[[ $# -gt 0 ]] || set -- start

[[ -n "${AUTONOX_HOME:-}" ]] || die "set AUTONOX_HOME (settings live in \$AUTONOX_HOME/import.env and \$AUTONOX_HOME/sources/)"
[[ -d "$AUTONOX_HOME" ]] || die "AUTONOX_HOME is not a directory: $AUTONOX_HOME"

IMPORT_ENV="${AUTONOX_HOME}/import.env"
SOURCE_ENV="${AUTONOX_HOME}/sources/${SOURCE}.env"

[[ -f "$IMPORT_ENV" ]] || die "deployment settings not found: $IMPORT_ENV"
if [[ ! -f "$SOURCE_ENV" ]]; then
  available="$(cd "${AUTONOX_HOME}/sources" 2>/dev/null && ls -1 ./*.env 2>/dev/null | sed 's|^\./||; s|\.env$||' | tr '\n' ' ' || true)"
  die "unknown source: ${SOURCE} (no ${SOURCE_ENV})${available:+ — available: ${available}}"
fi
[[ -x "${SCRIPT_DIR}/import.sh" ]] || die "import.sh is not executable: ${SCRIPT_DIR}/import.sh"

# Rebuilt rather than inherited. A scheduler's environment is not something to
# depend on: cron's is nearly empty, systemd's is whatever the unit declares.
passthrough=(AUTONOX_IMPORT_ISOLATED=1 "AUTONOX_HOME=${AUTONOX_HOME}")
for name in PATH HOME TERM TZ LANG LC_ALL DOCKER_HOST DOCKER_CONTEXT \
            CONTAINER_HOST XDG_RUNTIME_DIR SSL_CERT_FILE SSL_CERT_DIR \
            ${IMPORT_PASSTHROUGH_ENV:-}; do
  [[ -n "${!name:-}" ]] && passthrough+=("${name}=${!name}")
done

exec env -i "${passthrough[@]}" "${BASH_SOURCE[0]}" "$SOURCE" "$@"
