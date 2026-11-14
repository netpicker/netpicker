#!/usr/bin/env bash
#
# Restore the Docker volumes of the Netpicker stack from a tar file made by
# ./backup.sh. Replaces the contents of every volume in the backup.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./restore.sh [options] [BACKUP.tar]

Stops the Netpicker stack and replaces the contents of the Docker volumes in
BACKUP.tar (default: the newest netpicker_backup*.tar in this directory) with
the contents of the backup. Start the stack again with 'docker compose up -d'.

Options:
  -p, --project NAME   Docker Compose project name (default: auto-detect)
      --no-stop        do not stop the stack first (it must be stopped already)
  -y, --yes            do not ask for confirmation
  -h, --help           show this help
EOF
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT=
BACKUP=
STOP=1
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -p | --project) PROJECT=${2:?--project needs a value}; shift ;;
        --no-stop) STOP=0 ;;
        -y | --yes) ASSUME_YES=1 ;;
        -h | --help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) BACKUP=$1 ;;
    esac
    shift
done

die() {
    echo "ERROR: $*" >&2
    exit 1
}

detect_project() {
    local p
    p=${COMPOSE_PROJECT_NAME:-}
    if [ -z "$p" ] && [ -f "$SCRIPT_DIR/.env" ]; then
        p=$(sed -n 's/^[[:space:]]*COMPOSE_PROJECT_NAME[[:space:]]*=[[:space:]]*["'\'']*\([^"'\'' ]*\).*/\1/p' "$SCRIPT_DIR/.env" | tail -n 1)
    fi
    [ -n "$p" ] || p=$(basename "$SCRIPT_DIR")
    printf '%s\n' "$p" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

pick_image() {
    local img
    for img in netpicker/db:latest netpicker/api:latest; do
        if docker image inspect "$img" >/dev/null 2>&1; then
            echo "$img"
            return
        fi
    done
    docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^netpicker/(db|api)' | head -n 1
}

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon; run this as a user in the docker group"
[ -n "$PROJECT" ] || PROJECT=$(detect_project)
if [ -z "$BACKUP" ]; then
    # shellcheck disable=SC2012
    BACKUP=$(ls -t "$SCRIPT_DIR"/netpicker_backup*.tar 2>/dev/null | head -n 1)
    [ -n "$BACKUP" ] || die "no netpicker_backup*.tar in $SCRIPT_DIR; give the backup file as argument"
fi
[ -f "$BACKUP" ] || die "$BACKUP not found"

# the volumes are the top-level directories in the tar: ./<volume>/...
VOLUMES=$(tar -tf "$BACKUP" | sed -n 's#^\(\./\)\{0,1\}\([^/][^/]*\)/.*#\2#p' | grep -E '^[A-Za-z0-9][A-Za-z0-9_.-]*$' | sort -u)
[ -n "$VOLUMES" ] || die "$BACKUP holds no volumes"

echo "Restoring $BACKUP into these volumes; their current contents are deleted:"
# shellcheck disable=SC2086
printf '  %s\n' $VOLUMES
if [ $ASSUME_YES -eq 0 ]; then
    printf 'This stops Netpicker (project %s) and cannot be undone. Continue? [y/N] ' "$PROJECT"
    read -r answer </dev/tty || answer=
    case "$answer" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac
fi

running=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT")
if [ -n "$running" ]; then
    [ $STOP -eq 1 ] || die "containers of project '$PROJECT' are running; stop them first"
    echo "Stopping the stack ..."
    (cd "$SCRIPT_DIR" && docker compose -p "$PROJECT" down)
fi

mounts=()
for v in $VOLUMES; do
    if ! docker volume inspect "$v" >/dev/null 2>&1; then
        if [ "${v#"${PROJECT}_"}" != "$v" ]; then
            # the labels Docker Compose gives the volumes it creates
            docker volume create --label "com.docker.compose.project=$PROJECT" \
                --label "com.docker.compose.volume=${v#"${PROJECT}_"}" "$v" >/dev/null
        else
            docker volume create "$v" >/dev/null
        fi
    fi
    mounts+=(-v "$v:/restore/$v")
done

IMAGE=$(pick_image)
[ -n "$IMAGE" ] || die "no Netpicker image on this host to write the volumes with"

echo "Restoring ..."
# shellcheck disable=SC2016
docker run --rm -i --network none -u 0 --entrypoint sh "${mounts[@]}" "$IMAGE" -c '
    set -e
    for d in /restore/*; do find "$d" -mindepth 1 -delete; done
    tar --numeric-owner -xpf - -C /restore' <"$BACKUP"

echo "Restore completed. Start Netpicker again with: docker compose up -d"
