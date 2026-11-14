#!/usr/bin/env bash
#
# Back up the Docker volumes of the Netpicker stack into one tar file.
#
# Stops the stack first (unless --no-stop), so the database files in the tar
# are consistent. The volumes are read by a throw-away container, so this
# needs no sudo and also works with Docker Desktop and rootless Docker.
# Restore the tar with ./restore.sh.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./backup.sh [options]

Stops the Netpicker stack and writes the contents of its Docker volumes to
netpicker_backup-YYYYmmdd-HHMMSS.tar in this directory. Start the stack again
with 'docker compose up -d'; restore the backup with ./restore.sh.

Options:
  -p, --project NAME   Docker Compose project name (default: auto-detect)
  -o, --output FILE    write the backup to FILE
      --no-stop        do not stop the stack first (it must be stopped already,
                       or the database files in the backup may be inconsistent)
  -y, --yes            do not ask for confirmation
  -h, --help           show this help
EOF
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT=
OUTPUT=
STOP=1
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        -p | --project) PROJECT=${2:?--project needs a value}; shift ;;
        -o | --output) OUTPUT=${2:?--output needs a value}; shift ;;
        --no-stop) STOP=0 ;;
        -y | --yes) ASSUME_YES=1 ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# the project name as Docker Compose derives it
detect_project() {
    local p
    p=${COMPOSE_PROJECT_NAME:-}
    if [ -z "$p" ] && [ -f "$SCRIPT_DIR/.env" ]; then
        p=$(sed -n 's/^[[:space:]]*COMPOSE_PROJECT_NAME[[:space:]]*=[[:space:]]*["'\'']*\([^"'\'' ]*\).*/\1/p' "$SCRIPT_DIR/.env" | tail -n 1)
    fi
    [ -n "$p" ] || p=$(basename "$SCRIPT_DIR")
    printf '%s\n' "$p" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

# an image with tar that is already on this host: the database image of the
# stack, or else any Netpicker image
pick_image() {
    local img
    for img in $(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
        --filter label=com.docker.compose.service=db --format '{{.Image}}') \
        netpicker/db:latest netpicker/api:latest; do
        if docker image inspect "$img" >/dev/null 2>&1; then
            echo "$img"
            return
        fi
    done
    docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^netpicker/(db|api)' | head -n 1
}

# the size of the volumes in KiB, from 'docker system df -v'
volumes_kib() {
    docker system df -v 2>/dev/null | awk -v list=" $* " '
        function kib(s,   n, u) {
            n = s + 0; u = s; sub(/^[0-9.]+/, "", u)
            if (u == "kB" || u == "KB") return n
            if (u == "MB") return n * 1000
            if (u == "GB") return n * 1000 * 1000
            if (u == "TB") return n * 1000 * 1000 * 1000
            return n / 1000
        }
        /^Local Volumes space usage/ { on = 1; next }
        /space usage:/ { on = 0 }
        on && index(list, " " $1 " ") { t += kib($NF) }
        END { printf "%d\n", t * 1000 / 1024 }'
}

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon; run this as a user in the docker group"
[ -n "$PROJECT" ] || PROJECT=$(detect_project)
[ -n "$OUTPUT" ] || OUTPUT="$SCRIPT_DIR/netpicker_backup-$(date +%Y%m%d-%H%M%S).tar"

VOLUMES=$( {
    docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT"
    # volumes of older Docker Compose versions have no labels
    docker volume ls -q | grep "^${PROJECT}_" || true
} | sort -u)
[ -n "$VOLUMES" ] || die "no volumes of the Docker Compose project '$PROJECT' found; give the project name with -p"

echo "Volumes of project '$PROJECT':"
# shellcheck disable=SC2086
printf '  %s\n' $VOLUMES

out_dir=$(cd "$(dirname "$OUTPUT")" && pwd) || die "the directory of $OUTPUT does not exist"
OUTPUT="$out_dir/$(basename "$OUTPUT")"
# shellcheck disable=SC2086
need=$(volumes_kib $VOLUMES)
avail=$(df -Pk "$out_dir" | awk 'NR == 2 { print $4 }')
echo "The volumes hold about $((need / 1024)) MiB; $((avail / 1024)) MiB is free in $out_dir."
if [ "${need:-0}" -gt 0 ] && [ "$avail" -lt $((need + need / 10 + 102400)) ]; then
    die "not enough free space in $out_dir for the backup; free some space or write it elsewhere with -o"
fi

running=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT")
if [ $STOP -eq 1 ] && [ -n "$running" ]; then
    if [ $ASSUME_YES -eq 0 ]; then
        printf 'This stops Netpicker (project %s) for the backup. Continue? [y/N] ' "$PROJECT"
        read -r answer </dev/tty || answer=
        case "$answer" in [yY]*) ;; *) echo "Aborted."; exit 1 ;; esac
    fi
    echo "Stopping the stack ..."
    (cd "$SCRIPT_DIR" && docker compose -p "$PROJECT" down)
elif [ -n "$running" ]; then
    echo "WARNING: containers of project '$PROJECT' are running; the database files in the backup may be inconsistent" >&2
fi

IMAGE=$(pick_image)
[ -n "$IMAGE" ] || die "no Netpicker image on this host to read the volumes with"

mounts=()
for v in $VOLUMES; do
    mounts+=(-v "$v:/backup/$v:ro")
done

echo "Writing $OUTPUT ..."
# tar writes to stdout, so the file belongs to this user and needs no bind
# mount (which SELinux or Docker Desktop file sharing could refuse)
if ! docker run --rm -i --network none -u 0 --entrypoint tar "${mounts[@]}" "$IMAGE" \
    --numeric-owner -cf - -C /backup . >"$OUTPUT.partial"; then
    rm -f "$OUTPUT.partial"
    die "the backup failed"
fi
mv "$OUTPUT.partial" "$OUTPUT"

echo "Backup completed: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
if [ $STOP -eq 1 ] && [ -n "$running" ]; then
    echo "Start Netpicker again with: docker compose up -d"
fi
