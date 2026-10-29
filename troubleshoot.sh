#!/usr/bin/env bash
#
# Troubleshoot a running Netpicker Docker Compose stack.
#
# Checks the host (uptime, load, CPU, memory, disk space), that the Netpicker
# version that runs is the release of this git repo, that all services are up,
# healthy and within their resource limits, what the local changes to the repo
# do to the stack and whether the containers match the compose files, that the
# database is at the alembic revision the api image expects, that the
# containers can reach each other, that the agents in the database are
# connected and set up for the compose stack they run in, that the celery task
# queues in redis are not stuck, that the git working copies in the policy
# workdir have no old uncommitted files or stale locks, how the last backup and
# policy run of the devices went and that the container logs are free of errors.
#
# Run it on the Docker host as a user that can access the Docker daemon. It
# only reads state; when the api container is down it starts a throw-away
# copy of the api image (without network) to read the alembic revisions.
# With --clear-queues it does not check anything, but deletes the waiting and
# in-flight tasks from the celery task queues in redis. With --reset-workdir
# it does not check anything either, but discards the uncommitted files and
# stale git locks left behind in the git repos of the policy workdir with git
# reset --hard.

set -o pipefail

usage() {
    cat <<'EOF'
Usage: ./troubleshoot.sh [options]

Checks a running Netpicker Docker stack: host uptime, CPU, memory and disk
space, the Netpicker version against the release tags of this repo,
containers with their health checks and resource limits, local changes to
this repo and whether the containers match the compose files, the database
migration (alembic) revision, connectivity between containers, the agents
(connected, in this compose stack or elsewhere, sharing the redis and
kibbitzer of the stack), the redis task queues, uncommitted files in the git
repos of the policy workdir, the last backup and policy run of every device
and errors in the container logs.

With --clear-queues it deletes the waiting and in-flight tasks from the redis
task queues instead, after it asked for confirmation. Use it when backups and
policy runs stay scheduled while kibbitzer and committer are idle: the tasks
in the queues are lost or stuck, and the next scheduled runs start afresh.

With --reset-workdir it discards the uncommitted files in the git repos of the
policy workdir instead, with git reset --hard and git clean, after it asked
for confirmation. Use it when the check reports uncommitted files that a
backup or policy run left behind over an hour ago and that are not needed: the
files are lost. It skips repos with newer files, a running git command or a
rebase, and keeps the commits that are not pushed to gitd. Repos with stale
locks get a question of their own: git leaves a lock file behind when it is
killed, and refuses to work in the repo until the file is removed, so nothing
commits the files there. It removes the locks older than 10 minutes, then
resets the repo, whatever the age of its files.

Options:
  -p, --project NAME     Docker Compose project name (default: auto-detect)
  -s, --since DURATION   how far back to scan the logs, in "docker logs --since"
                         format, e.g. 30m, 6h or 2026-01-31T12:00:00 (default: 1h)
  -i, --interval SECS    how long to watch the task queues (default: 15)
      --task-age SECS    warn about tasks unacknowledged, and device backups
                         and policy runs unfinished, for longer than this
                         (default: 3600)
      --ignore REGEX     ignore log lines matching the extended regex REGEX;
                         can be given more than once
  -b, --bundle           also write a support bundle (.tar.gz) to the current
                         directory with logs, container details, redis and
                         migration state; secrets are masked on a best-effort basis
  -v, --verbose          show more log lines per container
      --clear-queues     delete all waiting and in-flight tasks from the celery
                         task queues in redis, then exit; runs no checks
      --reset-workdir    discard the uncommitted files and stale git locks left
                         behind in the git repos of the policy workdir with git
                         reset --hard and git clean, then exit; runs no checks
  -y, --yes              clear the queues or reset the repos without asking for
                         confirmation
      --no-color         disable colored output
  -h, --help             show this help

Exit status: 0 all checks passed, 1 warnings, 2 failures, 3 could not run.
With --clear-queues or --reset-workdir: 0 done or nothing to do, 3 could not run.
EOF
}

PROJECT="${COMPOSE_PROJECT_NAME:-}"
SINCE=1h
INTERVAL=15
TASK_AGE=3600
IGNORE_RE=
BUNDLE=0
VERBOSE=0
COLOR=auto
CLEAR_QUEUES=0
RESET_WORKDIR=0
ASSUME_YES=0
# the -p option, repeated in the commands the advice gives
PROJECT_OPT=

REQUIRED_SERVICES="db redis minio gitd gitdctrl api celery committer agent kibbitzer frontend"
OPTIONAL_SERVICES="swagger cadvisor syslog-ng"
# one-shot services, checked by their own section
ONESHOT_SERVICES="db_migration"

# images of agents, also in other registries, e.g. netpicker/agent:2.8.1
AGENT_IMAGE_RE='(^|/)agent([:@]|$)'
# the AGENT_ID of an agent that does not set it: the id of the agent G7 that
# the api creates
DEFAULT_AGENT_ID=DrkSpy
# agents send a heartbeat every 10 seconds; count an agent as connected when
# its last heartbeat is this recent and redis cannot tell
AGENT_BEAT_AGE=60

INSPECT_TIMEOUT=2
BUNDLE_LOG_TAIL=20000

# resource thresholds in percent
DISK_WARN=85
DISK_FAIL=95
MEM_WARN=90
MEM_FAIL=95
CPU_WARN=90
# report uncommitted files and unpushed commits in the policy workdir older than this
WORKDIR_AGE=3600

# release versions in git and image tags, e.g. 2.8.1; VERSION_RE also matches
# pre-releases such as 2.8.1-rc
RELEASE_RE='^v?[0-9]+(\.[0-9]+)+$'
VERSION_RE='^v?[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.-]+)?$'

SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
case "$0" in
    */*) SELF=$0 ;;
    *) SELF=./$0 ;;
esac

need_value() {
    if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "Option $1 needs a value" >&2
        exit 3
    fi
}

need_number() {
    case "$2" in
        '' | *[!0-9]*)
            echo "Option $1 needs a number, got '$2'" >&2
            exit 3
            ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p | --project) need_value "$@"; PROJECT=$2; PROJECT_OPT=" -p $2"; shift 2 ;;
        -s | --since) need_value "$@"; SINCE=$2; shift 2 ;;
        -i | --interval) need_value "$@"; need_number "$1" "$2"; INTERVAL=$2; shift 2 ;;
        --task-age) need_value "$@"; need_number "$1" "$2"; TASK_AGE=$2; shift 2 ;;
        --ignore) need_value "$@"; IGNORE_RE="${IGNORE_RE:+$IGNORE_RE|}($2)"; shift 2 ;;
        -b | --bundle) BUNDLE=1; shift ;;
        -v | --verbose) VERBOSE=1; shift ;;
        --clear-queues) CLEAR_QUEUES=1; shift ;;
        --reset-workdir) RESET_WORKDIR=1; shift ;;
        -y | --yes) ASSUME_YES=1; shift ;;
        --no-color) COLOR=no; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
    esac
done
if [ $CLEAR_QUEUES -eq 1 ] && [ $RESET_WORKDIR -eq 1 ]; then
    echo "Options --clear-queues and --reset-workdir do not go together" >&2
    exit 3
fi
if [ $CLEAR_QUEUES -eq 1 ] && [ $BUNDLE -eq 1 ]; then
    echo "Options --clear-queues and --bundle do not go together" >&2
    exit 3
fi
if [ $RESET_WORKDIR -eq 1 ] && [ $BUNDLE -eq 1 ]; then
    echo "Options --reset-workdir and --bundle do not go together" >&2
    exit 3
fi

# ---------------------------------------------------------------------------
# output

ESC=$(printf '\033')
TAB=$(printf '\t')

if [ "$COLOR" = auto ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR=yes
fi
if [ "$COLOR" = yes ]; then
    C_RED="$ESC[31m" C_GREEN="$ESC[32m" C_YELLOW="$ESC[33m" C_CYAN="$ESC[36m"
    C_BOLD="$ESC[1m" C_DIM="$ESC[2m" C_RESET="$ESC[0m"
else
    C_RED= C_GREEN= C_YELLOW= C_CYAN= C_BOLD= C_DIM= C_RESET=
fi

N_PASS=0
N_WARN=0
N_FAIL=0
FAIL_LIST=
WARN_LIST=
REPORT_FILE=

say() {
    printf '%s\n' "$*"
    if [ -n "$REPORT_FILE" ]; then
        printf '%s\n' "$*" | sed "s/$ESC\[[0-9;]*m//g" >>"$REPORT_FILE"
    fi
}

section() {
    say ""
    say "${C_BOLD}== $* ==${C_RESET}"
}

pass() {
    N_PASS=$((N_PASS + 1))
    say "${C_GREEN}[PASS]${C_RESET} $*"
}

warn() {
    N_WARN=$((N_WARN + 1))
    WARN_LIST="$WARN_LIST$*$TAB"
    say "${C_YELLOW}[WARN]${C_RESET} $*"
}

fail() {
    N_FAIL=$((N_FAIL + 1))
    FAIL_LIST="$FAIL_LIST$*$TAB"
    say "${C_RED}[FAIL]${C_RESET} $*"
}

info() {
    say "${C_CYAN}[INFO]${C_RESET} $*"
}

detail() {
    say "       ${C_DIM}$*${C_RESET}"
}

# print stdin as detail lines
details() {
    local line
    while IFS= read -r line; do
        detail "$line"
    done
}

die() {
    echo "${C_RED}error:${C_RESET} $*" >&2
    exit 3
}

# confirm QUESTION: true if the answer to QUESTION is yes; with --yes without asking
confirm() {
    local answer
    [ $ASSUME_YES -eq 0 ] || return 0
    printf '%s [y/N] ' "$1"
    read -r answer
    case "$answer" in
        y | Y | yes | YES) return 0 ;;
    esac
    return 1
}

pad() {
    printf '%-10s' "$1"
}

human_duration() {
    local s=$1
    if [ "$s" -ge 86400 ]; then
        echo "$((s / 86400))d $((s % 86400 / 3600))h"
    elif [ "$s" -ge 3600 ]; then
        echo "$((s / 3600))h $((s % 3600 / 60))m"
    elif [ "$s" -ge 60 ]; then
        echo "$((s / 60))m $((s % 60))s"
    else
        echo "${s}s"
    fi
}

# human_kib KIB -> size like 1.5G
human_kib() {
    awk -v k="$1" 'BEGIN {
        n = split("K M G T P", u)
        for (i = 1; k >= 1024 && i < n; i++) k /= 1024
        printf(i == 1 ? "%d%s\n" : "%.1f%s\n", k, u[i])
    }'
}

# Compare versions such as 2.8 and 2.8.1-rc; a pre-release is lower than its
# release. With mode=cmp print -1, 0 or 1 for a lower than, equal to or higher
# than b; with mode=max print the highest version of the input lines.
IFS= read -r -d '' AWK_VER <<'EOF'
function parse(s, p,   i) {
    sub(/^v/, "", s)
    PRE = ""
    if ((i = index(s, "-")) > 0) { PRE = substr(s, i + 1); s = substr(s, 1, i - 1) }
    return split(s, p, ".")
}
function vcmp(a, b,   pa, pb, na, nb, prea, preb, i, n, x, y) {
    na = parse(a, pa); prea = PRE
    nb = parse(b, pb); preb = PRE
    n = na > nb ? na : nb
    for (i = 1; i <= n; i++) {
        x = i <= na ? pa[i] + 0 : 0
        y = i <= nb ? pb[i] + 0 : 0
        if (x != y) return x < y ? -1 : 1
    }
    if (prea == preb) return 0
    if (prea == "") return 1
    if (preb == "") return -1
    return prea < preb ? -1 : 1
}
BEGIN { if (mode == "cmp") { print vcmp(a, b); exit } }
NF && (best == "" || vcmp($0, best) > 0) { best = $0 }
END { if (mode == "max" && best != "") print best }
EOF

ver_cmp() {
    awk -v mode=cmp -v a="$1" -v b="$2" "$AWK_VER" </dev/null
}

ver_max() {
    awk -v mode=max "$AWK_VER"
}

# seconds since FILE was modified
file_age() {
    local t
    t=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 1
    echo $(($(date +%s) - t))
}

# ---------------------------------------------------------------------------
# containers of the compose project

# One line per container: service|name|status|health|restarts|oomkilled|exitcode|image id|image|hostname
CTR=

load_containers() {
    local ids
    ids=$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")
    [ -n "$ids" ] || die "no containers found for compose project '$PROJECT'"
    # shellcheck disable=SC2086
    CTR=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}|{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.State.ExitCode}}|{{.Image}}|{{.Config.Image}}|{{.Config.Hostname}}' $ids |
        sed 's#|/#|#' | sort)
}

ctr_line() {
    printf '%s\n' "$CTR" | awk -F'|' -v n="$1" '$2 == n { print; exit }'
}

ctr_field() {
    printf '%s\n' "$CTR" | awk -F'|' -v n="$1" -v f="$2" '$2 == n { print $f; exit }'
}

svc_containers() {
    printf '%s\n' "$CTR" | awk -F'|' -v s="$1" '$1 == s { print $2 }'
}

svc_running() {
    printf '%s\n' "$CTR" | awk -F'|' -v s="$1" '$1 == s && $3 == "running" { print $2; exit }'
}

# a running container of the service, or else any container of it
svc_any() {
    local c
    c=$(svc_running "$1")
    [ -n "$c" ] || c=$(svc_containers "$1" | head -n 1)
    printf '%s\n' "$c"
}

first_running() {
    local svc c
    for svc in "$@"; do
        c=$(svc_running "$svc")
        if [ -n "$c" ]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

host_service() {
    printf '%s\n' "$CTR" | awk -F'|' -v h="$1" '$10 == h { print $1; exit }'
}

is_optional() {
    case " $OPTIONAL_SERVICES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

ctr_env() {
    [ -n "$1" ] || return 0
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null
}

env_get() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

# url_hostport URL [DEFAULT_PORT] -> host:port
url_hostport() {
    local rest=${1#*://} port=$2
    rest=${rest%%/*}
    rest=${rest%%\?*}
    rest=${rest##*@}
    if [ -z "$port" ]; then
        case "$1" in
            https:*) port=443 ;;
            *) port=80 ;;
        esac
    fi
    case "$rest" in
        *:*) printf '%s\n' "$rest" ;;
        *) printf '%s:%s\n' "$rest" "$port" ;;
    esac
}

# url_db URL -> redis database number in the URL path, 0 if none
url_db() {
    local path=${1#*://}
    case "$path" in
        */*) path=${path#*/} ;;
        *) path= ;;
    esac
    path=${path%%\?*}
    case "$path" in
        '' | *[!0-9]*) echo 0 ;;
        *) echo "$path" ;;
    esac
}

# Work out where the services find each other, honouring overrides in the
# environment of the api, agent and kibbitzer services.
resolve_targets() {
    local v p
    API_ANY=$(svc_any api)
    API_IMAGE=$(ctr_field "$API_ANY" 8)
    ENV_API=$(ctr_env "$API_ANY")
    ENV_AGENT=$(ctr_env "$(svc_any agent)")
    ENV_KIB=$(ctr_env "$(svc_any kibbitzer)")

    v=$(env_get "$ENV_API" API_DB_HOST)
    if [ -n "$v" ]; then
        p=$(env_get "$ENV_API" API_DB_PORT)
        DB_HP="$v:${p:-5432}"
    else
        v=$(env_get "$ENV_API" DB_URI)
        if [ -n "$v" ]; then DB_HP=$(url_hostport "$v" 5432); else DB_HP=db:5432; fi
    fi

    v=$(env_get "$ENV_API" REDIS_URL)
    if [ -n "$v" ]; then
        REDIS_HP=$(url_hostport "$v" 6379)
        API_REDIS_DB=$(url_db "$v")
    else
        REDIS_HP=redis:6379
        API_REDIS_DB=0
    fi
    REDIS_PW=$(env_get "$ENV_API" REDIS_PASSWORD)
    REDIS_C=
    if [ "${REDIS_HP%%:*}" = redis ]; then
        REDIS_C=$(svc_running redis)
    fi
    v=$(env_get "$ENV_API" CELERY_BROKER_VISIBILITY_TIMEOUT)
    VIS_TIMEOUT=${v:-43200}

    v=$(env_get "$ENV_API" S3_ENDPOINT_URL)
    if [ -n "$v" ]; then
        S3_HP=$(url_hostport "$v")
    else
        v=$(env_get "$ENV_API" S3_SERVICE)
        S3_HP=${v:-minio:9000}
    fi

    v=$(env_get "$ENV_API" GIT_SERVER)
    GIT_HP=$(url_hostport "${v:-git://gitd}" 9418)
    v=$(env_get "$ENV_API" GIT_REPO_MANAGER)
    GITCTRL_HP=$(printf '%s' "$v" | sed -E 's/^[^"]*"([^"]+)"[^0-9]*([0-9]+).*$/\1:\2/')
    printf '%s' "$GITCTRL_HP" | grep -Eq '^[A-Za-z0-9._-]+:[0-9]+$' || GITCTRL_HP=gitdctrl:9419

    v=$(env_get "$ENV_API" API_URL)
    API_HP=$(url_hostport "${v:-http://api:8000}")
    v=$(env_get "$ENV_API" CLI_PROXY_HOST)
    p=$(env_get "$ENV_AGENT" CLI_PROXY_PORT)
    CLI_HP="${v:-agent}:${p:-9876}"

    v=$(env_get "$ENV_KIB" SHENV_API_URL)
    KIB_API_HP=$(url_hostport "${v:-http://api:8000}")
    v=$(env_get "$ENV_KIB" SHENV_TAC_HOST)
    p=$(env_get "$ENV_KIB" SHENV_TAC_PORT)
    KIB_TAC_HP="${v:-agent}:${p:-8765}"
    v=$(env_get "$ENV_KIB" SHENV_REDIS_URL)
    KIB_REDIS_HP=$(url_hostport "${v:-redis://redis}" 6379)
}

# agent_conf ENV KEY: a setting of the agent from its environment ENV, or the
# default of the agent
agent_conf() {
    local v
    v=$(env_get "$1" "$2")
    if [ -z "$v" ]; then
        case "$2" in
            AGENT_ID) v=$DEFAULT_AGENT_ID ;;
            AGENT_HOST) v=agent ;;
            REDIS_URL) v=redis://redis/4 ;;
            BACKUP_SVC_ADDR) v=kibbitzer ;;
            BACKUP_SVC_PORT) v=9696 ;;
        esac
    fi
    printf '%s\n' "$v"
}

# redis_target URL -> host:port/database
redis_target() {
    printf '%s/%s\n' "$(url_hostport "$1" 6379)" "$(url_db "$1")"
}

# the agent services of the stack other than agent, from the containers
extra_agents() {
    printf '%s\n' "$CTR" | awk -F'|' -v re="$AGENT_IMAGE_RE" '$1 != "agent" && $9 ~ re { print $1 }' | sort -u
}

ctr_label() {
    docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null | grep -v '^<no value>$'
}

# The project directory, compose files and env files the stack was started
# with, from the labels docker compose puts on the containers (one per line).
load_compose() {
    local c
    c=${API_ANY:-$(printf '%s\n' "$CTR" | head -n 1 | cut -d'|' -f2)}
    COMPOSE_WD=$(ctr_label "$c" com.docker.compose.project.working_dir)
    COMPOSE_FILES=$(ctr_label "$c" com.docker.compose.project.config_files | tr ',' '\n')
    COMPOSE_ENV_FILES=$(ctr_label "$c" com.docker.compose.project.environment_file | tr ',' '\n')
}

# git in the clone of this repo; GIT_OPTIONAL_LOCKS keeps git status from
# taking the index lock
rgit() {
    GIT_OPTIONAL_LOCKS=0 LC_ALL=C git -C "$REPO" "$@" </dev/null
}

# Find the git clone of this repo: the compose project directory of the
# stack, or else the directory of this script. Sets REPO, STACK_IN_REPO (1
# when the stack runs from the clone) and WD_PREFIX (the path of the compose
# project directory in the clone, "" at its top), or REPO_ERR.
find_repo() {
    local d out
    REPO= REPO_ERR= STACK_IN_REPO=0 WD_PREFIX=
    if ! command -v git >/dev/null 2>&1; then
        REPO_ERR="git is not installed"
        return 1
    fi
    for d in "$COMPOSE_WD" "$SCRIPT_DIR"; do
        [ -n "$d" ] && [ -d "$d" ] || continue
        if out=$(git -C "$d" rev-parse --show-toplevel 2>&1 </dev/null); then
            REPO=$out
            break
        fi
        case "$out" in
            *'dubious ownership'*)
                REPO_ERR="git does not trust $d because another user owns it; run this script as its owner or allow it with 'git config --global --add safe.directory $d'"
                return 1
                ;;
        esac
    done
    if [ -z "$REPO" ]; then
        REPO_ERR="${COMPOSE_WD:-the compose project directory} is not a git clone of the Netpicker repo"
        return 1
    fi
    if [ -n "$COMPOSE_WD" ] && [ "$(git -C "$COMPOSE_WD" rev-parse --show-toplevel 2>/dev/null </dev/null)" = "$REPO" ]; then
        STACK_IN_REPO=1
        WD_PREFIX=$(git -C "$COMPOSE_WD" rev-parse --show-prefix </dev/null)
    fi
}

# repo_rel FILE: the path in the repo of FILE in the compose project directory
repo_rel() {
    [ "$STACK_IN_REPO" = 1 ] || return 1
    case "$1" in
        "$COMPOSE_WD"/*) printf '%s%s\n' "$WD_PREFIX" "${1#"$COMPOSE_WD"/}" ;;
        *) return 1 ;;
    esac
}

# seconds since the last 'git fetch' in the repo
fetch_age() {
    local f
    f=$(rgit rev-parse --git-path FETCH_HEAD 2>/dev/null) || return 1
    case "$f" in
        /*) ;;
        *) f="$REPO/$f" ;;
    esac
    [ -f "$f" ] && file_age "$f"
}

# compose_run MODE ARGS...: docker compose with the project, directory, env
# files and compose files of the stack. MODE base takes the compose files that
# are in the repo as they were at commit $BASE, and fails when none of the
# compose files existed then.
compose_run() {
    local mode=$1 f rel n=0
    local -a args
    shift
    args=(-p "$PROJECT" --project-directory "$COMPOSE_WD")
    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] && args+=(--env-file "$f")
    done <<EOF
$COMPOSE_ENV_FILES
EOF
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ "$mode" = base ] && rel=$(repo_rel "$f"); then
            rgit cat-file -e "$BASE:$rel" 2>/dev/null || continue
            mkdir -p "$WORK/base/$(dirname "$rel")" && rgit show "$BASE:$rel" >"$WORK/base/$rel" || return 1
            f="$WORK/base/$rel"
        fi
        args+=(-f "$f")
        n=$((n + 1))
    done <<EOF
$COMPOSE_FILES
EOF
    [ $n -gt 0 ] || return 1
    docker compose "${args[@]}" "$@" </dev/null
}

# ---------------------------------------------------------------------------
# scripts run inside the containers

# Test a connection from inside a container: probe MODE HOST PORT.
# MODE is tcp (plain connect), ping (gitdctrl PING/PONG) or git (git ls-remote,
# a bare connect makes git-daemon log "fatal: the remote end hung up").
# Exit status 0 ok, 1 failed, 2 name does not resolve, 3 cannot test.
IFS= read -r -d '' PROBE_SH <<'EOF'
mode=$1 host=$2 port=$3
if [ "$mode" = git ]; then
    if out=$(git ls-remote "git://$host:$port/healthcheck.git" 2>&1 >/dev/null); then
        exit 0
    fi
    echo "git ls-remote failed: $(echo "$out" | tail -n 1)"
    exit 1
fi
if command -v python3 >/dev/null 2>&1; then
    exec python3 -c '
import socket, sys
mode, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    socket.getaddrinfo(host, port)
except socket.gaierror as exc:
    print("cannot resolve %s: %s" % (host, exc))
    sys.exit(2)
try:
    conn = socket.create_connection((host, port), 5)
    if mode == "ping":
        conn.settimeout(5)
        conn.sendall(b"PING\n")
        if not conn.recv(16).startswith(b"PONG"):
            print("no PONG reply")
            sys.exit(1)
    conn.close()
except Exception as exc:
    print(exc)
    sys.exit(1)
' "$mode" "$host" "$port"
fi
if command -v getent >/dev/null 2>&1 && ! getent hosts "$host" >/dev/null 2>&1; then
    echo "cannot resolve $host"
    exit 2
fi
if command -v nc >/dev/null 2>&1; then
    if [ "$mode" = ping ]; then
        printf 'PING\n' | nc -w 5 "$host" "$port" 2>/dev/null | grep -q PONG && exit 0
        echo "no PONG reply"
        exit 1
    fi
    nc -z -w 5 "$host" "$port" >/dev/null 2>&1 && exit 0
    echo "connection refused or timed out"
    exit 1
fi
echo "no python3 or nc in the container"
exit 3
EOF

# Celery queues in one redis database. Queue names come from the kombu
# binding sets (members are routing_key<sep>pattern<sep>queue); the api uses
# the default "\x06\x16" separator, kibbitzer and agent use "^". Priority
# sub-queues are <queue><sep>1 and <queue><sep>2. In-flight (unacked)
# messages are in the "unacked" hash, delivery times in "unacked_index".
# With the argument "clear" it also deletes the queues and the in-flight
# messages; the bindings stay, so the workers keep consuming the queues.
# Output: Q<TAB>queue<TAB>separator<TAB>length and
#         U<TAB>unacked count<TAB>oldest age in seconds<TAB>task<TAB>routing key
IFS= read -r -d '' LUA_QUEUES <<'EOF'
local clear = ARGV[1] == "clear"
local out, seen = {}, {}
local seps = { { "\6\22", "x06x16" }, { "^", "^" } }
local cursor = "0"
repeat
  local r = redis.call("SCAN", cursor, "MATCH", "_kombu.binding.*", "COUNT", 1000)
  cursor = r[1]
  for _, bkey in ipairs(r[2]) do
    local exchange = string.sub(bkey, 16)
    if not string.find(exchange, "pidbox", 1, true) and exchange ~= "celeryev" then
      for _, member in ipairs(redis.call("SMEMBERS", bkey)) do
        for _, sp in ipairs(seps) do
          local sep, label = sp[1], sp[2]
          if string.find(member, sep, 1, true) then
            local queue, pos = member, 1
            while true do
              local s, e = string.find(member, sep, pos, true)
              if not s then break end
              queue, pos = string.sub(member, e + 1), e + 1
            end
            if not seen[queue] then
              seen[queue] = true
              local n = 0
              for _, key in ipairs({ queue, queue .. sep .. "1", queue .. sep .. "2" }) do
                local len = redis.pcall("LLEN", key)
                if type(len) == "number" then
                  n = n + len
                  if clear and len > 0 then redis.call("DEL", key) end
                end
              end
              table.insert(out, "Q\t" .. queue .. "\t" .. label .. "\t" .. n)
            end
            break
          end
        end
      end
    end
  end
until cursor == "0"
local now = redis.call("TIME")
local oldest = redis.call("ZRANGE", "unacked_index", 0, 0, "WITHSCORES")
local age, task, rkey = -1, "", ""
if oldest[2] then
  age = math.floor(tonumber(now[1]) - tonumber(oldest[2]))
  local raw = redis.call("HGET", "unacked", oldest[1])
  if raw then
    local ok, v = pcall(cjson.decode, raw)
    if ok and type(v) == "table" then
      if type(v[1]) == "table" and type(v[1].headers) == "table" then
        task = tostring(v[1].headers.task or "")
      end
      rkey = tostring(v[3] or "")
    end
  end
end
table.insert(out, "U\t" .. redis.call("HLEN", "unacked") .. "\t" .. age .. "\t" .. task .. "\t" .. rkey)
if clear then redis.call("DEL", "unacked", "unacked_index") end
return out
EOF

# Agents connected to the api websocket: every api process keeps a set
# AgentBroker.<host>.<pid> of its connected agents, as pickled ConnectedAgent
# tuples. Args: redis host:port, database.
# Output: C<TAB>agent id (its AGENT_ID)<TAB>tenant<TAB>host (its AGENT_HOST)<TAB>api host.pid
#         or E<TAB>error
IFS= read -r -d '' PY_AGENTS <<'EOF'
import os
import pickle
import sys
import warnings

warnings.simplefilter("ignore")
try:
    import redis

    from app.utils import shortid

    host, port = sys.argv[1].rsplit(":", 1)
    rdb = redis.Redis(host=host, port=int(port), db=int(sys.argv[2]),
                      password=os.environ.get("NP_REDIS_PASSWORD") or None,
                      socket_timeout=5)
    for key in rdb.scan_iter("AgentBroker.*", count=1000):
        server = key.decode().split(".", 1)[1]
        for member in rdb.smembers(key):
            agent = pickle.loads(member)
            print("C\t%s\t%s\t%s\t%s" % (shortid.encode(int(agent.id)), agent.tenant,
                                         agent.host or "", server))
except Exception as exc:
    print("E\t%s" % exc)
EOF

# Ask the celery workers on one broker database what they are doing.
# Args: redis host:port, database, separator label, timeout.
# Output: W<TAB>worker<TAB>concurrency<TAB>active<TAB>reserved<TAB>scheduled<TAB>queues
#         or E<TAB>error
IFS= read -r -d '' PY_INSPECT <<'EOF'
import os
import sys
import warnings

warnings.simplefilter("ignore")
try:
    from urllib.parse import quote

    from celery import Celery

    hostport, db, sep, timeout = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
    password = os.environ.get("NP_REDIS_PASSWORD") or ""
    auth = ":%s@" % quote(password, safe="") if password else ""
    app = Celery(broker="redis://%s%s/%s" % (auth, hostport, db))
    if sep == "^":
        # control messages with the wrong separator make the workers log errors
        app.conf.broker_transport_options = {"sep": "^"}
    insp = app.control.inspect(timeout=timeout)
    queues = insp.active_queues() or {}
    stats = insp.stats() or {}
    active = insp.active() or {}
    reserved = insp.reserved() or {}
    scheduled = insp.scheduled() or {}
except Exception as exc:
    print("E\t%s" % exc)
    sys.exit(0)

for worker in sorted(set(queues) | set(stats)):
    pool = (stats.get(worker) or {}).get("pool") or {}
    names = ",".join(q.get("name", "") for q in queues.get(worker) or [])
    print("W\t%s\t%s\t%d\t%d\t%d\t%s" % (
        worker, pool.get("max-concurrency", 0),
        len(active.get(worker) or []), len(reserved.get(worker) or []),
        len(scheduled.get(worker) or []), names))
EOF

# Run the query in argv[1] with the database settings of the api, print the
# rows tab-separated
IFS= read -r -d '' PY_DB_QUERY <<'EOF'
import sys

from sqlalchemy import create_engine

from app.settings import common_config

with create_engine(common_config.ALEMBIC_URI).connect() as conn:
    for row in conn.exec_driver_sql(sys.argv[1]):
        print("\t".join("" if v is None else str(v) for v in row))
EOF

# The last event of every device per kind of event (a trigger deletes the
# earlier ones): readout is a backup and exec-rules a policy run. Automation
# jobs (exec-job) are left out: they stay scheduled until their run in the
# future. The phase goes scheduled -> started -> finished, or cancelled;
# failed backups have success false or an error in the details, failed policy
# runs an exception. Ages are in seconds, times in UTC.
# Output: S tenant event status devices oldest oldest-age newest newest-age
#         E tenant event error devices newest-age example-addresses
#         X tenant event phase devices oldest-age example-addresses (unfinished
#           for longer than @TASK_AGE@ seconds)
#         N tenant devices excluded never-backed-up never-policy-run
IFS= read -r -d '' SQL_DEVICE_EVENTS <<'EOF'
WITH ev AS (
    SELECT coalesce(t.name, '-') AS tenant, d.ipaddress, e.event, e.registered, e.details,
           greatest(extract(epoch FROM (now() AT TIME ZONE 'utc') - e.registered), 0)::bigint AS age,
           CASE
               WHEN jsonb_typeof(e.details) = 'object' AND (
                   e.details ? 'exception'
                   OR (e.event = 'readout' AND (e.details->>'success' = 'false'
                                                OR coalesce(e.details->>'error', '') <> '')))
                   THEN 'failed'
               WHEN e.phase = 'finished' AND e.details->>'success' = 'true' THEN 'succeeded'
               ELSE coalesce(e.phase, 'unknown')
           END AS status
    FROM deviceevent e
    JOIN device d ON d.id = e.device_id
    LEFT JOIN tenant t ON t.id = d.tenant_id
    WHERE e.event <> 'exec-job'
)
SELECT 'S', tenant, event, status, count(*)::text,
       to_char(min(registered), 'YYYY-MM-DD HH24:MI'), max(age)::text,
       to_char(max(registered), 'YYYY-MM-DD HH24:MI'), min(age)::text
FROM ev GROUP BY tenant, event, status
UNION ALL
SELECT 'E', tenant, event, msg, count(*)::text, min(age)::text,
       array_to_string((array_agg(ipaddress ORDER BY registered DESC))[1:3], ', '), NULL, NULL
FROM (SELECT tenant, event, ipaddress, registered, age,
             left(regexp_replace(coalesce(nullif(details->>'error', ''), details->>'exception', 'no error message'),
                                 '\s+', ' ', 'g'), 160) AS msg
      FROM ev WHERE status = 'failed') f
GROUP BY tenant, event, msg
UNION ALL
SELECT 'X', tenant, event, status, count(*)::text, max(age)::text,
       array_to_string((array_agg(ipaddress ORDER BY registered))[1:3], ', '), NULL, NULL
FROM ev WHERE status IN ('scheduled', 'started') AND age > @TASK_AGE@
GROUP BY tenant, event, status
UNION ALL
SELECT 'N', coalesce(t.name, '-'), count(*)::text,
       (count(*) FILTER (WHERE d.exclude))::text,
       (count(*) FILTER (WHERE NOT d.exclude AND NOT EXISTS (
           SELECT 1 FROM deviceevent e WHERE e.device_id = d.id AND e.event = 'readout')))::text,
       (count(*) FILTER (WHERE NOT EXISTS (
           SELECT 1 FROM deviceevent e WHERE e.device_id = d.id AND e.event = 'exec-rules')))::text,
       NULL, NULL, NULL
FROM device d LEFT JOIN tenant t ON t.id = d.tenant_id
GROUP BY t.name
EOF

# The device event table of one tenant (-v t=NAME) from the S and N rows.
IFS= read -r -d '' AWK_EVENTS_TABLE <<'EOF'
function dur(s) {
    s += 0
    if (s >= 86400) return int(s / 86400) "d " int(s % 86400 / 3600) "h"
    if (s >= 3600) return int(s / 3600) "h " int(s % 3600 / 60) "m"
    if (s >= 60) return int(s / 60) "m " s % 60 "s"
    return s "s"
}
function label(e) { return e == "readout" ? "backup" : e == "exec-rules" ? "policy run" : e }
function erank(e) { return e == "readout" ? 1 : e == "exec-rules" ? 2 : 3 }
function srank(s) {
    return s == "succeeded" ? 1 : s == "finished" ? 2 : s == "failed" ? 3 : s == "cancelled" ? 4 \
        : s == "started" ? 5 : s == "scheduled" ? 6 : s == "never" ? 9 : 7
}
function row(e, s, n, oldest, newest) {
    key[++nr] = sprintf("%d %d %s %s", erank(e), srank(s), e, s)
    line[nr] = sprintf("%-11s %-10s %7d  %-30s %s", label(e), s == "started" ? "running" : s, n, oldest, newest)
}
BEGIN { FS = "\t" }
$2 != t { next }
$1 == "S" { row($3, $4, $5, $6 " (" dur($7) " ago)", $8 " (" dur($9) " ago)") }
$1 == "N" {
    if ($5 > 0) row("readout", "never", $5, "", "")
    if ($6 > 0) row("exec-rules", "never", $6, "", "")
}
END {
    for (i = 2; i <= nr; i++)
        for (j = i; j > 1 && key[j - 1] > key[j]; j--) {
            k = key[j]; key[j] = key[j - 1]; key[j - 1] = k
            l = line[j]; line[j] = line[j - 1]; line[j - 1] = l
        }
    printf "%-11s %-10s %7s  %-30s %s\n", "", "status", "devices", "oldest (UTC)", "newest (UTC)"
    for (i = 1; i <= nr; i++) { sub(/ +$/, "", line[i]); print line[i] }
}
EOF

# The agents in the database with the id the agent containers use as their
# AGENT_ID: the shortid of the database id (app/utils/shortid.py of the api),
# base 42 with the lowest digit first after adding 42^5. Connected agents send
# a heartbeat every 10 seconds, which sets last_connected (UTC). The api
# splits the backups of devices without an agent over the connected agents of
# their tenant.
# Output: A agent-id tenant name heartbeat-age (empty: never) devices
#         U tenant devices-without-agent (not excluded from backups)
IFS= read -r -d '' SQL_AGENTS <<'EOF'
WITH RECURSIVE sid(id, n, s) AS (
    SELECT id, id::numeric + 130691232, ''::text FROM agent
    UNION ALL
    SELECT id, div(n, 42), s || substr('bcdfghjklmnpqrstvwxyzBCDFGHJKLMNPQRSTVWXYZ', mod(n, 42)::int + 1, 1)
    FROM sid WHERE n > 0
)
SELECT 'A', sid.s, coalesce(t.name, '-'), a.name,
       greatest(extract(epoch FROM (now() AT TIME ZONE 'utc') - a.last_connected), 0)::bigint::text,
       (SELECT count(*) FROM device d WHERE d.agent_id = a.id)::text
FROM agent a
JOIN sid ON sid.id = a.id AND sid.n = 0
LEFT JOIN tenant t ON t.id = a.tenant_id
UNION ALL
SELECT 'U', coalesce(t.name, '-'), count(*)::text, NULL, NULL, NULL
FROM device d LEFT JOIN tenant t ON t.id = d.tenant_id
WHERE d.agent_id IS NULL AND NOT d.exclude
GROUP BY t.name
EOF

# The services of the stack from flattened compose config lines (see
# AWK_FLAT): S<TAB>service<TAB>kind (agent, kibbitzer or -)<TAB>container_name
# and E<TAB>service<TAB>KEY=value for every environment variable. -v re= the
# regex of agent images.
IFS= read -r -d '' AWK_STACK <<'EOF'
BEGIN { FS = OFS = "\t" }
!($1 in seen) { seen[$1] = 1; order[++n] = $1 }
$2 == "image" { img[$1] = $3 }
$2 == "labels.service.netpicker.io" { lbl[$1] = $3 }
$2 == "container_name" { cn[$1] = $3 }
$2 ~ /^environment\./ { env[$1, ++ne[$1]] = substr($2, 13) "=" $3 }
END {
    for (i = 1; i <= n; i++) {
        s = order[i]
        if (lbl[s] == "agent" || img[s] ~ re) k = "agent"
        else if (lbl[s] == "kibbitzer" || img[s] ~ /(^|\/)kibbitzer([:@]|$)/) k = "kibbitzer"
        else k = "-"
        print "S", s, k, cn[s]
        for (j = 1; j <= ne[s]; j++) print "E", s, env[s, j]
    }
}
EOF

# Align tab-separated columns.
IFS= read -r -d '' AWK_COLUMNS <<'EOF'
BEGIN { FS = "\t" }
{
    for (i = 1; i <= NF; i++) {
        cell[NR, i] = $i
        if (length($i) > w[i]) w[i] = length($i)
    }
    if (NF > nf) nf = NF
}
END {
    for (r = 1; r <= NR; r++) {
        line = ""
        for (i = 1; i <= nf; i++) line = line sprintf("%-" w[i] "s  ", cell[r, i])
        sub(/ +$/, "", line)
        print line
    }
}
EOF

# Flatten the normalized YAML of 'docker compose config' to one line per
# setting: service<TAB>path<TAB>value, e.g. "api<TAB>environment.LOG_LEVEL<TAB>INFO".
# Lists of scalars become one value like "[CMD-SHELL, pg_isready]", a list
# of maps one line per item, with ports and volumes as host:container.
IFS= read -r -d '' AWK_FLAT <<'EOF'
function unquote(s) {
    if (s ~ /^".*"$/ || s ~ /^'.*'$/) s = substr(s, 2, length(s) - 2)
    return s
}
function path(d,   p, k) {
    p = ""
    for (k = 3; k <= d; k++) if (kind[k] != "item") p = p (p == "" ? "" : ".") name[k]
    return p
}
# the innermost list item open at or above level d, 0 if none
function item_at(d,   k) {
    for (k = d; k >= 3; k--) if (kind[k] == "item") return k
    return 0
}
function leaf(d, v,   it, p, k) {
    it = item_at(d)
    if (it) {
        p = ""
        for (k = it + 1; k <= d; k++) p = p (p == "" ? "" : ".") name[k]
        field[it, p] = v
        buf[it] = buf[it] (buf[it] == "" ? "" : " ") p "=" v
    } else {
        print svc "\t" path(d) "\t" v
    }
}
function close_item(d,   v, lk, f, sf) {
    lk = name[d - 1]
    if (lk == "ports") {
        v = field[d, "published"] ":" field[d, "target"]
        if (field[d, "host_ip"] != "") v = field[d, "host_ip"] ":" v
        if (field[d, "protocol"] != "" && field[d, "protocol"] != "tcp") v = v "/" field[d, "protocol"]
    } else if (lk == "volumes" && field[d, "target"] != "") {
        v = (field[d, "source"] != "" ? field[d, "source"] ":" : "") field[d, "target"]
        if (field[d, "read_only"] == "true") v = v ":ro"
    } else {
        v = buf[d]
    }
    for (f in field) { split(f, sf, SUBSEP); if (sf[1] == d) delete field[f] }
    buf[d] = ""
    leaf(d - 1, v)
}
# close every level indented at least i
function pop(i) {
    while (depth >= 3 && ind[depth] >= i) {
        if (kind[depth] == "item") close_item(depth)
        else if (kind[depth] == "list") leaf(depth, "[" lst[depth] "]")
        else if (kind[depth] == "key" && !kids[depth]) leaf(depth, "")
        depth--
    }
}
function flush_block() {
    if (!blk) return
    blk = 0
    if (blkitem) { lst[depth] = lst[depth] (lst[depth] == "" ? "" : ", ") blkval; kind[depth] = "list" }
    else { leaf(depth, blkval); depth-- }
}
# "key: value" or "key:" indented i
function keyval(t, i,   k, v, p) {
    if (t ~ /^"/) {
        p = index(substr(t, 2), "\"") + 1
        k = substr(t, 2, p - 2)
        v = substr(t, p + 2)
    } else {
        p = index(t, ":")
        k = substr(t, 1, p - 1)
        v = substr(t, p + 1)
    }
    sub(/^ /, "", v)
    kids[depth] = 1
    depth++
    ind[depth] = i; name[depth] = k; kind[depth] = "key"; kids[depth] = 0; lst[depth] = ""
    if (v == "") return
    if (v ~ /^[|>][-+]?$/) { blk = 1; blkind = i; blkval = ""; blkitem = 0; return }
    leaf(depth, unquote(v))
    depth--
}
{
    sub(/\r$/, "")
    if ($0 ~ /^ *$/) next
    match($0, /^ */)
    i = RLENGTH
    t = substr($0, i + 1)
    if (blk) {
        if (i > blkind) { blkval = blkval (blkval == "" ? "" : "\\n") t; next }
        flush_block()
    }
    if (i == 0) {
        pop(0)
        depth = 0
        insvc = (t == "services:")
        next
    }
    if (!insvc) next
    if (i == 2) {
        pop(2)
        depth = 2
        svc = unquote(substr(t, 1, length(t) - 1))
        ind[2] = 2; kids[2] = 0
        next
    }
    pop(i)
    if (t ~ /^- /) {
        t = substr(t, 3)
        kids[depth] = 1
        if (t ~ /^("[^"]*"|[^ "]+):( |$)/) {
            depth++
            ind[depth] = i; name[depth] = ""; kind[depth] = "item"; buf[depth] = ""
            keyval(t, i + 2)
        } else if (t ~ /^[|>][-+]?$/) {
            blk = 1; blkind = i; blkval = ""; blkitem = 1
        } else {
            kind[depth] = "list"
            lst[depth] = lst[depth] (lst[depth] == "" ? "" : ", ") unquote(t)
        }
        next
    }
    keyval(t, i)
}
END { flush_block(); pop(0) }
EOF

# Compare two flattened compose configs, the first file the base. Secrets
# are masked. Output: R<TAB>service (removed), A<TAB>service<TAB>image (added),
# C<TAB>services<TAB>path<TAB>added|removed|changed<TAB>what changed; when the
# same setting differs in more than 3 services one C line lists them all
# without what changed, e.g. container_name in an override that resets it.
IFS= read -r -d '' AWK_CDIFF <<'EOF'
function mask(p, v) {
    sub(/^.*\./, "", p)
    if (v != "" && tolower(p) ~ /passw|secret|token|key|credential/) return "***"
    gsub(/:[^:\/@ ]+@/, ":***@", v)
    return v
}
# the values of k on side s (b or c), sorted and joined with ", "; masked if m
function joined(s, k, m,   n, i, j, t, a) {
    n = s == "b" ? bn[k] : cn[k]
    for (i = 1; i <= n; i++) {
        a[i] = s == "b" ? bv[k, i] : cv[k, i]
        if (m) a[i] = mask(path_of[k], a[i])
    }
    for (i = 2; i <= n; i++) for (j = i; j > 1 && a[j - 1] > a[j]; j--) { t = a[j]; a[j] = a[j - 1]; a[j - 1] = t }
    t = ""
    for (i = 1; i <= n; i++) t = t (i > 1 ? ", " : "") a[i]
    return t
}
# the values of k on side s that the other side does not have
function only(s, k,   o, n, i, j, t, v, found) {
    o = s == "b" ? "c" : "b"
    n = s == "b" ? bn[k] : cn[k]
    t = ""
    for (i = 1; i <= n; i++) {
        v = s == "b" ? bv[k, i] : cv[k, i]
        found = 0
        for (j = 1; j <= (o == "b" ? bn[k] : cn[k]); j++)
            if (v == (o == "b" ? bv[k, j] : cv[k, j])) found = 1
        if (!found) t = t (t == "" ? "" : ", ") mask(path_of[k], v)
    }
    return t
}
function seen(s, p,   k) {
    k = s SUBSEP p
    if (!(k in known)) { known[k] = 1; order[++nk] = k; svc_of[k] = s; path_of[k] = p }
    return k
}
BEGIN { FS = "\t" }
FNR == NR { bs[$1] = 1; k = seen($1, $2); bv[k, ++bn[k]] = $3; next }
{ cs[$1] = 1; k = seen($1, $2); cv[k, ++cn[k]] = $3 }
END {
    for (s in bs) if (!(s in cs)) print "R\t" s
    for (s in cs) if (!(s in bs)) print "A\t" s "\t" cv[s SUBSEP "image", 1]
    for (i = 1; i <= nk; i++) {
        k = order[i]
        s = svc_of[k]; p = path_of[k]
        if (!(s in bs) || !(s in cs)) continue
        if (joined("b", k, 0) == joined("c", k, 0)) continue
        ob = joined("b", k, 1); oc = joined("c", k, 1)
        if (!bn[k]) { how = "added"; text = oc }
        else if (!cn[k]) { how = "removed"; text = "was " ob }
        else if (bn[k] == 1 && cn[k] == 1) { how = "changed"; text = ob " -> " oc }
        else {
            how = "changed"
            r = only("b", k); a = only("c", k)
            text = (r != "" ? "removed " r : "") (r != "" && a != "" ? "; " : "") (a != "" ? "added " a : "")
        }
        g = p SUBSEP how SUBSEP text
        if (!(g in gsvc)) { gorder[++ng] = g; gp[g] = p; gh[g] = how; gt[g] = text; pc[p SUBSEP how]++ }
        gsvc[g] = gsvc[g] (gsvc[g] == "" ? "" : ", ") s
    }
    for (i = 1; i <= ng; i++) {
        g = gorder[i]
        ph = gp[g] SUBSEP gh[g]
        if (pc[ph] > 3) {
            all[ph] = all[ph] (all[ph] == "" ? "" : ", ") gsvc[g]
            if (!(ph in first)) first[ph] = i
        }
    }
    for (i = 1; i <= ng; i++) {
        g = gorder[i]
        ph = gp[g] SUBSEP gh[g]
        if (pc[ph] <= 3) print "C\t" gsvc[g] "\t" gp[g] "\t" gh[g] "\t" gt[g]
        else if (first[ph] == i) print "C\t" all[ph] "\t" gp[g] "\t" gh[g] "\t"
    }
}
EOF

# Disk and inode usage of paths: DF_SH LABEL PATH [LABEL PATH]...
# Output: label<TAB>df -Pk row<TAB>df -Pi row
IFS= read -r -d '' DF_SH <<'EOF'
while [ $# -ge 2 ]; do
    s=$(df -Pk "$2" 2>/dev/null | tail -n +2 | tail -n 1)
    i=$(df -Pi "$2" 2>/dev/null | tail -n +2 | tail -n 1)
    [ -z "$s" ] || printf '%s\t%s\t%s\n' "$1" "$s" "$i"
    shift 2
done
EOF

# Look for problems in the git working copies under the policy workdir:
# uncommitted files, commits not pushed to gitd, stale lock files, unfinished
# merges and directories the container user cannot write to.
# Args: workdir, container name, max files to list, age in seconds after
# which uncommitted work counts as left behind, mode and its argument:
#   check CMD     report the problems; advise CMD to discard the uncommitted
#                 files and stale locks left behind
#   list          report the repos with uncommitted files or stale locks left
#                 behind, with a RESET<TAB>repo line for each that git reset
#                 can clean and an UNLOCK<TAB>repo line for each that it can
#                 clean once its stale locks are removed
#   reset REPOS   discard the uncommitted files in REPOS, one per line, with
#                 git reset --hard and git clean
#   unlock REPOS  remove the stale locks in REPOS, then reset them
# Output: PASS|WARN|FAIL|INFO|DETAIL|RESET|UNLOCK<TAB>message
IFS= read -r -d '' PY_WORKDIR <<'EOF'
import os
import shutil
import subprocess
import sys
import time

root, container = sys.argv[1], sys.argv[2]
max_files, dirty_age = int(sys.argv[3]), int(sys.argv[4])
mode, mode_arg = sys.argv[5], sys.argv[6] if len(sys.argv) > 6 else ""
# a copy of the upstream CVE list that the api resets on every update; git
# status takes long on its many files
SKIP = {"cvelistv5"}
# repos are at most at <kind>/user-<id>/<tenant>
MAX_DEPTH = 4
LOCK_AGE = 600
GIT_TIMEOUT = 60
STATES = (
    ("MERGE_HEAD", "merge"),
    ("rebase-merge", "rebase"),
    ("rebase-apply", "rebase"),
    ("CHERRY_PICK_HEAD", "cherry-pick"),
    ("REVERT_HEAD", "revert"),
)
# the api may be committing: git status must not take index.lock
ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
FIX_OWNER = "fix the ownership of the volume, e.g. with fix-volume-permissions.sh"
now = time.time()
uid = os.getuid()


class GitError(Exception):
    pass


def emit(kind, msg):
    print("%s\t%s" % (kind, msg.replace("\t", " ").replace("\n", " ")))


def duration(s):
    s = int(s)
    if s >= 86400:
        return "%dd %dh" % (s // 86400, s % 86400 // 3600)
    if s >= 3600:
        return "%dh %dm" % (s // 3600, s % 3600 // 60)
    if s >= 60:
        return "%dm %ds" % (s // 60, s % 60)
    return "%ds" % s


def age(path):
    try:
        return now - os.lstat(path).st_mtime
    except OSError:
        return None


def git(repo, *args):
    return subprocess.run(("git", "-C", repo) + args, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=ENV, timeout=GIT_TIMEOUT)


def git_error(proc):
    lines = proc.stderr.decode(errors="replace").strip().splitlines()
    for line in lines:
        if line.startswith(("fatal:", "error:")):
            return line
    return lines[-1] if lines else "exit code %d" % proc.returncode


def find_repos():
    for top, dirs, files in os.walk(root):
        if ".git" in dirs or ".git" in files:
            yield top
            dirs[:] = []
            continue
        depth = 0 if top == root else os.path.relpath(top, root).count(os.sep) + 1
        if depth >= MAX_DEPTH:
            dirs[:] = []
        else:
            dirs[:] = sorted(d for d in dirs
                             if not d.startswith(".") and not (depth == 0 and d in SKIP))


def git_dir(repo):
    path = os.path.join(repo, ".git")
    if os.path.isfile(path):
        with open(path) as f:
            line = f.readline().strip()
        if line.startswith("gitdir:"):
            path = os.path.join(repo, line[7:].strip())
    return path


def scan_git_dir(gdir):
    """-> (first directory not writable, [(lock file, age)], (operation, age) of an unfinished one)"""
    readonly, locks, state = None, [], None
    for top, _, files in os.walk(gdir):
        if readonly is None and not os.access(top, os.W_OK):
            readonly = top
        for f in files:
            a = age(os.path.join(top, f)) if f.endswith(".lock") else None
            if a is not None:
                locks.append((os.path.join(top, f), a))
    for marker, op in STATES:
        a = age(os.path.join(gdir, marker))
        if a is not None:
            state = (op, a)
            break
    return readonly, locks, state


def parse_status(out):
    """git status --porcelain=v2 -z -> (commits ahead, [(XY, path)], unmerged count)"""
    ahead, files, unmerged = 0, [], 0
    tokens = iter(out.split(b"\0"))
    for raw in tokens:
        entry = raw.decode(errors="replace")
        kind = entry[:2]
        if entry.startswith("# branch.ab "):
            ahead = int(entry.split()[2])
        elif kind in ("1 ", "2 "):
            fields = entry.split(" ", 9 if kind == "2 " else 8)
            files.append((fields[1].replace(".", " "), fields[-1]))
            if kind == "2 ":
                next(tokens, None)  # the original path of a rename
        elif kind == "u ":
            fields = entry.split(" ", 10)
            files.append((fields[1], fields[-1]))
            unmerged += 1
        elif kind == "? ":
            files.append(("??", entry[2:]))
    return ahead, files, unmerged


def git_status(repo):
    """-> (commits ahead, [(age, XY, path)] oldest first and deleted files last, unmerged count)"""
    proc = git(repo, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all")
    if proc.returncode:
        raise GitError(git_error(proc))
    ahead, files, unmerged = parse_status(proc.stdout)
    dated = sorted(((age(os.path.join(repo, p)), xy, p) for xy, p in files),
                   key=lambda f: -1 if f[0] is None else f[0], reverse=True)
    return ahead, dated, unmerged


def left_behind(dated):
    """True if the oldest uncommitted file is older than dirty_age, or all are deleted"""
    return bool(dated) and (dated[0][0] is None or dated[0][0] >= dirty_age)


def describe(dated, unmerged):
    untracked = sum(1 for _, xy, _ in dated if xy == "??")
    counts = ", ".join("%d %s" % (n, what) for n, what in (
        (len(dated) - untracked - unmerged, "changed"),
        (untracked, "untracked"),
        (unmerged, "with conflicts"),
    ) if n)
    oldest = dated[0][0]
    when = "" if oldest is None else ", the oldest changed %s ago" % duration(oldest)
    return "%d uncommitted file(s) (%s)%s" % (len(dated), counts, when)


def list_files(repo, dated):
    for a, xy, p in dated[:max_files]:
        emit("DETAIL", "%s %8s  %s" % (xy, "-" if a is None else duration(a), p))
    if len(dated) > max_files:
        emit("DETAIL", "... and %d more; see 'docker exec %s git -C %s status'"
             % (len(dated) - max_files, container, repo))


def describe_locks(repo, locks):
    return "stale lock%s %s" % ("s" if len(locks) > 1 else "", ", ".join(
        "%s from %s ago" % (os.path.relpath(lock, repo), duration(a)) for lock, a in locks))


def reset_blocker(repo, readonly, locks, state, unlock=False):
    """Why git reset cannot discard the uncommitted files of a repo, or None;
    with unlock, once its stale locks are removed"""
    if readonly:
        return "%s is not writable for uid %d; %s" % (os.path.relpath(readonly, repo), uid, FIX_OWNER)
    if any(a < LOCK_AGE for _, a in locks):
        return "a git command is running; try again later"
    if locks and not unlock:
        return describe_locks(repo, locks)
    if state and state[0] == "rebase":
        if state[1] < LOCK_AGE:
            return "a rebase is in progress; try again later"
        return "unfinished rebase from %s ago; abort it first with 'git rebase --abort'" % duration(state[1])
    return None


def check(repo):
    """Report the problems of one repo; True if it has none."""
    name = os.path.relpath(repo, root)
    readonly, locks, state = scan_git_dir(git_dir(repo))
    ok = not (readonly or locks or state)
    if reset_blocker(repo, readonly, locks, state, unlock=True):
        unlock = " (only remove it when no git command runs)"
    else:
        unlock = "; remove it and reset the repo with '%s' (only when no git command runs)" % mode_arg

    if readonly:
        emit("FAIL", "%s: %s is not writable for uid %d, so commits fail; %s"
             % (name, os.path.relpath(readonly, repo), uid, FIX_OWNER))
    for lock, a in locks:
        if a >= LOCK_AGE:
            emit("FAIL", "%s: stale lock %s from %s ago; git refuses to work in this repo until "
                 "it is removed%s" % (name, os.path.relpath(lock, repo), duration(a), unlock))
        else:
            emit("INFO", "%s: %s from %s ago, a git command is running"
                 % (name, os.path.relpath(lock, repo), duration(a)))
    if state:
        op, a = state
        if a >= LOCK_AGE:
            emit("FAIL", "%s: unfinished %s from %s ago; commits fail until it is aborted with "
                 "'git %s --abort'" % (name, op, duration(a), op))
        else:
            emit("INFO", "%s: a %s is in progress" % (name, op))

    try:
        ahead, dated, unmerged = git_status(repo)
    except subprocess.TimeoutExpired:
        emit("WARN", "%s: git status did not finish within %ds" % (name, GIT_TIMEOUT))
        return False
    except GitError as exc:
        emit("FAIL", "%s: git status failed: %s" % (name, exc))
        if "dubious ownership" in str(exc):
            emit("DETAIL", "%s is owned by uid %d but the container runs as uid %d; %s"
                 % (repo, os.stat(repo).st_uid, uid, FIX_OWNER))
        return False

    if dated:
        ok = False
        msg = "%s: %s" % (name, describe(dated, unmerged))
        if not left_behind(dated):
            emit("INFO", msg)
        elif reset_blocker(repo, readonly, locks, state):
            emit("WARN", msg)
        else:
            emit("WARN", "%s; if they are not needed, discard them (git reset --hard) with '%s'"
                 % (msg, mode_arg))
        list_files(repo, dated)

    if ahead > 0:
        ok = False
        try:
            times = [int(t) for t in git(repo, "log", "--format=%ct", "@{upstream}..HEAD").stdout.split()]
        except (subprocess.TimeoutExpired, ValueError):
            times = []
        oldest = now - min(times) if times else None
        when = "" if oldest is None else ", the oldest from %s ago" % duration(oldest)
        emit("WARN" if oldest is None or oldest >= dirty_age else "INFO",
             "%s: %d commit(s) not pushed to gitd%s" % (name, ahead, when))
    return ok


def list_reset(repo):
    """Report the uncommitted files and stale locks left behind in one repo; True if it has no
    uncommitted files."""
    name = os.path.relpath(repo, root)
    readonly, locks, state = scan_git_dir(git_dir(repo))
    try:
        _, dated, unmerged = git_status(repo)
    except subprocess.TimeoutExpired:
        emit("WARN", "%s: skipped, git status did not finish within %ds" % (name, GIT_TIMEOUT))
        return False
    except GitError as exc:
        emit("WARN", "%s: skipped, git status failed: %s" % (name, exc))
        return False
    if locks and all(a >= LOCK_AGE for _, a in locks):
        # git refuses to work in the repo, so no backup or policy run can commit its files
        msg = "%s: %s" % (name, describe_locks(repo, locks))
        if dated:
            msg += " and " + describe(dated, unmerged)
        reason = reset_blocker(repo, readonly, locks, state, unlock=True)
        if reason:
            emit("WARN", "%s; skipped, %s" % (msg, reason))
        else:
            emit("INFO", msg)
            list_files(repo, dated)
            emit("UNLOCK", name)
        return False
    if not dated:
        return True
    msg = "%s: %s" % (name, describe(dated, unmerged))
    reason = reset_blocker(repo, readonly, locks, state)
    if not left_behind(dated):
        emit("INFO", "%s; skipped, a backup or policy run may still commit them" % msg)
    elif reason:
        emit("WARN", "%s; skipped, %s" % (msg, reason))
    else:
        emit("INFO", msg)
        list_files(repo, dated)
        emit("RESET", name)
    return False


def reset(repo, unlock):
    """Discard the uncommitted files of one repo with git reset --hard and git clean;
    with unlock, remove its stale locks first."""
    name = os.path.relpath(repo, root)
    if not os.path.exists(os.path.join(repo, ".git")):
        emit("WARN", "%s: not reset, it is no longer a git repo" % name)
        return
    readonly, locks, state = scan_git_dir(git_dir(repo))
    reason = reset_blocker(repo, readonly, locks, state, unlock)
    if reason:
        emit("WARN", "%s: not reset, %s" % (name, reason))
        return
    if locks:
        for lock, _ in locks:
            try:
                os.remove(lock)
            except FileNotFoundError:
                pass
        emit("INFO", "%s: removed the %s" % (name, describe_locks(repo, locks)))
    _, before, _ = git_status(repo)
    for args in (("reset", "--hard", "--quiet"), ("clean", "-d", "--force", "--quiet")):
        proc = git(repo, *args)
        if proc.returncode:
            emit("FAIL", "%s: git %s failed: %s" % (name, args[0], git_error(proc)))
            return
    _, after, _ = git_status(repo)
    head = git(repo, "rev-parse", "--short", "HEAD").stdout.decode(errors="replace").strip()
    if after:
        emit("WARN", "%s: reset to %s, but %d uncommitted file(s) are left" % (name, head, len(after)))
        list_files(repo, after)
    elif before:
        emit("PASS", "%s: reset to %s, discarded %d uncommitted file(s)" % (name, head, len(before)))
    else:
        emit("PASS", "%s: reset to %s, no uncommitted files" % (name, head))


if not os.path.isdir(root):
    emit("WARN", "%s does not exist in the %s container" % (root, container))
    sys.exit(0)
if not shutil.which("git"):
    emit("WARN", "no git in the %s container, cannot check %s" % (container, root))
    sys.exit(0)
if mode in ("reset", "unlock"):
    for name in mode_arg.splitlines():
        try:
            reset(os.path.join(root, name), mode == "unlock")
        except Exception as exc:
            emit("FAIL", "%s: could not reset: %s" % (name, exc))
    sys.exit(0)
clean, found = [], 0
for repo in find_repos():
    found += 1
    try:
        if (list_reset if mode == "list" else check)(repo):
            clean.append(os.path.relpath(repo, root))
    except Exception as exc:
        emit("WARN", "%s: could not check: %s" % (os.path.relpath(repo, root), exc))
if not found:
    emit("INFO", "no git repos found in %s" % root)
elif clean:
    names = ", ".join(clean[:10]) + (" and %d more" % (len(clean) - 10) if len(clean) > 10 else "")
    emit("PASS", "%d of %d repo(s) %s: %s" % (
        len(clean), found, "without uncommitted files" if mode == "list" else "clean", names))
EOF

# Classify log lines as C (critical) or E (error); lines with an explicit
# lower log level are skipped. Python tracebacks are reported by their final
# exception line. Matches the [ERROR] and " ERROR/" markers the api uses in
# app/core/logs.py plus postgres, nginx, glog and logfmt/json styles.
IFS= read -r -d '' AWK_CLASSIFY <<'EOF'
function emit(sev, text) {
    if (ign != "" && text ~ ign) return
    print sev "\t" text
}
BEGIN { ign = ENVIRON["NP_IGNORE"] }
{
    line = $0
    sub(/\r$/, "", line)
    l = tolower(line)
    if (tb) {
        if (line ~ /^[ \t]/ || line == "" || l ~ /^(during handling of the above exception|the above exception was the direct cause)/)
            next
        tb = 0
        if (l !~ /^traceback \(most recent call last\)/) {
            emit("E", "Traceback: " line)
            next
        }
    }
    if (l ~ /^traceback \(most recent call last\)/) { tb = 1; next }
    if (l ~ /\[(info|debug|trace|notice|warn|warning)\]|[ :](info|debug|trace|warning)\/|level=(info|debug|trace|warn|warning)|"level": ?"(info|debug|trace|warn|warning)"/)
        next
    # git prints "fatal:" for every failed request, and postgres says FATAL on restarts
    if (line ~ /^fatal: / || l ~ /the database system is (starting up|shutting down|in recovery mode)|terminating connection due to administrator command/) {
        emit("E", line)
        next
    }
    if (l ~ /\[(critical|crit|fatal|emerg|alert|panic)\]|[ :](critical|fatal)\/|(^|[^a-z_.])(fatal|panic|critical):|level=(fatal|panic)|"level": ?"(fatal|panic)"|out of memory|oom-kill|^f[0-9][0-9][0-9][0-9] [0-9]/) {
        emit("C", line)
        next
    }
    if (l ~ /\[error\]|[ :]error\/|(^|[^a-z_.])error:|level=error|"level": ?"error"|^e[0-9][0-9][0-9][0-9] [0-9]|background saving error|misconf/)
        emit("E", line)
}
END { if (tb) emit("E", "Traceback (truncated)") }
EOF

# Group classified lines that differ only in numbers and ids.
# Output: count<TAB>latest example
IFS= read -r -d '' AWK_GROUP <<'EOF'
BEGIN { FS = "\t" }
{
    text = substr($0, length($1) + 2)
    key = text
    gsub(/0x[0-9a-fA-F]+/, "#", key)
    gsub(/[0-9a-fA-F]*[0-9][0-9a-fA-F]*/, "#", key)
    if (!(key in count)) order[++n] = key
    count[key]++
    example[key] = text
}
END {
    for (i = 1; i <= n; i++)
        printf "%d\t%s\n", count[order[i]], substr(example[order[i]], 1, 200)
}
EOF

# ---------------------------------------------------------------------------
# helpers running commands in containers

probe() {
    docker exec "$1" sh -c "$PROBE_SH" probe "$2" "${3%:*}" "${3##*:}" </dev/null 2>&1
}

rcli() {
    if [ -n "$REDIS_PW" ]; then
        REDISCLI_AUTH=$REDIS_PW docker exec -e REDISCLI_AUTH "$REDIS_C" redis-cli "$@" </dev/null
    else
        docker exec "$REDIS_C" redis-cli "$@" </dev/null
    fi
}

# rlua DB SCRIPT [ARG...]: run a Lua script in a redis database
rlua() {
    local db=$1 script=$2
    shift 2
    if [ -n "$REDIS_PW" ]; then
        printf '%s' "$script" | REDISCLI_AUTH=$REDIS_PW docker exec -i -e REDISCLI_AUTH "$REDIS_C" \
            sh -c 'db=$1; shift; redis-cli --raw -n "$db" EVAL "$(cat)" 0 "$@"' sh "$db" "$@"
    else
        printf '%s' "$script" | docker exec -i "$REDIS_C" \
            sh -c 'db=$1; shift; redis-cli --raw -n "$db" EVAL "$(cat)" 0 "$@"' sh "$db" "$@"
    fi
}

# run alembic in /opt of the api image, which holds the image's migrations
alembic_cmd() {
    local c
    c=$(svc_running api)
    if [ -n "$c" ]; then
        docker exec "$c" sh -c 'cd /opt && alembic "$@"' alembic "$@" </dev/null 2>&1
    elif [ -n "$API_IMAGE" ]; then
        docker run --rm --network none --entrypoint sh "$API_IMAGE" \
            -c 'cd /opt && alembic "$@"' alembic "$@" </dev/null 2>&1
    else
        echo "no api container or image to run alembic in"
        return 1
    fi
}

# db_query SQL: print the rows of a query, tab-separated
db_query() {
    local dbc name user out c rc
    dbc=
    case "$DB_HP" in
        db:*) dbc=$(svc_running db) ;;
    esac
    if [ -n "$dbc" ]; then
        name=$(env_get "$ENV_API" API_DB_NAME)
        user=$(env_get "$ENV_API" API_DB_USER)
        if out=$(docker exec "$dbc" psql -X -q -t -A -F "$TAB" -U "${user:-netpicker}" -d "${name:-netpicker}" \
            -c "$1" </dev/null 2>&1); then
            printf '%s\n' "$out"
            return 0
        fi
        # the query failed, not the connection: the api code fails the same way
        case "$out" in
            *ERROR:*) printf '%s\n' "$out"; return 1 ;;
        esac
    fi
    # external database, or psql did not work: ask the api code
    if ! c=$(first_running api celery committer); then
        echo "${out:-no running db, api, celery or committer container to query the database}"
        return 1
    fi
    out=$(docker exec "$c" python3 -c "$PY_DB_QUERY" "$1" </dev/null 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        printf '%s\n' "$out"
    else
        # the exception, not the [SQL: ...] that sqlalchemy prints after it
        printf '%s\n' "$out" | grep -E '^[A-Za-z_.]+(Error|Exception)[:(]' | tail -n 1 | grep . ||
            printf '%s\n' "$out" | tail -n 3
    fi
    return $rc
}

# print the revision(s) in the alembic_version table
db_revision() {
    db_query 'SELECT version_num FROM alembic_version'
}

health_output() {
    docker inspect -f '{{if .State.Health}}{{range .State.Health.Log}}{{json .Output}}{{"\n"}}{{end}}{{end}}' "$1" 2>/dev/null |
        grep -v '^$' | tail -n 1 |
        sed -e 's/^"//' -e 's/"$//' -e 's/\\n/ | /g' -e 's/\\u003c/</g' -e 's/\\u003e/>/g' -e 's/\\u0026/\&/g' |
        cut -c1-300
}

# ---------------------------------------------------------------------------
# checks

preflight() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
    DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>&1) ||
        die "cannot talk to the Docker daemon: $DOCKER_VERSION
Run this script as root or as a member of the docker group."
    DOCKER_INFO=$(docker info --format '{{.OperatingSystem}}|{{.KernelVersion}}|{{.NCPU}}|{{.MemTotal}}|{{.Driver}}|{{.DockerRootDir}}' 2>/dev/null)
    DOCKER_ROOT=$(printf '%s' "$DOCKER_INFO" | cut -d'|' -f6)
}

detect_project() {
    local projects count
    [ -z "$PROJECT" ] || return 0
    projects=$(docker ps -a --filter label=service.netpicker.io=api \
        --format '{{.Label "com.docker.compose.project"}}' | grep -v '^$' | sort -u)
    if [ -z "$projects" ]; then
        projects=$(docker ps -a --filter label=com.docker.compose.service=api \
            --format '{{.Label "com.docker.compose.project"}}' | grep -v '^$' | sort -u)
    fi
    count=$(printf '%s\n' "$projects" | grep -c .)
    case "$count" in
        0) die "no Netpicker stack found (no container of a compose service 'api'); use --project NAME" ;;
        1) PROJECT=$projects ;;
        *) die "found several Netpicker stacks: $(echo $projects); pick one with --project NAME" ;;
    esac
}

print_environment() {
    local ref ver c os kernel ncpu mem driver
    section "Environment"
    info "Host $(hostname), $(date '+%Y-%m-%d %H:%M:%S %Z'), Docker $DOCKER_VERSION"
    if [ -n "$DOCKER_INFO" ]; then
        IFS='|' read -r os kernel ncpu mem driver _ <<EOF
$DOCKER_INFO
EOF
        info "Docker runs on $os, kernel $kernel, $ncpu CPU(s), $(human_kib $((mem / 1024))) memory, storage driver $driver"
    fi
    info "Compose project $PROJECT with $(printf '%s\n' "$CTR" | grep -c .) containers"
    [ -z "$COMPOSE_FILES" ] || info "Compose files: $(printf '%s\n' "$COMPOSE_FILES" | paste -sd, - | sed 's/,/, /g')"
    if [ -n "$API_ANY" ]; then
        ref=$(ctr_field "$API_ANY" 9)
        c=$(svc_running api)
        if [ -n "$c" ]; then
            ver=$(docker exec "$c" python3 -c 'import importlib.metadata as m; print(m.version("netyce-api"))' </dev/null 2>/dev/null)
        fi
        info "api image $ref${ver:+ (netyce-api $ver)}"
    fi
}

# the version number in the root page of the frontend, which newer frontend
# builds put in <meta name="netpicker-version" content="2.8.1">; the login page
# shows it too, but only once the app runs in a browser
frontend_version() {
    local c html
    c=$(svc_running frontend)
    [ -n "$c" ] || return 1
    html=$(docker exec "$c" wget -q -T 5 -O - http://127.0.0.1/ </dev/null 2>/dev/null) ||
        html=$(docker exec "$c" wget -q -T 5 --no-check-certificate -O - https://127.0.0.1/ </dev/null 2>/dev/null) ||
        return 1
    printf '%s\n' "$html" | grep -o -i -E 'version[^0-9<]{0,40}[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?' | sed -n 1p |
        grep -o -E '[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?$'
}

# image_version CONTAINER: the version in the image tag of the container, or
# in another tag of the same image (latest is the same image as the release
# when both were pulled)
image_version() {
    local ref v
    ref=$(ctr_field "$1" 9)
    v=$(printf '%s\n' "${ref##*:}" | grep -E "$VERSION_RE")
    if [ -n "$v" ]; then
        printf '%s\n' "$v"
        return
    fi
    docker image inspect -f '{{range .RepoTags}}{{println .}}{{end}}' "$(ctr_field "$1" 8)" 2>/dev/null |
        sed -n 's/^.*:\([^:/]*\)$/\1/p' | grep -E "$VERSION_RE" | ver_max
}

# Set REPO_VERSION to the release this checkout belongs to and REPO_VERSION_HOW
# to why. Releases are tagged on release branches that fork off main, so
# HEAD belongs to the newest release that is in its history: either the tag
# is an ancestor of HEAD, or its release branch forked off an ancestor (main
# after the 2.8.1 release branch forked off is 2.8.1). Tags whose history
# contains HEAD are later releases.
repo_version() {
    local head t mb depth best= best_depth=-1 best_mb= n
    REPO_VERSION= REPO_VERSION_HOW=
    head=$(rgit rev-parse HEAD 2>/dev/null) || return 1
    t=$(rgit tag --points-at HEAD | grep -E "$VERSION_RE" | ver_max)
    if [ -n "$t" ]; then
        REPO_VERSION=$t
        REPO_VERSION_HOW="tagged $t"
        return 0
    fi
    for t in $(rgit tag -l | grep -E "$RELEASE_RE"); do
        mb=$(rgit merge-base HEAD "$t" 2>/dev/null) || continue
        [ "$mb" != "$head" ] || continue
        depth=$(rgit rev-list --count "$mb")
        if [ "$depth" -gt "$best_depth" ] ||
            { [ "$depth" -eq "$best_depth" ] && [ "$(ver_cmp "$t" "$best")" -gt 0 ]; }; then
            best=$t best_depth=$depth best_mb=$mb
        fi
    done
    [ -n "$best" ] || return 1
    n=$(rgit rev-list --count "$best_mb..HEAD")
    REPO_VERSION=$best
    if [ "$(rgit rev-parse "$best^{commit}")" = "$best_mb" ]; then
        REPO_VERSION_HOW="$n commit(s) after the tag $best"
    else
        REPO_VERSION_HOW="$n commit(s) after the release branch of $best forked off"
    fi
}

check_version() {
    local svc c v ref why branch newest age vers
    section "Netpicker version"
    RUN_VERSION=
    if [ -z "$(svc_running frontend)" ]; then
        why="the frontend does not run"
    elif v=$(frontend_version); [ -n "$v" ]; then
        RUN_VERSION=$v
        info "the frontend publishes version $v in its root page"
    else
        why="the root page of the frontend has no version number"
    fi
    if [ -z "$RUN_VERSION" ]; then
        for svc in frontend api; do
            c=$(svc_any "$svc")
            [ -n "$c" ] || continue
            v=$(image_version "$c")
            [ -n "$v" ] || continue
            RUN_VERSION=$v
            ref=$(ctr_field "$c" 9)
            if [ "${ref##*:}" = "$v" ]; then
                info "Netpicker $v runs: the $svc image is $ref ($why)"
            else
                info "Netpicker $v runs: the $svc image $ref is the same image as $v ($why)"
            fi
            break
        done
    fi
    if [ -z "$RUN_VERSION" ]; then
        c=$(svc_any frontend)
        info "cannot tell which version runs: $why and the images have no version tag"
        if [ -n "$c" ]; then
            detail "the frontend image $(ctr_field "$c" 9) was built $(docker image inspect -f '{{.Created}}' "$(ctr_field "$c" 8)" 2>/dev/null | cut -c1-10)"
        fi
    fi

    # the netpicker images, apart from db and minio that have their own versions
    vers=$(printf '%s\n' "$CTR" | awk -F'|' '$3 == "running" && $9 ~ /(^|\/)netpicker\// && $9 !~ /netpicker\/(db|minio)(:|$)/ { print $1 "|" $2 }' |
        while IFS='|' read -r svc c; do
            v=$(image_version "$c")
            [ -z "$v" ] || printf '%s %s\n' "$v" "$svc"
        done | sort -u)
    if [ "$(printf '%s\n' "$vers" | awk 'NF { print $1 }' | sort -u | grep -c .)" -gt 1 ]; then
        warn "the containers run different Netpicker versions: $(printf '%s\n' "$vers" | awk '
            { s[$1] = s[$1] (s[$1] == "" ? "" : ", ") $2 }
            END { for (v in s) printf "%s%s (%s)", (n++ ? "; " : ""), v, s[v]; print "" }'); update them with 'docker compose pull && docker compose up -d'"
    fi

    if [ -z "$REPO" ]; then
        info "$REPO_ERR; skipped the comparison with the release tags"
        return
    fi
    if ! repo_version; then
        info "no release tags in $REPO; get them with 'git fetch --tags'"
        return
    fi
    branch=$(rgit symbolic-ref --short -q HEAD) || branch="detached HEAD"
    info "the repo $REPO is at $REPO_VERSION: $branch $(rgit rev-parse --short HEAD), $REPO_VERSION_HOW"
    if [ -n "$RUN_VERSION" ]; then
        case $(ver_cmp "$RUN_VERSION" "$REPO_VERSION") in
            0) pass "the stack runs $RUN_VERSION, the version of the repo" ;;
            1) warn "the stack runs $RUN_VERSION, newer than the repo ($REPO_VERSION); 'git pull' to get the compose files of $RUN_VERSION" ;;
            *) warn "the stack runs $RUN_VERSION, older than the repo ($REPO_VERSION); update the images with 'docker compose pull && docker compose up -d'" ;;
        esac
        if ! rgit rev-parse -q --verify "refs/tags/$RUN_VERSION" >/dev/null &&
            ! rgit rev-parse -q --verify "refs/tags/v$RUN_VERSION" >/dev/null; then
            detail "$RUN_VERSION is not a tag in this clone; 'git fetch --tags' gets the tags of newer releases"
        fi
    fi
    newest=$(rgit tag -l | grep -E "$RELEASE_RE" | ver_max)
    if [ -n "$newest" ] && [ "$(ver_cmp "$newest" "${RUN_VERSION:-$REPO_VERSION}")" -gt 0 ]; then
        age=$(fetch_age)
        info "release $newest is available${age:+ (the newest tag as of the last 'git fetch', $(human_duration "$age") ago)}"
    fi
}

meminfo() {
    awk -v k="$1:" '$1 == k { print $2; exit }' /proc/meminfo
}

# percent_ge VALUE LIMIT: VALUE >= LIMIT, for decimal numbers
percent_ge() {
    awk -v v="$1" -v l="$2" 'BEGIN { exit !(v + 0 >= l + 0) }'
}

check_host() {
    local up ncpu load1 load5 load15 busy iowait steal msg total avail pct swap_total swap_free oom
    section "Host resources"
    if [ ! -r /proc/stat ] || [ ! -r /proc/meminfo ]; then
        info "not a Linux host, skipped the CPU and memory checks${DOCKER_INFO:+ (see the Docker line above)}"
        command -v uptime >/dev/null 2>&1 && info "uptime: $(uptime | sed 's/^ *//')"
        return
    fi
    if [ -n "${DOCKER_HOST:-}" ]; then
        warn "DOCKER_HOST is set: these checks are about $(hostname), which may not be the Docker host"
    fi

    ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    up=$(cut -d. -f1 /proc/uptime)
    read -r load1 load5 load15 _ </proc/loadavg
    info "up $(human_duration "$up"), load average $load1, $load5, $load15 (1, 5, 15 min) on $ncpu CPU(s)"
    if [ "$up" -lt 3600 ]; then
        warn "the host booted $(human_duration "$up") ago; if that was not planned, see the end of the previous boot's log ('journalctl -b -1 -e')"
    fi
    if ! percent_ge "$ncpu" "$load5"; then
        warn "load average over 5 minutes is $load5 on $ncpu CPU(s); processes are waiting for CPU or disk"
    fi

    # busy, iowait and steal percentages of all CPUs over one second
    read -r busy iowait steal <<EOF
$({ head -n 1 /proc/stat; sleep 1; head -n 1 /proc/stat; } | awk '
    { t = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9 }
    NR == 1 { t0 = t; i0 = $5; w0 = $6; s0 = $9; next }
    t > t0 { d = t - t0; printf "%d %d %d\n", 100 * (d - ($5 - i0) - ($6 - w0)) / d, 100 * ($6 - w0) / d, 100 * ($9 - s0) / d }')
EOF
    if [ -n "$busy" ]; then
        msg="CPU ${busy}% busy, ${iowait}% waiting for disk I/O, ${steal}% stolen by the hypervisor (1s sample)"
        if [ "$busy" -ge "$CPU_WARN" ]; then
            warn "$msg; the host has no CPU to spare"
        elif [ "$iowait" -ge 20 ]; then
            warn "$msg; the disk is too slow for the load"
        elif [ "$steal" -ge 10 ]; then
            warn "$msg; the VM gets less CPU than it was given (a burstable instance out of CPU credits?)"
        else
            pass "$msg"
        fi
    fi

    total=$(meminfo MemTotal)
    avail=$(meminfo MemAvailable)
    [ -n "$avail" ] || avail=$(($(meminfo MemFree) + $(meminfo Buffers) + $(meminfo Cached)))
    pct=$(((total - avail) * 100 / total))
    msg="memory: $(human_kib $((total - avail))) of $(human_kib "$total") used (${pct}%), $(human_kib "$avail") available"
    if [ "$pct" -ge "$MEM_FAIL" ]; then
        fail "$msg; the kernel kills processes when it runs out"
    elif [ "$pct" -ge "$MEM_WARN" ]; then
        warn "$msg; the host is low on memory"
    else
        pass "$msg"
    fi
    swap_total=$(meminfo SwapTotal)
    swap_free=$(meminfo SwapFree)
    if [ "${swap_total:-0}" -gt 0 ]; then
        pct=$(((swap_total - swap_free) * 100 / swap_total))
        msg="swap: $(human_kib $((swap_total - swap_free))) of $(human_kib "$swap_total") used (${pct}%)"
        if [ "$pct" -ge 50 ]; then warn "$msg; the host is short of memory, which makes it slow"; else pass "$msg"; fi
    fi
    oom=$(awk '$1 == "oom_kill" { print $2; exit }' /proc/vmstat 2>/dev/null)
    if [ "${oom:-0}" -gt 0 ]; then
        warn "the kernel OOM killer killed $oom process(es) since the host booted; see 'dmesg -T | grep -i \"killed process\"'"
    fi
}

# disk_rows: "label<TAB>df -Pk row<TAB>df -Pi row" for the host's root, the
# Docker root, the compose directory and every volume of the running
# containers; the volumes that cannot be checked go to $WORK/df-skipped
disk_rows() {
    local running mounts c cn vol dest svc out seen=" "
    set -- "host /" /
    [ -z "$DOCKER_ROOT" ] || [ ! -d "$DOCKER_ROOT" ] || set -- "$@" "docker root" "$DOCKER_ROOT"
    [ -z "$COMPOSE_WD" ] || [ ! -d "$COMPOSE_WD" ] || set -- "$@" "compose dir" "$COMPOSE_WD"
    sh -c "$DF_SH" df "$@"

    # a volume is on the Docker host, which is not necessarily this machine
    running=$(printf '%s\n' "$CTR" | awk -F'|' '$3 == "running" { print $2 }')
    [ -n "$running" ] || return 0
    # shellcheck disable=SC2086
    mounts=$(docker inspect -f '{{$n := .Name}}{{range .Mounts}}{{if eq .Type "volume"}}{{$n}}|{{.Name}}|{{.Destination}}{{"\n"}}{{end}}{{end}}' $running |
        sed 's#^/##')
    for c in $running; do
        svc=$(ctr_field "$c" 1)
        set --
        while IFS='|' read -r cn vol dest; do
            [ "$cn" = "$c" ] || continue
            case "$seen" in
                *" $vol "*) continue ;;
            esac
            seen="$seen$vol "
            set -- "$@" "${svc:-$c}:$dest" "$dest"
        done <<EOF
$mounts
EOF
        [ $# -gt 0 ] || continue
        out=$(docker exec "$c" sh -c "$DF_SH" df "$@" </dev/null 2>/dev/null)
        if [ -n "$out" ]; then
            printf '%s\n' "$out"
        else
            echo "${svc:-$c}" >>"$WORK/df-skipped"
        fi
    done
}

check_disk() {
    local rows labels fs size avail pct ipct msg low=0 unrotated= nunrotated=0 big= name type maxsize path bytes
    section "Disk space"
    # one line per filesystem: labels, filesystem, size, available, use%, inode use%
    rows=$(disk_rows | awk -F'\t' '
        {
            if (split($2, s, " ") < 5) next
            key = s[1] " " s[2]
            if (key in label) { label[key] = label[key] ", " $1; next }
            order[++n] = key
            label[key] = $1
            # the last percentage: macOS "df -Pi" also has the block capacity
            ip = "-"
            ni = split($3, i, " ")
            for (f = 1; f <= ni; f++) if (i[f] ~ /%$/) ip = i[f]
            row[key] = s[1] FS s[2] FS s[4] FS s[5] FS ip
        }
        END { for (k = 1; k <= n; k++) print label[order[k]] FS row[order[k]] }')
    while IFS="$TAB" read -r labels fs size avail pct ipct; do
        [ -n "$fs" ] || continue
        pct=${pct%\%}
        ipct=${ipct%\%}
        msg="$fs ($labels): ${pct}% used, $(human_kib "$avail") of $(human_kib "$size") free"
        # btrfs and some network filesystems have no inode counts
        case "$ipct" in
            '' | *[!0-9]*) ipct=0 ;;
            *) msg="$msg, ${ipct}% of the inodes used" ;;
        esac
        if [ "$ipct" -ge "$DISK_FAIL" ]; then
            fail "$msg; it is out of inodes, so no new files can be created"
            low=1
        elif [ "$pct" -ge "$DISK_FAIL" ]; then
            fail "$msg; the database, redis and git stop working when it is full"
            low=1
        elif [ "$pct" -ge "$DISK_WARN" ] || [ "$ipct" -ge "$DISK_WARN" ]; then
            warn "$msg; it is filling up"
            low=1
        else
            pass "$msg"
        fi
    done <<EOF
$rows
EOF
    if [ $low -eq 1 ]; then
        detail "Docker disk usage ('docker system df'):"
        docker system df --format '{{.Type}}: {{.Size}}, {{.Reclaimable}} reclaimable' 2>&1 | details
        detail "'docker image prune' removes the images of earlier versions that no container uses."
    fi

    # json-file logs grow until the disk is full unless max-size is set
    while IFS='|' read -r name type maxsize path; do
        [ -n "$name" ] || continue
        if [ "$type" = json-file ] && { [ -z "$maxsize" ] || [ "$maxsize" = "<no value>" ]; }; then
            unrotated="$unrotated $name"
            nunrotated=$((nunrotated + 1))
        fi
        # the log files are only readable as root
        if [ -n "$path" ] && [ -r "$path" ]; then
            bytes=$(wc -c <"$path" 2>/dev/null)
            if [ "${bytes:-0}" -ge 1073741824 ]; then
                big="$big, $name $(human_kib $((bytes / 1024)))"
            fi
        fi
    done <<EOF
$(printf '%s\n' "$CTR" | cut -d'|' -f2 | xargs docker inspect -f '{{.Name}}|{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{.LogPath}}' 2>/dev/null | sed 's#^/##')
EOF
    if [ $nunrotated -gt 0 ]; then
        warn "the logs of $nunrotated container(s) are not rotated (json-file log driver without max-size) and grow until the disk is full:$unrotated"
        detail "Set \"log-opts\": {\"max-size\": \"50m\", \"max-file\": \"3\"} in /etc/docker/daemon.json, restart Docker and recreate the containers."
    fi
    [ -z "$big" ] || warn "large container logs: ${big#, }"
    if [ -s "$WORK/df-skipped" ]; then
        info "could not check the volumes of (no sh or df in the container): $(sort -u "$WORK/df-skipped" | paste -sd, - | sed 's/,/, /g')"
    fi
}

check_service() {
    local svc=$1 level=$2 names name status health restarts oom exitcode label out
    names=$(svc_containers "$svc")
    if [ -z "$names" ]; then
        if [ "$level" = warn ]; then
            warn "$(pad "$svc") not found (optional service)"
        else
            fail "$(pad "$svc") no container found; start it with 'docker compose up -d'"
        fi
        return
    fi
    for name in $names; do
        IFS='|' read -r _ _ status health restarts oom exitcode _ <<EOF
$(ctr_line "$name")
EOF
        label=$(pad "$svc")
        [ "$name" = "$svc" ] || label="$label $name:"
        case "$status/$health" in
            running/healthy) pass "$label running, healthy" ;;
            running/none) pass "$label running (no health check)" ;;
            running/starting) warn "$label running, health check still starting" ;;
            running/unhealthy)
                "$level" "$label running but unhealthy"
                out=$(health_output "$name")
                [ -z "$out" ] || detail "last health check: $out"
                ;;
            restarting/*)
                "$level" "$label restarting (last exit code $exitcode), it keeps crashing; last log lines:"
                docker logs --tail 5 "$name" 2>&1 | cut -c1-200 | details
                ;;
            *)
                "$level" "$label $status (exit code $exitcode); last log lines:"
                docker logs --tail 5 "$name" 2>&1 | cut -c1-200 | details
                ;;
        esac
        if [ "$oom" = true ]; then
            fail "$label was killed by the kernel OOM killer; give the host or container more memory"
        fi
        if [ "${restarts:-0}" -gt 0 ] 2>/dev/null; then
            warn "$label restarted $restarts time(s) since it was created"
        fi
    done
}

check_containers() {
    local svc
    section "Containers"
    for svc in $REQUIRED_SERVICES; do
        check_service "$svc" fail
    done
    for svc in $OPTIONAL_SERVICES; do
        check_service "$svc" warn
    done
    # anything else in the project, e.g. extra agents or services from options/
    for svc in $(printf '%s\n' "$CTR" | cut -d'|' -f1 | sort -u); do
        case " $REQUIRED_SERVICES $OPTIONAL_SERVICES $ONESHOT_SERVICES " in
            *" $svc "*) continue ;;
        esac
        check_service "$svc" warn
    done
}

# file_role PATH STACK_FILES MOUNTS: what a changed file of the repo is to the
# stack; STACK_FILES are the compose files of the stack and MOUNTS the
# service|path|destination of the bind mounts, both with paths in the repo
file_role() {
    local svcs
    if printf '%s\n' "$2" | grep -qxF -- "$1"; then
        echo "a compose file of the running stack"
        return
    fi
    svcs=$(printf '%s\n' "$3" | awk -F'|' -v p="$1" '
        $2 != "" && (p == $2 || index(p, $2 "/") == 1) && !seen[$1 $3]++ { printf "%s%s (%s)", (n++ ? ", " : ""), $1, $3 }')
    if [ -n "$svcs" ]; then
        echo "mounted into $svcs"
        return
    fi
    case "$1" in
        "${WD_PREFIX}docker-compose.override.yml" | "${WD_PREFIX}docker-compose.override.yaml" | \
            "${WD_PREFIX}compose.override.yml" | "${WD_PREFIX}compose.override.yaml")
            echo "not used by the running stack, but the next 'docker compose up' reads it" ;;
        "${WD_PREFIX}.env") echo "sets the variables of the compose files" ;;
        netpicker-chart/*) echo "the Helm chart, not used by Docker Compose" ;;
        podman/*) echo "for Podman, not used by Docker Compose" ;;
        docs/* | *.md) echo "documentation" ;;
        *.sh) echo "a script" ;;
        *.yml | *.yaml) echo "a compose file the running stack does not use" ;;
    esac
}

# What the local changes do to the compose config of the stack: compare the
# config from the compose files at $BASE with the config from the files now.
# Sets CHANGED_SVCS to the services the changes alter.
compose_impact() {
    local out kind a b c d line rel vols warns= details= n=0 max=10
    CHANGED_SVCS=" " REMOVED_SVCS=" "
    [ $VERBOSE -eq 0 ] || max=100
    rel=$(printf '%s\n' "$STACK_REL" | while IFS= read -r rel; do
        [ -n "$rel" ] && rgit cat-file -e "$BASE:$rel" 2>/dev/null && { echo "$rel"; break; }
    done)
    if [ -z "$rel" ]; then
        info "the compose files of the stack were not in the repo at $(rgit rev-parse --short "$BASE"), so there is nothing to compare them with"
        return
    fi
    if ! compose_run base config >"$WORK/compose-base.yml" 2>"$WORK/compose.err"; then
        info "cannot read the compose files as they were at $(rgit rev-parse --short "$BASE"): $(grep . "$WORK/compose.err" | tail -n 1)"
        return
    fi
    awk "$AWK_FLAT" "$WORK/compose-base.yml" >"$WORK/compose-base.flat"
    printf '%s\n' "$CUR_CFG" | awk "$AWK_FLAT" >"$WORK/compose-cur.flat"
    out=$(awk "$AWK_CDIFF" "$WORK/compose-base.flat" "$WORK/compose-cur.flat")
    if [ -z "$out" ]; then
        pass "the local changes leave the compose config of the stack as it is in the repo"
        return
    fi
    while IFS="$TAB" read -r kind a b c d; do
        case "$kind" in
            R)
                CHANGED_SVCS="$CHANGED_SVCS$a "
                REMOVED_SVCS="$REMOVED_SVCS$a "
                case " $REQUIRED_SERVICES " in
                    *" $a "*) fail "$(pad "$a") removed from the compose config by the local changes; Netpicker does not work without it" ;;
                    *) warn "$(pad "$a") removed from the compose config by the local changes" ;;
                esac
                if [ -n "$(svc_containers "$a")" ]; then
                    detail "its container still exists from before; 'docker compose up -d --remove-orphans' removes it"
                else
                    detail "that is why it has no container"
                fi
                ;;
            A)
                CHANGED_SVCS="$CHANGED_SVCS$a "
                info "$(pad "$a") added by the local changes${b:+ (image $b)}"
                ;;
            C)
                CHANGED_SVCS="$CHANGED_SVCS$(printf '%s' "$a" | sed 's/, / /g') "
                vols=
                case "$c/$d" in
                    removed/*) vols=${d#was } ;;
                    changed/removed*) vols=${d#removed }; vols=${vols%%; added *} ;;
                esac
                if [ "$b" = image ] && [ -n "$d" ]; then
                    warns="$warns$a: the local changes run another image than the repo: $d$TAB"
                elif [ "$b" = volumes ] && [ -n "$vols" ]; then
                    warns="$warns$a: the local changes no longer mount $vols, so the data written there is not kept or shared$TAB"
                else
                    n=$((n + 1))
                    [ $n -gt $max ] || details="$details$a: $b $c${d:+: $d}$TAB"
                fi
                ;;
        esac
    done <<EOF
$out
EOF
    while IFS= read -r line; do
        [ -z "$line" ] || warn "$line"
    done <<EOF
$(printf '%s' "$warns" | tr "$TAB" '\n')
EOF
    if [ $n -gt 0 ]; then
        if [ -n "$warns" ]; then
            info "the local changes also alter $n other setting(s) of the compose config:"
        else
            info "the local changes alter $n setting(s) of the compose config:"
        fi
        printf '%s' "$details" | tr "$TAB" '\n' | details
        [ $n -le $max ] || detail "... and $((n - max)) more; see them all with --verbose"
    fi
}

# The local changes to the repo: commits not on the upstream branch, and
# uncommitted and untracked files. Sets BASE to the commit they are relative to.
repo_changes() {
    local up behind ahead age files baks n ntracked path what lines role mounts running f max=10
    [ $VERBOSE -eq 0 ] || max=50
    # the compose files of the stack, with their paths in the repo
    STACK_REL=$(printf '%s\n' "$COMPOSE_FILES" | while IFS= read -r f; do repo_rel "$f"; done)
    up=$(rgit rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)
    if [ -n "$up" ]; then
        BASE=$(rgit merge-base HEAD "$up")
        read -r behind ahead <<EOF
$(rgit rev-list --left-right --count "$up...HEAD")
EOF
        if [ "${behind:-0}" -gt 0 ]; then
            age=$(fetch_age)
            info "$behind commit(s) on $up are not pulled yet${age:+ (as of the last 'git fetch', $(human_duration "$age") ago)}; update.sh pulls them"
        fi
        if [ "${ahead:-0}" -gt 0 ]; then
            info "$ahead local commit(s) that are not on $up:"
            rgit log --format='%h %ad %s' --date=short "$up..HEAD" | head -n "$max" | details
        fi
    else
        BASE=$(rgit rev-parse HEAD)
        info "$(rgit symbolic-ref --short -q HEAD || echo 'the detached HEAD') has no upstream branch; showing the changes since the last commit"
    fi

    # path<TAB>what<TAB>line counts: git status for the uncommitted and
    # untracked files, git diff for the local commits and the line counts
    files=$({
        rgit status --porcelain --no-renames --untracked-files=all | sed "s/^/S$TAB/"
        rgit diff --name-status --no-renames "$BASE" HEAD | sed "s/^/C$TAB/"
        rgit diff --numstat --no-renames "$BASE" | sed "s/^/N$TAB/"
    } | awk -F'\t' '
        function add(p) { if (!(p in seen)) { seen[p] = 1; order[++n] = p } }
        $1 == "S" { p = substr($2, 4); add(p); st[p] = substr($2, 1, 2); next }
        $1 == "C" { add($3); cm[$3] = $2; next }
        $1 == "N" { lines[$4] = $2 == "-" ? "binary" : "+" $2 " -" $3 }
        END {
            for (i = 1; i <= n; i++) {
                p = order[i]
                if (st[p] == "??") {
                    what = "new, not committed"
                } else {
                    c = st[p] != "" ? st[p] : cm[p]
                    what = c ~ /D/ ? "deleted" : c ~ /A/ ? "added" : "modified"
                    what = what ", " (st[p] == "" ? "committed locally" : cm[p] == "" ? "not committed" : "committed locally and changed since")
                }
                print p "\t" what "\t" lines[p]
            }
        }')
    # copies update.sh makes before it pulls
    baks=$(printf '%s\n' "$files" | awk -F'\t' '$2 ~ /^new/ && $1 ~ /\.bak\.[0-9]+$/ { print $1 }')
    files=$(printf '%s\n' "$files" | awk -F'\t' 'NF && !($2 ~ /^new/ && $1 ~ /\.bak\.[0-9]+$/)')
    n=$(printf '%s\n' "$files" | grep -c .)

    if [ "$n" -eq 0 ]; then
        pass "no local changes: the files are as in ${up:-the last commit} ($(rgit rev-parse --short "$BASE"))"
    else
        running=$(printf '%s\n' "$CTR" | awk -F'|' '$3 == "running" { print $2 }')
        # shellcheck disable=SC2086
        mounts=$([ -z "$running" ] || docker inspect -f '{{$s := index .Config.Labels "com.docker.compose.service"}}{{range .Mounts}}{{if eq .Type "bind"}}{{$s}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}{{end}}' $running 2>/dev/null |
            while IFS='|' read -r svc src dest; do
                [ -n "$src" ] && src=$(repo_rel "$src") && printf '%s|%s|%s\n' "$svc" "$src" "$dest"
            done)
        info "$n file(s) differ from ${up:-the last commit} ($(rgit rev-parse --short "$BASE")):"
        printf '%s\n' "$files" | head -n "$max" | while IFS="$TAB" read -r path what lines; do
            if [ -z "$lines" ] && [ "${what%%,*}" = new ] && [ -f "$REPO/$path" ]; then
                lines="$(wc -l <"$REPO/$path" | tr -d ' ') lines"
            fi
            role=$(file_role "$path" "$STACK_REL" "$mounts")
            detail "$path: $what${lines:+ ($lines)}${role:+; $role}"
            if [ $VERBOSE -eq 1 ] && [ "${what%%,*}" = modified ]; then
                rgit diff --no-ext-diff --no-textconv --no-color "$BASE" -- "$path" | tail -n +5 | head -n 40 | redact |
                    sed 's/^/    /' | details
            fi
        done
        [ "$n" -le "$max" ] || detail "... and $((n - max)) more; see 'git -C $REPO status'"
        ntracked=$(printf '%s\n' "$files" | awk -F'\t' '$2 !~ /^new/ && $2 ~ /(not committed|changed since)$/' | grep -c .)
        if [ "$ntracked" -gt 0 ] && [ -n "$up" ]; then
            warn "$ntracked file(s) of the repo have uncommitted changes, so 'git pull' (update.sh) stops when $up changes them too; commit them, or keep local settings in docker-compose.override.yml (see docker-compose.override.yml.sample)"
        fi
    fi
    if [ -n "$baks" ]; then
        info "$(printf '%s\n' "$baks" | head -n 1)$([ "$(printf '%s\n' "$baks" | grep -c .)" -le 1 ] || echo " and $(($(printf '%s\n' "$baks" | grep -c .) - 1)) more"): copies update.sh made before it pulled, safe to delete"
    fi

    [ -n "$CUR_CFG" ] || return 0
    # only the compose files of the stack change its config
    printf '%s\n' "$files" | awk -F'\t' 'NR == FNR { if ($0 != "") stack[$0] = 1; next } $1 in stack { hit = 1 } END { exit !hit }' \
        <(printf '%s\n' "$STACK_REL") - || return 0
    compose_impact
}

# Do the containers match the compose files? 'docker compose up -d' recreates
# the containers whose config hash differs from the hash of the files.
compose_drift() {
    local hashes labels svc name hash want stale_local= stale_other= orphans= missing= n=0
    if ! hashes=$(compose_run current config --hash '*' 2>/dev/null); then
        info "this docker compose cannot print config hashes; skipped the comparison of the containers with the compose files"
        return
    fi
    labels=$(printf '%s\n' "$CTR" | cut -d'|' -f2 |
        xargs docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}|{{.Name}}|{{index .Config.Labels "com.docker.compose.config-hash"}}' 2>/dev/null |
        sed 's#|/#|#')
    while IFS='|' read -r svc name hash; do
        [ -n "$name" ] || continue
        n=$((n + 1))
        want=$(printf '%s\n' "$hashes" | awk -v s="$svc" '$1 == s { print $2; exit }')
        if [ -z "$want" ]; then
            # reported with the local changes that removed it
            case "$REMOVED_SVCS" in
                *" $svc "*) ;;
                *) orphans="$orphans, $name ($svc)" ;;
            esac
        elif [ "$want" != "$hash" ]; then
            case "$CHANGED_SVCS" in
                *" $svc "*) stale_local="$stale_local, $name" ;;
                *) stale_other="$stale_other, $name" ;;
            esac
        fi
    done <<EOF
$labels
EOF
    while read -r svc _; do
        [ -n "$svc" ] && [ -z "$(svc_containers "$svc")" ] || continue
        case " $REQUIRED_SERVICES $OPTIONAL_SERVICES " in
            # reported with the containers
            *" $svc "*) ;;
            *) missing="$missing, $svc" ;;
        esac
    done <<EOF
$hashes
EOF
    [ -z "$stale_local" ] || warn "the local changes are not applied to ${stale_local#, } yet; 'docker compose up -d' recreates them with the changes"
    [ -z "$stale_other" ] || warn "${stale_other#, } differ from the compose files ('git pull' or a Docker Compose upgrade since they were created?); 'docker compose up -d' recreates them"
    [ -z "$orphans" ] || warn "not in the compose files any more: ${orphans#, }; 'docker compose up -d --remove-orphans' removes them"
    [ -z "$missing" ] || warn "in the compose files but without a container: ${missing#, }; 'docker compose up -d' creates them"
    if [ -z "$stale_local$stale_other$orphans$missing" ]; then
        pass "all $n container(s) match the compose files"
    fi
}

check_compose() {
    section "Compose files and local changes${REPO:+ ($REPO)}"
    CUR_CFG= CHANGED_SVCS=" " REMOVED_SVCS=" "
    if [ -z "$COMPOSE_WD" ] || [ -z "$COMPOSE_FILES" ]; then
        info "the containers have no docker compose labels; skipped"
        return
    fi
    if ! docker compose version >/dev/null 2>&1; then
        info "docker compose (v2) is not installed; skipped reading the compose files"
    elif ! CUR_CFG=$(compose_run current config 2>"$WORK/compose.err"); then
        CUR_CFG=
        fail "cannot read the compose files of the stack, so 'docker compose up' fails too: $(grep . "$WORK/compose.err" | tail -n 1)"
    fi
    if [ -z "$REPO" ]; then
        info "$REPO_ERR; skipped the local changes"
    elif [ "$STACK_IN_REPO" = 1 ]; then
        repo_changes
    else
        info "the stack runs from $COMPOSE_WD, not from the repo $REPO; skipped its local changes"
    fi
    [ -z "$CUR_CFG" ] || compose_drift
}

# the three containers using the most of a resource, from "name|amount|display" lines on stdin
top3() {
    sort -t'|' -k2,2gr | awk -F'|' -v p="$PROJECT" '
        $2 > 0 && n++ < 3 {
            name = $1
            sub("^" p "[-_]", "", name)
            sub(/[-_]1$/, "", name)
            printf "%s%s %s", (n > 1 ? ", " : ""), name, $3
        }
        END { print "" }'
}

check_resources() {
    local running stats limits name cpu usage memperc pids mem nano quota period pidslim svc label cpus lim cg oom
    local periods throttled limited= nunlimited=0 n=0 before
    section "Container resources"
    running=$(printf '%s\n' "$CTR" | awk -F'|' '$3 == "running" { print $2 }')
    if [ -z "$running" ]; then
        info "no container is running"
        return
    fi
    # shellcheck disable=SC2086
    if ! stats=$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.PIDs}}' $running 2>&1); then
        warn "docker stats failed: $(printf '%s\n' "$stats" | tail -n 1)"
        return
    fi
    # shellcheck disable=SC2086
    limits=$(docker inspect -f '{{.Name}}|{{.HostConfig.Memory}}|{{.HostConfig.NanoCpus}}|{{.HostConfig.CpuQuota}}|{{.HostConfig.CpuPeriod}}|{{.HostConfig.PidsLimit}}' $running |
        sed 's#^/##')

    info "most memory: $(printf '%s\n' "$stats" | awk -F'|' '
        function bytes(s,   n) {
            n = s + 0
            if (s ~ /[kK]i?B/) n *= 1024; else if (s ~ /Mi?B/) n *= 1048576
            else if (s ~ /Gi?B/) n *= 1073741824; else if (s ~ /Ti?B/) n *= 1099511627776
            return n
        }
        { split($3, m, " / "); print $1 "|" bytes(m[1]) "|" m[1] }' | top3)"
    info "most CPU (100% is one CPU): $(printf '%s\n' "$stats" | awk -F'|' '{ print $1 "|" $2 + 0 "|" $2 }' | top3)"

    before=$((N_WARN + N_FAIL))
    while IFS='|' read -r name cpu usage memperc pids; do
        [ -n "$name" ] || continue
        n=$((n + 1))
        IFS='|' read -r _ mem nano quota period pidslim <<EOF
$(printf '%s\n' "$limits" | awk -F'|' -v n="$name" '$1 == n { print; exit }')
EOF
        svc=$(ctr_field "$name" 1)
        label=$(pad "${svc:-$name}")
        [ "$name" = "$svc" ] || label="$label $name:"
        cpus=$(awk -v n="${nano:-0}" -v q="${quota:-0}" -v p="${period:-0}" \
            'BEGIN { if (n > 0) c = n / 1e9; else if (q > 0) c = q / (p > 0 ? p : 100000); if (c > 0) printf "%g\n", c }')
        case "$pidslim" in '' | *[!0-9]*) pidslim=0 ;; esac

        lim=
        [ "${mem:-0}" -le 0 ] || lim="memory $(human_kib $((mem / 1024)))"
        [ -z "$cpus" ] || lim="${lim:+$lim, }$cpus CPU"
        [ "$pidslim" -le 0 ] || lim="${lim:+$lim, }$pidslim processes"
        if [ -n "$lim" ]; then
            limited="${limited:+$limited; }${svc:-$name} $lim"
        else
            nunlimited=$((nunlimited + 1))
        fi

        if [ "${mem:-0}" -gt 0 ] && percent_ge "${memperc%\%}" "$MEM_WARN"; then
            warn "$label uses $usage memory (${memperc}), close to its limit; processes in it are OOM-killed at the limit"
        fi
        if [ -n "$cpus" ] && percent_ge "${cpu%\%}" "$(awk -v c="$cpus" -v w="$CPU_WARN" 'BEGIN { print c * w }')"; then
            warn "$label uses $cpu CPU, at its limit of $cpus CPU(s), so it runs slowly"
        fi
        if [ "$pidslim" -gt 0 ] && [ "${pids:-0}" -ge $((pidslim * 9 / 10)) ] 2>/dev/null; then
            warn "$label runs $pids processes, close to its limit of $pidslim"
        fi

        # the container's own cgroup: memory.events/memory.oom_control count
        # OOM kills of any process in it, cpu.stat the CPU throttling
        cg=$(docker exec "$name" cat /sys/fs/cgroup/memory.events /sys/fs/cgroup/cpu.stat \
            /sys/fs/cgroup/memory/memory.oom_control /sys/fs/cgroup/cpu/cpu.stat </dev/null 2>/dev/null)
        oom=$(printf '%s\n' "$cg" | awk '$1 == "oom_kill" { print $2; exit }')
        if [ "${oom:-0}" -gt 0 ] 2>/dev/null; then
            if [ "${mem:-0}" -gt 0 ]; then
                fail "$label the OOM killer killed $oom process(es) in this container since it started; raise its memory limit"
            else
                fail "$label the OOM killer killed $oom process(es) in this container since it started; give the host more memory"
            fi
        fi
        if [ -n "$cpus" ]; then
            read -r periods throttled <<EOF
$(printf '%s\n' "$cg" | awk '$1 == "nr_periods" { p = $2 } $1 == "nr_throttled" { t = $2 } END { print p + 0, t + 0 }')
EOF
            if [ "$periods" -gt 0 ] && [ $((throttled * 100 / periods)) -ge 20 ]; then
                warn "$label was CPU-throttled in $((throttled * 100 / periods))% of its time slices since it started; its limit of $cpus CPU(s) is too low"
            fi
        fi
    done <<EOF
$stats
EOF

    if [ -n "$limited" ]; then
        [ $nunlimited -eq 0 ] || limited="$limited; no limits on the other $nunlimited container(s)"
        info "limits: $limited"
    else
        info "no container has a memory, CPU or process limit"
    fi
    if [ $((N_WARN + N_FAIL)) -eq "$before" ]; then
        pass "$n running container(s) within their limits, no OOM kills"
    fi
}

check_migrations() {
    local wanted out heads nheads expected current rc mismatch=0 mig status exitcode img svc c steps nsteps differs=0
    section "Database migration (alembic)"
    if [ -z "$API_ANY" ]; then
        fail "no api container, cannot tell which revision the database should be at"
        return
    fi

    wanted=$(env_get "$ENV_API" alembic_version)
    out=$(alembic_cmd heads)
    heads=$(printf '%s\n' "$out" | awk '/\(head\)/ { print $1 }')
    nheads=$(printf '%s\n' "$heads" | grep -c .)
    if [ "$nheads" -gt 1 ]; then
        fail "the api image has $nheads alembic heads ($(echo $heads)); its migrations are broken"
        return
    fi
    if [ "$nheads" -eq 0 ]; then
        fail "could not read the alembic head of the api image:"
        printf '%s\n' "$out" | tail -n 3 | details
    fi
    case "$wanted" in
        '' | head)
            expected=$heads
            if [ -z "$wanted" ]; then
                warn "alembic_version is not set on the api service, so db_migration skips the migrations; set it to 'head'"
            fi
            ;;
        *)
            expected=$wanted
            info "alembic_version is pinned to $wanted (head of the api image: ${heads:-unknown})"
            if ! alembic_cmd show "$wanted" >/dev/null 2>&1; then
                fail "alembic_version $wanted is not a revision this api image knows"
            fi
            ;;
    esac

    if [ -n "$expected" ]; then
        out=$(db_revision)
        rc=$?
        current=$(printf '%s\n' "$out" | grep -E '^[0-9a-f]+$')
        if [ $rc -ne 0 ] || [ -z "$current" ]; then
            case "$out" in
                *'relation "alembic_version" does not exist'*)
                    fail "the database has no alembic_version table; the migrations have never run"
                    ;;
                *)
                    fail "could not read the revision of the database:"
                    printf '%s\n' "$out" | tail -n 3 | details
                    ;;
            esac
            mismatch=1
        elif [ "$(printf '%s\n' "$current" | grep -c .)" -gt 1 ]; then
            fail "the database has several alembic revisions: $(echo $current)"
            mismatch=1
        elif [ "$current" = "$expected" ]; then
            pass "database is at revision $current, as the api image expects"
        elif ! alembic_cmd show "$current" >/dev/null 2>&1; then
            fail "database is at revision $current, which this api image does not know (expected $expected)"
            detail "A newer Netpicker version migrated the database. Run that version again, or let"
            detail "db_migration downgrade it; it keeps the migrations of earlier images in the policy-data volume."
            mismatch=1
        elif alembic_cmd history -r "$current:$expected" >/dev/null 2>&1; then
            fail "database is behind: at revision $current, the api image expects $expected"
            detail "db_migration should have upgraded it; see its status below."
            mismatch=1
        else
            fail "database is ahead of the api image: at revision $current, the api image expects $expected"
            detail "db_migration should have downgraded it; see its status below."
            mismatch=1
        fi
        if [ $mismatch -eq 1 ] && docker logs --tail 20 "$API_ANY" 2>&1 | grep -q 'Waiting for migration'; then
            detail "The api is waiting for this migration and does not start until it is applied."
        fi
    fi

    mig=$(svc_containers db_migration | head -n 1)
    if [ -z "$mig" ]; then
        warn "no db_migration container found; it applies the migrations on 'docker compose up'"
    else
        IFS='|' read -r _ _ status _ _ _ exitcode img _ <<EOF
$(ctr_line "$mig")
EOF
        case "$status/$exitcode" in
            exited/0)
                # the log holds every run; look at the last one, which starts with
                # "Migration target" (printed by /db-migrate in the api image)
                out=$(docker logs "$mig" 2>&1 | awk '/^Migration target / { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }')
                steps=$(printf '%s\n' "$out" | grep -E 'Running (upgrade|downgrade)' | sed 's/^.*\] //')
                nsteps=$(printf '%s\n' "$steps" | grep -c .)
                case "$(printf '%s\n' "$out" | grep -E '^(Database up-to-date|Upgrading|Downgrading|SKIPPING)' | tail -n 1)" in
                    SKIPPING*) warn "db_migration skipped the migrations because alembic_version is not set" ;;
                    Upgrading*) pass "db_migration completed: applied $nsteps upgrade(s), the last: $(printf '%s\n' "$steps" | tail -n 1)" ;;
                    # /db-migrate also says "Downgrading" when it had nothing to do
                    Downgrading*) [ "$nsteps" -eq 0 ] && pass "db_migration completed: nothing to migrate" ||
                        pass "db_migration completed: applied $nsteps downgrade(s), the last: $(printf '%s\n' "$steps" | tail -n 1)" ;;
                    *) pass "db_migration completed: database up-to-date" ;;
                esac
                ;;
            exited/*)
                fail "db_migration failed with exit code $exitcode; last log lines:"
                docker logs --tail 15 "$mig" 2>&1 | cut -c1-200 | details
                ;;
            running/*) warn "db_migration is still running" ;;
            created/*) warn "db_migration never started; it waits for the db service to be healthy" ;;
            *) warn "db_migration is $status" ;;
        esac
        if [ -n "$API_IMAGE" ] && [ "$img" != "$API_IMAGE" ]; then
            warn "db_migration last ran with a different image than the api; run 'docker compose up -d' to migrate with the current image"
        fi
    fi

    for svc in celery committer; do
        for c in $(svc_containers "$svc"); do
            img=$(ctr_field "$c" 8)
            if [ "$img" != "$API_IMAGE" ]; then
                fail "$svc ($c) runs a different image than the api; recreate it with 'docker compose up -d'"
                differs=1
            fi
        done
    done
    if [ $differs -eq 0 ] && [ -n "$API_IMAGE" ]; then
        img=${API_IMAGE#sha256:}
        pass "api, celery and committer run the same image (${img%"${img#????????????}"})"
    fi
}

# agent_matrix SERVICE ENV: source|mode|host:port|description of an agent
# service with environment ENV
agent_matrix() {
    local v
    v=$(env_get "$2" SHENV_API_URL)
    echo "$1|tcp|$(url_hostport "${v:-http://api:8000}")|api"
    v=$(env_get "$2" REDIS_URL)
    echo "$1|tcp|$(url_hostport "${v:-redis://redis}" 6379)|redis"
    v=$(env_get "$2" NETPICKER_GIT_URL)
    echo "$1|tcp|$(url_hostport "${v:-http://frontend/git}")|frontend git"
    echo "$1|tcp|$(agent_conf "$2" BACKUP_SVC_ADDR):$(agent_conf "$2" BACKUP_SVC_PORT)|kibbitzer"
}

# source|mode|host:port|description
connectivity_matrix() {
    local svc
    for svc in api celery committer; do
        echo "$svc|tcp|$DB_HP|database"
        echo "$svc|tcp|$REDIS_HP|redis"
        echo "$svc|git|$GIT_HP|gitd"
        echo "$svc|ping|$GITCTRL_HP|gitdctrl"
        echo "$svc|tcp|$S3_HP|minio"
    done
    echo "api|tcp|$CLI_HP|agent CLI proxy"
    echo "celery|tcp|$CLI_HP|agent CLI proxy"
    echo "celery|tcp|$API_HP|api"
    agent_matrix agent "$ENV_AGENT"
    for svc in $(extra_agents); do
        agent_matrix "$svc" "$(ctr_env "$(svc_any "$svc")")"
    done
    echo "kibbitzer|tcp|$KIB_API_HP|api"
    echo "kibbitzer|tcp|$KIB_REDIS_HP|redis"
    echo "kibbitzer|tcp|$KIB_TAC_HP|agent vault"
    echo "frontend|tcp|$API_HP|api"
    if [ -n "$(svc_containers swagger)" ]; then
        echo "frontend|tcp|swagger:8080|swagger"
    fi
}

# host_http SERVICE CONTAINER_PORT PATH SCHEME: request a published port from the host
host_http() {
    local c hp url out rc
    c=$(svc_running "$1")
    [ -n "$c" ] || return 0
    hp=$(docker port "$c" "$2" 2>/dev/null | head -n 1)
    [ -n "$hp" ] || return 0
    case "$hp" in
        0.0.0.0:*) hp="127.0.0.1:${hp#*:}" ;;
        '[::]:'*) hp="[::1]:${hp##*:}" ;;
    esac
    url="$4://$hp$3"
    if command -v curl >/dev/null 2>&1; then
        out=$(curl -fsSk -m 5 -o /dev/null "$url" 2>&1)
        rc=$?
    elif command -v wget >/dev/null 2>&1; then
        out=$(wget -q -T 5 --no-check-certificate -O /dev/null "$url" 2>&1)
        rc=$?
    else
        info "$(pad host) -> $1 $url: no curl or wget on the host, skipped"
        return 0
    fi
    if [ $rc -eq 0 ]; then
        pass "$(pad host) -> $1: GET $url OK"
    else
        fail "$(pad host) -> $1: GET $url failed: $out"
    fi
}

check_connectivity() {
    local src c ok failed s mode hp label out rc matrix
    section "Connectivity between containers"
    matrix=$(connectivity_matrix)
    for src in api celery committer agent $(extra_agents) kibbitzer frontend; do
        c=$(svc_running "$src")
        if [ -z "$c" ]; then
            info "$(pad "$src") not running, skipped"
            continue
        fi
        ok=
        failed=0
        while IFS='|' read -r s mode hp label; do
            [ "$s" = "$src" ] || continue
            out=$(probe "$c" "$mode" "$hp")
            rc=$?
            case $rc in
                0) ok="$ok $hp" ;;
                3) warn "$(pad "$src") -> $label $hp: cannot test, $out" ;;
                *) fail "$(pad "$src") -> $label $hp: $out"; failed=1 ;;
            esac
        done <<EOF
$matrix
EOF
        if [ $failed -eq 0 ]; then
            [ -z "$ok" ] || pass "$(pad "$src") ->$ok"
        elif [ -n "$ok" ]; then
            info "$(pad "$src") -> reachable:$ok"
        fi
    done

    c=$(svc_running frontend)
    if [ -n "$c" ]; then
        if out=$(docker exec "$c" wget -q -T 5 -O /dev/null http://127.0.0.1/api/v1/status </dev/null 2>&1); then
            pass "$(pad frontend) -> api through nginx: GET /api/v1/status OK"
        else
            fail "$(pad frontend) -> api through nginx: GET /api/v1/status failed: $out"
        fi
    fi
    host_http api 8000/tcp /api/v1/status http
    host_http frontend 80/tcp /health http
    host_http frontend 443/tcp /health https
}

# Load the services of the stack into STACK (see AWK_STACK): from the compose
# config, or from the containers when the compose files could not be read.
load_stack() {
    local svc c
    if [ -n "$CUR_CFG" ]; then
        STACK=$(printf '%s\n' "$CUR_CFG" | awk "$AWK_FLAT" | awk -v re="$AGENT_IMAGE_RE" "$AWK_STACK")
        return
    fi
    STACK=$(for svc in $(printf '%s\n' "$CTR" | cut -d'|' -f1 | sort -u); do
        c=$(svc_any "$svc")
        printf '%s\timage\t%s\n%s\tcontainer_name\t%s\n' "$svc" "$(ctr_field "$c" 9)" "$svc" "$c"
        ctr_env "$c" | awk -v s="$svc" '{ i = index($0, "="); if (i) print s "\tenvironment." substr($0, 1, i - 1) "\t" substr($0, i + 1) }'
    done | awk -v re="$AGENT_IMAGE_RE" "$AWK_STACK")
}

# the environment of a service of the stack, KEY=value lines
stack_env() {
    printf '%s\n' "$STACK" | awk -F'\t' -v s="$1" '$1 == "E" && $2 == s { print substr($0, length($2) + 4) }'
}

# the service of the stack that the host name NAME is: its service name,
# container_name or container name
stack_service() {
    local s
    s=$(printf '%s\n' "$STACK" | awk -F'\t' -v n="$1" '$1 == "S" && ($2 == n || ($4 != "" && $4 == n)) { print $2; exit }')
    [ -n "$s" ] || s=$(printf '%s\n' "$CTR" | awk -F'|' -v n="$1" '$2 == n { print $1; exit }')
    printf '%s\n' "$s"
}

beat_label() {
    case "$1" in
        '' | -) echo never ;;
        *) echo "$(human_duration "$1") ago" ;;
    esac
}

# Ask redis which agents are connected to the api: sets AGENTS_LIVE to the C
# lines of PY_AGENTS, or AGENTS_LIVE_ERR to why it cannot tell.
load_live_agents() {
    local c out rc
    AGENTS_LIVE= AGENTS_LIVE_ERR=
    if ! c=$(first_running api celery committer); then
        AGENTS_LIVE_ERR="no api, celery or committer container runs"
        return 1
    fi
    out=$(printf '%s' "$PY_AGENTS" |
        NP_REDIS_PASSWORD=$REDIS_PW docker exec -i -e NP_REDIS_PASSWORD "$c" python3 - "$REDIS_HP" "$API_REDIS_DB" 2>&1)
    rc=$?
    AGENTS_LIVE_ERR=$(printf '%s\n' "$out" | sed -n "s/^E$TAB//p" | head -n 1)
    if [ $rc -ne 0 ] || [ -n "$AGENTS_LIVE_ERR" ]; then
        [ -n "$AGENTS_LIVE_ERR" ] || AGENTS_LIVE_ERR=$(printf '%s\n' "$out" | tail -n 1)
        return 1
    fi
    AGENTS_LIVE=$(printf '%s\n' "$out" | grep "^C$TAB")
    return 0
}

# The agents in the database: are they connected, and do they run in this
# stack? An agent in this stack shares its redis and kibbitzer; an agent in
# another stack needs its own there, which cannot be checked from here.
check_agents() {
    local db_ok=0 live_ok=0 n ntenants label up nsvcs from lost c svc env id rt kaddr kport ksvc krt v
    local sid tenant name beat devices nconn hosts svcs k multi u api_port celery_port missing remote=
    local targets hp out rc names
    section "Agents"
    load_stack
    AGENT_SVCS=$(printf '%s\n' "$STACK" | awk -F'\t' '$1 == "S" && $3 == "agent" { print $2 }')
    # agent id<TAB>service, for the agent services of the stack
    AGENT_MAP=$(for svc in $AGENT_SVCS; do
        printf '%s\t%s\n' "$(agent_conf "$(stack_env "$svc")" AGENT_ID)" "$svc"
    done)

    if AGENTS_DB=$(db_query "$SQL_AGENTS"); then
        db_ok=1
    else
        warn "could not read the agents from the database:"
        printf '%s\n' "$AGENTS_DB" | tail -n 3 | details
        AGENTS_DB=
    fi
    if load_live_agents; then
        live_ok=1
    else
        warn "could not ask redis which agents are connected to the api, going by their heartbeats instead: $AGENTS_LIVE_ERR"
    fi

    # agent id, tenant, name, heartbeat age, devices, connections, hosts and
    # services in this stack; "-" for none, as read skips empty fields
    printf '%s\n' "$AGENTS_LIVE" >"$WORK/agents.live"
    printf '%s\n' "$AGENT_MAP" >"$WORK/agents.map"
    printf '%s\n' "$AGENTS_DB" >"$WORK/agents.db"
    AGENTS=$(awk -F'\t' -v OFS='\t' '
        FILENAME == ARGV[1] {
            if ($1 == "C") {
                nc[$2]++
                if ($4 == "") $4 = "?"
                if (!(($2, $4) in hs)) { hs[$2, $4] = 1; h[$2] = h[$2] (h[$2] == "" ? "" : ", ") $4 }
            }
            next
        }
        FILENAME == ARGV[2] { if ($1 != "") s[$1] = s[$1] (s[$1] == "" ? "" : ", ") $2; next }
        $1 == "A" { print $2, $3, $4, ($5 == "" ? "-" : $5), $6, nc[$2] + 0, (h[$2] == "" ? "-" : h[$2]), (s[$2] == "" ? "-" : s[$2]) }
    ' "$WORK/agents.live" "$WORK/agents.map" "$WORK/agents.db" | sort -t "$TAB" -k2,2 -k3,3)
    n=$(printf '%s\n' "$AGENTS" | grep -c .)
    if [ $db_ok -eq 1 ] && [ "$n" -eq 0 ]; then
        fail "the agent table is empty, so no agent can connect; the api creates the default agent G7 (AGENT_ID $DEFAULT_AGENT_ID) when it starts without agents"
    elif [ "$n" -gt 0 ]; then
        info "$n agent(s) in the database$([ $live_ok -eq 0 ] || echo ", $(printf '%s\n' "$AGENTS" | awk -F'\t' '$6 > 0' | grep -c .) connected to the api"):"
        {
            printf 'agent id\tname\ttenant\tdevices\tlast heartbeat\tconnected\tservice in this stack\n'
            while IFS="$TAB" read -r sid tenant name beat devices nconn hosts svcs; do
                if [ $live_ok -eq 0 ]; then
                    up=?
                elif [ "$nconn" -gt 1 ]; then
                    up="$nconn times, as $hosts"
                elif [ "$nconn" -gt 0 ]; then
                    up="yes, as $hosts"
                else
                    up=no
                fi
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sid" "$name" "$tenant" "$devices" "$(beat_label "$beat")" "$up" "$svcs"
            done <<EOF
$AGENTS
EOF
        } | awk "$AWK_COLUMNS" | details
    elif [ -n "$AGENTS_LIVE" ]; then
        info "connected to the api: $(printf '%s\n' "$AGENTS_LIVE" | awk -F'\t' '{ printf "%s%s (tenant %s) as host %s", (NR > 1 ? ", " : ""), $2, $3, $4 } END { print "" }')"
    fi

    ntenants=$(printf '%s\n' "$AGENTS" | cut -f2 | sort -u | grep -c .)
    while IFS="$TAB" read -r sid tenant name beat devices nconn hosts svcs; do
        [ -n "$sid" ] || continue
        label="agent $name ($sid$([ "$ntenants" -le 1 ] || echo ", tenant $tenant"))"
        if [ $live_ok -eq 1 ]; then
            up=$nconn
        elif [ "$beat" != - ] && [ "$beat" -le "$AGENT_BEAT_AGE" ]; then
            up=1
        else
            up=0
        fi
        lost=
        [ "$devices" -eq 0 ] || lost="; its $devices device(s) get no backups until it connects"
        if [ "$up" -gt 0 ]; then
            from=
            [ $live_ok -eq 0 ] || from=" as host $hosts"
            [ "$nconn" -le 1 ] || from=" $nconn times$from"
            if [ "$svcs" != - ]; then
                pass "$label: connected$from, runs in this stack as service $svcs"
            else
                pass "$label: connected$from, runs outside this compose stack"
                remote="$remote, $name"
            fi
            nsvcs=0
            [ "$svcs" = - ] || nsvcs=$(printf '%s\n' "$svcs" | tr ',' '\n' | grep -c .)
            # more agents in this stack with the same id are reported below
            if [ "$nconn" -gt 1 ] && [ "$nconn" -gt "$nsvcs" ]; then
                fail "$label is connected $nconn times: several agents use AGENT_ID $sid, but every agent needs its own"
            fi
        elif [ "$svcs" != - ]; then
            # shellcheck disable=SC2046
            c=$(first_running $(printf '%s' "$svcs" | tr ',' ' '))
            if [ -n "$c" ]; then
                fail "$label: not connected (last heartbeat $(beat_label "$beat")) although service $svcs runs in this stack; see 'docker logs $c'$lost"
            else
                fail "$label: not connected, its service $svcs in this stack does not run$lost"
            fi
        elif [ "$devices" -gt 0 ]; then
            fail "$label: not connected (last heartbeat $(beat_label "$beat")) and not in this compose stack$lost"
            remote="$remote, $name"
        else
            warn "$label: not connected (last heartbeat $(beat_label "$beat")) and not in this compose stack; no devices use it"
            remote="$remote, $name"
        fi
    done <<EOF
$AGENTS
EOF

    # the agent services of this stack: their AGENT_ID, and the redis and
    # kibbitzer they share
    if [ $db_ok -eq 1 ]; then
        while IFS="$TAB" read -r id svc; do
            [ -n "$id" ] || continue
            printf '%s\n' "$AGENTS" | awk -F'\t' -v i="$id" '$1 == i { f = 1 } END { exit !f }' && continue
            fail "$(pad "$svc") AGENT_ID $id$([ "$id" != "$DEFAULT_AGENT_ID" ] || echo ", the default,") is not an agent in the database, so the api refuses its connection; set AGENT_ID to the id of an agent in Netpicker"
        done <<EOF
$AGENT_MAP
EOF
    fi
    while IFS="$TAB" read -r id svcs; do
        [ -n "$id" ] || continue
        fail "services $svcs all use AGENT_ID $id$([ "$id" != "$DEFAULT_AGENT_ID" ] || echo ", the default"), but every agent needs its own"
    done <<EOF
$(printf '%s\n' "$AGENT_MAP" | awk -F'\t' 'NF { n[$1]++; s[$1] = s[$1] (s[$1] == "" ? "" : ", ") $2 } END { for (i in n) if (n[i] > 1) print i "\t" s[i] }')
EOF

    : >"$WORK/agents.shared"
    for svc in $AGENT_SVCS; do
        env=$(stack_env "$svc")
        rt=$(redis_target "$(agent_conf "$env" REDIS_URL)")
        kaddr=$(agent_conf "$env" BACKUP_SVC_ADDR)
        kport=$(agent_conf "$env" BACKUP_SVC_PORT)
        ksvc=$(stack_service "$kaddr")
        if [ -z "$(stack_service "${rt%%:*}")" ]; then
            warn "$(pad "$svc") uses redis $rt (REDIS_URL), which is not a service of this stack; an agent in this stack shares the redis of the stack with kibbitzer"
        fi
        if [ -z "$ksvc" ]; then
            warn "$(pad "$svc") sends its backups to $kaddr:$kport (BACKUP_SVC_ADDR), which is not a service of this stack; an agent in this stack shares the kibbitzer of the stack"
            continue
        fi
        # kibbitzer pushes the backup results to the list aob-replies in its
        # redis, the agent pops them from its own and sends them to the api
        v=$(env_get "$(stack_env "$ksvc")" SHENV_REDIS_URL)
        krt=$(redis_target "${v:-redis://redis/4}")
        if [ "$krt" != "$rt" ]; then
            fail "$(pad "$svc") waits for its backup results in redis $rt (REDIS_URL), but $ksvc puts them in $krt (SHENV_REDIS_URL), so its backups never finish; point both to the same redis database"
            continue
        fi
        printf '%s\t%s\t%s\n' "$rt" "$kaddr:$kport" "$svc" >>"$WORK/agents.shared"
    done
    while IFS="$TAB" read -r rt k svcs; do
        [ -n "$rt" ] || continue
        case "$svcs" in
            *,*) pass "agent services $svcs share kibbitzer $k and redis $rt of this stack, the redis kibbitzer reports to" ;;
            *) pass "$(pad "$svcs") uses kibbitzer $k and redis $rt of this stack, the redis kibbitzer reports to" ;;
        esac
    done <<EOF
$(awk -F'\t' '{ k = $1 "\t" $2; if (!(k in s)) o[++n] = k; s[k] = s[k] (s[k] == "" ? "" : ", ") $3 } END { for (i = 1; i <= n; i++) print o[i] "\t" s[o[i]] }' "$WORK/agents.shared")
EOF

    # Tenants with several agents. Without CLI_PROXY_PORT, the rules connect
    # to port 9876 of the host of the first agent of the tenant that the api
    # finds, whatever the agent of the device; with it, to the CLI proxy in
    # the api, which passes each command to the agent of the device.
    api_port=$(env_get "$ENV_API" CLI_PROXY_PORT)
    celery_port=$(env_get "$(ctr_env "$(svc_any celery)")" CLI_PROXY_PORT)
    [ "$api_port" != 0 ] || api_port=
    [ "$celery_port" != 0 ] || celery_port=
    multi=$(printf '%s\n' "$AGENTS" | awk -F'\t' 'NF { n[$2]++ } END { for (t in n) if (n[t] > 1) print t "\t" n[t] }' | sort)
    if [ -n "$multi" ]; then
        missing=
        [ -n "$api_port" ] || missing=api
        [ -n "$celery_port" ] || missing="${missing:+$missing and }celery"
        if [ "$(printf '%s\n' "$multi" | grep -c .)" -eq 1 ]; then
            names="tenant $(printf '%s\n' "$multi" | cut -f1) has $(printf '%s\n' "$multi" | cut -f2) agents"
        else
            names="tenants $(printf '%s\n' "$multi" | cut -f1 | paste -sd, - | sed 's/,/, /g') have several agents"
        fi
        if [ -n "$missing" ]; then
            warn "$names, but CLI_PROXY_PORT is not set on $missing: policy rules that use device.cli() go to the CLI proxy of whichever agent of the tenant the api finds first, also for the devices of its other agents"
            detail "Set CLI_PROXY_PORT: 9876 in the environment of api and celery, e.g. in docker-compose.override.yml; then the"
            detail "rules connect to the CLI proxy in the api, which passes each command to the agent of the device."
        elif [ "$api_port" != "$celery_port" ]; then
            warn "CLI_PROXY_PORT differs between api ($api_port) and celery ($celery_port), so the rules cannot reach the CLI proxy in the api; set the same port on both"
        fi
    fi
    while IFS="$TAB" read -r tenant n; do
        [ -n "$tenant" ] || continue
        u=$(printf '%s\n' "$AGENTS_DB" | awk -F'\t' -v t="$tenant" '$1 == "U" && $2 == t { print $3; exit }')
        if [ "${u:-0}" -gt 0 ]; then
            warn "tenant $tenant has $n agents and $u device(s) without an agent; the api splits their backups over the connected agents, so they fail when they land on an agent that cannot reach the device; assign every device to its agent"
        fi
    done <<EOF
$multi
EOF

    # can celery, which runs the rules, reach the CLI proxies they use? The
    # connectivity check above tests the one of the agent service.
    c=$(svc_running celery)
    targets=
    if [ -n "$celery_port" ]; then
        targets="api:$celery_port"
    elif [ $live_ok -eq 1 ]; then
        targets=$(printf '%s\n' "$AGENTS_LIVE" | awk -F'\t' -v skip="$CLI_HP" '$4 != "" && $4 ":9876" != skip { print $4 ":9876" }' | sort -u)
    fi
    [ -n "$c" ] || targets=
    for hp in $targets; do
        out=$(probe "$c" tcp "$hp")
        rc=$?
        if [ "$hp" = "api:$celery_port" ]; then
            label="the CLI proxy in the api"
        else
            names=$(printf '%s\n' "$AGENTS" | awk -F'\t' -v h="${hp%:*}" '{ n = split($7, a, ", "); for (i = 1; i <= n; i++) if (a[i] == h) { printf "%s%s", (k++ ? ", " : ""), $3; break } } END { print "" }')
            [ -n "$names" ] || names=$(printf '%s\n' "$AGENTS_LIVE" | awk -F'\t' -v h="${hp%:*}" '$4 == h && !seen[$2]++ { printf "%s%s", (k++ ? ", " : ""), $2 } END { print "" }')
            label="the CLI proxy of agent $names"
        fi
        case $rc in
            0) pass "$(pad celery) -> $label $hp" ;;
            3) warn "$(pad celery) -> $label $hp: cannot test, $out" ;;
            *)
                if [ -n "$celery_port" ]; then
                    fail "$(pad celery) -> $label $hp: $out; policy rules that use device.cli() fail"
                else
                    fail "$(pad celery) -> $label $hp: $out; policy rules that use device.cli() fail when the api picks this agent; set CLI_PROXY_PORT: 9876 on api and celery to reach the agents through the api instead"
                fi
                ;;
        esac
    done

    if [ -n "$remote" ]; then
        info "agent(s) ${remote#, } run outside this compose stack, so this script cannot check their setup. An agent in another stack needs its own redis and kibbitzer in that stack; on its host, check that:"
        detail "- agent, kibbitzer and redis run together in that stack ('docker compose ps' there)"
        detail "- REDIS_URL of the agent and SHENV_REDIS_URL of kibbitzer are the same redis database; kibbitzer"
        detail "  ignores REDIS_URL, both default to redis://redis/4"
        detail "- BACKUP_SVC_ADDR of the agent is the kibbitzer of that stack (default: kibbitzer)"
        detail "- WS_ENDPOINT and SHENV_API_URL of the agent and SHENV_API_URL of kibbitzer reach this api"
        detail "- AGENT_ID of the agent is its id in Netpicker, and no other agent uses it"
    fi
}

redis_info() {
    printf '%s\n' "$REDIS_INFO" | sed -n "s/^$1://p" | head -n 1
}

# queue_snapshot DB...: Q and U lines of every database, prefixed with the database
queue_snapshot() {
    local db
    for db in "$@"; do
        rlua "$db" "$LUA_QUEUES" 2>&1 | sed "s/^/$db$TAB/"
    done
}

inspect_workers() {
    local db sep
    INSPECT_C=$(first_running celery committer api)
    [ -n "$INSPECT_C" ] || return 0
    for db in "$@"; do
        sep=$(printf '%s\n' "$SNAP1" | awk -F'\t' -v d="$db" '$1 == d && $2 == "Q" { print $4; exit }')
        printf '%s' "$PY_INSPECT" |
            NP_REDIS_PASSWORD=$REDIS_PW docker exec -i -e NP_REDIS_PASSWORD "$INSPECT_C" \
                python3 - "$REDIS_HP" "$db" "$sep" "$INSPECT_TIMEOUT" >"$WORK/inspect.$db" 2>&1 &
    done
    wait
}

# Did kibbitzer or committer have work while the queues were watched? The
# device event check uses it to tell lost tasks from a long wait.
QUEUES_WATCHED=0
WORKERS_BUSY=0
WORKERS_UNKNOWN=0

# mark_busy SERVICE: a worker of SERVICE ran tasks or drained a queue
mark_busy() {
    case "$1" in
        kibbitzer | committer) WORKERS_BUSY=1 ;;
    esac
}

report_workers() {
    local db f worker conc act res sch queues svc c host
    for db in $BROKER_DBS; do
        f="$WORK/inspect.$db"
        if [ -z "$INSPECT_C" ]; then
            WORKERS_UNKNOWN=1
            fail "db$db: no api, celery or committer container runs to inspect the workers with"
            continue
        fi
        if grep -q "^E$TAB" "$f"; then
            WORKERS_UNKNOWN=1
            warn "db$db: could not inspect the workers: $(grep "^E$TAB" "$f" | head -n 1 | cut -f2-)"
            continue
        fi
        if ! grep -q "^W$TAB" "$f"; then
            if [ -s "$f" ]; then
                WORKERS_UNKNOWN=1
                warn "db$db: could not inspect the workers: $(tail -n 1 "$f")"
            else
                fail "db$db: no celery worker answers on this broker"
            fi
            continue
        fi
        while IFS="$TAB" read -r _ worker conc act res sch queues; do
            svc=$(host_service "${worker#*@}")
            [ "${act:-0}" -eq 0 ] || mark_busy "$svc"
            if [ -n "$svc" ]; then svc="$svc ($worker)"; else svc="$worker (not in this stack)"; fi
            pass "db$db worker $svc: $act/$conc busy, $res reserved, $sch scheduled; queues: $(printf '%s' "$queues" | sed 's/,/, /g')"
        done <<EOF
$(grep "^W$TAB" "$f")
EOF
    done

    [ -n "$INSPECT_C" ] || return 0
    for svc in celery committer kibbitzer; do
        for c in $(svc_containers "$svc"); do
            [ "$(ctr_field "$c" 3)" = running ] || continue
            host=$(ctr_field "$c" 10)
            # not cat | grep -q: with pipefail, cat killed by SIGPIPE after the match fails it
            if ! grep -q "@$host$TAB" "$WORK"/inspect.* 2>/dev/null; then
                fail "$(pad "$svc") $c: its celery worker does not answer control commands; it may be hung or overloaded"
            fi
        done
    done
}

report_queues() {
    local db q n1 n2 ncons conc active empty f u1 count age task rkey held orphans w
    for db in $BROKER_DBS; do
        f="$WORK/inspect.$db"
        [ -f "$f" ] || : >"$f"
        empty=
        for q in $(printf '%s\n' "$SNAP2" | awk -F'\t' -v d="$db" '$1 == d && $2 == "Q" { print $3 }'); do
            n1=$(printf '%s\n' "$SNAP1" | awk -F'\t' -v d="$db" -v q="$q" '$1 == d && $2 == "Q" && $3 == q { print $5; exit }')
            n2=$(printf '%s\n' "$SNAP2" | awk -F'\t' -v d="$db" -v q="$q" '$1 == d && $2 == "Q" && $3 == q { print $5; exit }')
            n1=${n1:-0}
            read -r ncons conc active <<EOF
$(awk -F'\t' -v q="$q" '$1 == "W" { n = split($7, a, ","); for (i = 1; i <= n; i++) if (a[i] == q) { c++; s += $3; b += $4 } } END { print c + 0, s + 0, b + 0 }' "$f")
EOF
            if [ "$n2" -eq 0 ]; then
                empty="$empty $q"
            elif [ "$ncons" -eq 0 ]; then
                case "$q" in
                    localtasks.*)
                        warn "db$db queue $q: $n2 message(s) for a container that no longer exists (recreated?); nothing will run them"
                        ;;
                    *)
                        fail "db$db queue $q: $n2 message(s) waiting and no worker consumes this queue"
                        ;;
                esac
            elif [ "$n2" -lt "$n1" ]; then
                pass "db$db queue $q: draining, $n1 -> $n2 message(s) in ${ELAPSED}s by $ncons worker(s)"
                for w in $(awk -F'\t' -v q="$q" '$1 == "W" { n = split($7, a, ","); for (i = 1; i <= n; i++) if (a[i] == q) print $2 }' "$f"); do
                    mark_busy "$(host_service "${w#*@}")"
                done
            elif [ "$conc" -gt 0 ] && [ "$active" -ge "$conc" ]; then
                warn "db$db queue $q: backlog of $n2 message(s) ($n1 -> $n2 in ${ELAPSED}s); all $conc worker slot(s) are busy, so it is slow rather than stuck"
            else
                fail "db$db queue $q: $n2 message(s) not draining in ${ELAPSED}s although its $ncons worker(s) have free slots; the workers may be stuck"
            fi
        done
        [ -z "$empty" ] || pass "db$db queues empty:$empty"

        # in-flight messages: delivered to a worker, not acknowledged yet
        u1=$(printf '%s\n' "$SNAP1" | awk -F'\t' -v d="$db" '$1 == d && $2 == "U" { print $3; exit }')
        IFS="$TAB" read -r count age task rkey <<EOF
$(printf '%s\n' "$SNAP2" | awk -F'\t' -v d="$db" '$1 == d && $2 == "U" { print $3 "\t" $4 "\t" $5 "\t" $6; exit }')
EOF
        count=${count:-0}
        [ "$count" -gt 0 ] || continue
        info "db$db: $count task(s) in flight, the oldest ${task:-?} (queue ${rkey:-?}) for $(human_duration "$age")"
        if [ "$age" -gt "$VIS_TIMEOUT" ]; then
            fail "db$db: task ${task:-?} has been unacknowledged for $(human_duration "$age"), longer than the visibility timeout of $(human_duration "$VIS_TIMEOUT"); the workers may be stuck"
        elif [ "$age" -gt "$TASK_AGE" ]; then
            warn "db$db: task ${task:-?} has been running or waiting for $(human_duration "$age")"
        fi
        if grep -q "^W$TAB" "$f"; then
            held=$(awk -F'\t' '$1 == "W" { n += $4 + $5 + $6 } END { print n + 0 }' "$f")
            [ "${u1:-0}" -lt "$count" ] && count=${u1:-0}
            orphans=$((count - held))
            if [ "$orphans" -gt 0 ]; then
                warn "db$db: $orphans in-flight task(s) are not held by any worker (worker crashed or was killed?); redis hands them out again only after the visibility timeout of $(human_duration "$VIS_TIMEOUT")"
            fi
        fi
    done
}

check_redis() {
    local out dbs t0 used max evicted
    section "Redis and task queues"
    if [ -z "$REDIS_C" ]; then
        if [ "${REDIS_HP%%:*}" != redis ]; then
            warn "redis is external ($REDIS_HP); the queue checks need the redis service of this stack, skipped"
        else
            fail "redis is not running; the task queues cannot be checked"
        fi
        return
    fi
    out=$(rcli PING 2>&1)
    if [ "$out" != PONG ]; then
        fail "redis does not answer PING: $out"
        return
    fi
    REDIS_INFO=$(rcli INFO 2>&1 | tr -d '\r')
    pass "redis $(redis_info redis_version) answers PING; $(redis_info used_memory_human) used, $(redis_info connected_clients) clients"
    if [ "$(redis_info rdb_last_bgsave_status)" != ok ]; then
        fail "redis could not save its last snapshot and refuses writes until it can; check the disk space and permissions of the redis volume"
    fi
    if [ "$(redis_info aof_enabled)" = 1 ] && [ "$(redis_info aof_last_write_status)" != ok ]; then
        fail "redis could not write its append-only file; check the disk space of the redis volume"
    fi
    evicted=$(redis_info evicted_keys)
    if [ "${evicted:-0}" -gt 0 ] 2>/dev/null; then
        warn "redis evicted $evicted key(s) to stay under its memory limit (policy $(redis_info maxmemory_policy)); queued tasks may have been lost"
    fi
    used=$(redis_info used_memory)
    max=$(redis_info maxmemory)
    if [ "${max:-0}" -gt 0 ] 2>/dev/null && [ $((used * 100 / max)) -ge 90 ]; then
        warn "redis uses $((used * 100 / max))% of its memory limit ($(redis_info maxmemory_human))"
    fi

    dbs=$(printf '%s\n' "$REDIS_INFO" | sed -n 's/^db\([0-9][0-9]*\):.*/\1/p')
    # shellcheck disable=SC2086
    SNAP1=$(queue_snapshot $dbs)
    out=$(printf '%s\n' "$SNAP1" | awk -F'\t' 'NF && $2 != "Q" && $2 != "U"' | head -n 1)
    if [ -n "$out" ]; then
        fail "could not read the task queues from redis: $(printf '%s' "$out" | cut -f2-)"
        return
    fi
    BROKER_DBS=$(printf '%s\n' "$SNAP1" | awk -F'\t' '$2 == "Q" { print $1 }' | sort -un)
    if [ -z "$BROKER_DBS" ]; then
        warn "no celery queues found in redis; the workers have never connected"
        return
    fi
    info "watching the task queues for ${INTERVAL}s"
    t0=$SECONDS
    # shellcheck disable=SC2086
    inspect_workers $BROKER_DBS
    [ $((SECONDS - t0)) -ge "$INTERVAL" ] || sleep $((INTERVAL - (SECONDS - t0)))
    ELAPSED=$((SECONDS - t0))
    # shellcheck disable=SC2086
    SNAP2=$(queue_snapshot $dbs)
    QUEUES_WATCHED=1
    report_workers
    report_queues
}

# workdir_py CONTAINER ROOT MODE [ARG]: run PY_WORKDIR on the policy workdir
# ROOT in CONTAINER
workdir_py() {
    local max=5
    [ $VERBOSE -eq 0 ] || max=25
    printf '%s' "$PY_WORKDIR" | docker exec -i "$1" python3 - "$2" "$1" "$max" "$WORKDIR_AGE" "${@:3}" 2>&1
}

# report the output of PY_WORKDIR
report_workdir() {
    local kind msg
    while IFS="$TAB" read -r kind msg; do
        case "$kind" in
            PASS) pass "$msg" ;;
            WARN) warn "$msg" ;;
            FAIL) fail "$msg" ;;
            INFO) info "$msg" ;;
            DETAIL) detail "$msg" ;;
        esac
    done <<EOF
$1
EOF
}

check_workdir() {
    local root c out
    root=$(env_get "$ENV_API" WORKDIR_VOLUME_PATH)
    root=${root:-/data/policy-workdir}
    section "Git repos in the policy workdir ($root)"
    # api, celery and committer share the policy-data volume
    if ! c=$(first_running api celery committer); then
        warn "no api, celery or committer container runs to check $root in"
        return
    fi
    if ! out=$(workdir_py "$c" "$root" check "$SELF$PROJECT_OPT --reset-workdir"); then
        warn "could not check the git repos in $root: $(printf '%s\n' "$out" | tail -n 1)"
        return
    fi
    report_workdir "$out"
}

event_label() {
    case "$1" in
        readout) echo backup ;;
        exec-rules) echo "policy run" ;;
        *) echo "$1" ;;
    esac
}

# report_events TENANT PREFIX: the failed and unfinished backups, policy runs
# and jobs of one tenant, from the query output in $EVENTS
report_events() {
    local t=$1 prefix=$2 ev label total failed what stuck phase count age addrs max=5
    [ $VERBOSE -eq 0 ] || max=25
    for ev in $(printf '%s\n' "$EVENTS" | awk -F'\t' -v t="$t" '$1 == "S" && $2 == t && !seen[$3]++ {
        print ($3 == "readout" ? 1 : $3 == "exec-rules" ? 2 : 3) " " $3 }' | sort | cut -d' ' -f2); do
        label=$(event_label "$ev")
        read -r total failed <<EOF
$(printf '%s\n' "$EVENTS" | awk -F'\t' -v t="$t" -v e="$ev" '$1 == "S" && $2 == t && $3 == e { n += $5; if ($4 == "failed") f += $5 } END { print n + 0, f + 0 }')
EOF
        if [ "$failed" -gt 0 ]; then
            case "$ev" in
                readout) what="failed their last backup" ;;
                *) what="had an error in the last $label" ;;
            esac
            if [ "$ev" = readout ] && [ "$failed" -eq "$total" ] && [ "$total" -ge 3 ]; then
                fail "${prefix}all $total device(s) $what:"
            else
                warn "${prefix}$failed of $total device(s) $what:"
            fi
            printf '%s\n' "$EVENTS" | awk -F'\t' -v t="$t" -v e="$ev" '$1 == "E" && $2 == t && $3 == e' |
                sort -t "$TAB" -k5,5nr | head -n "$max" |
                while IFS="$TAB" read -r _ _ _ msg count age addrs; do
                    detail "$(printf '%4dx  %s (%s%s), the last %s ago' "$count" "$msg" "$addrs" \
                        "$([ "$count" -le 3 ] || echo ", ...")" "$(human_duration "$age")")"
                done
        fi
        stuck=$(printf '%s\n' "$EVENTS" | awk -F'\t' -v t="$t" -v e="$ev" '$1 == "X" && $2 == t && $3 == e')
        while IFS="$TAB" read -r _ _ _ phase count age addrs; do
            [ -n "$phase" ] || continue
            warn "${prefix}$count $label(s) $phase $(human_duration "$age") ago and not finished ($addrs$([ "$count" -le 3 ] || echo ", ...")); the task was lost or a worker is stuck, see the task queues above"
        done <<EOF
$stuck
EOF
        if [ "$failed" -eq 0 ] && [ -z "$stuck" ]; then
            case "$ev" in
                readout | exec-rules) pass "${prefix}last ${label}s: no errors and none stuck on $total device(s)" ;;
            esac
        fi
    done
}

check_device_events() {
    local out rc t total excluded tenants prefix= lost ev n
    section "Device backups and policy runs (last event per device)"
    out=$(db_query "$(printf '%s\n' "$SQL_DEVICE_EVENTS" | sed "s/@TASK_AGE@/$TASK_AGE/")")
    rc=$?
    if [ $rc -ne 0 ]; then
        case "$out" in
            *'relation "deviceevent" does not exist'*)
                info "the database has no deviceevent table; this Netpicker version does not record device events" ;;
            *)
                warn "could not read the device events from the database:"
                printf '%s\n' "$out" | tail -n 3 | details
                ;;
        esac
        return
    fi
    EVENTS=$out
    tenants=$(printf '%s\n' "$EVENTS" | awk -F'\t' '$1 == "N" { print $2 }' | sort)
    if [ -z "$tenants" ]; then
        info "there are no devices"
        return
    fi
    while IFS= read -r t; do
        [ "$(printf '%s\n' "$tenants" | grep -c .)" -eq 1 ] || prefix="tenant $t: "
        IFS="$TAB" read -r total excluded <<EOF
$(printf '%s\n' "$EVENTS" | awk -F'\t' -v t="$t" '$1 == "N" && $2 == t { print $3 "\t" $4; exit }')
EOF
        info "${prefix}$total device(s)$([ "${excluded:-0}" -eq 0 ] || echo ", $excluded excluded from backups")"
        printf '%s\n' "$EVENTS" | awk -v t="$t" "$AWK_EVENTS_TABLE" | details
        report_events "$t" "$prefix"
    done <<EOF
$tenants
EOF

    # scheduled long ago, not started, and the workers that run and commit
    # them have nothing to do: their tasks will not run any more
    lost=
    for ev in readout exec-rules; do
        n=$(printf '%s\n' "$EVENTS" | awk -F'\t' -v e="$ev" '$1 == "X" && $3 == e && $4 == "scheduled" { n += $5 } END { print n + 0 }')
        [ "$n" -eq 0 ] || lost="$lost, $n $(event_label "$ev")(s)"
    done
    if [ -n "$lost" ] && [ $QUEUES_WATCHED -eq 1 ] && [ $WORKERS_BUSY -eq 0 ] && [ $WORKERS_UNKNOWN -eq 0 ]; then
        warn "${lost#, } scheduled over $(human_duration "$TASK_AGE") ago have not started and kibbitzer and committer are idle, so their tasks are lost or stuck; clear the task queues with '$SELF$PROJECT_OPT --clear-queues'"
        detail "This deletes all waiting and in-flight tasks from redis; the next scheduled backups and policy runs start afresh."
    fi
}

check_logs() {
    local svc name out classified n_crit n_err label groups ngroups max clean=
    section "Container logs (errors since $SINCE)"
    max=5
    [ $VERBOSE -eq 0 ] || max=25
    if [ -n "$API_ANY" ] && ! out=$(docker logs --since "$SINCE" --tail 0 "$API_ANY" 2>&1 >/dev/null); then
        case "$out" in
            *since*) fail "invalid --since value '$SINCE': $out"; return ;;
        esac
    fi
    while IFS='|' read -r svc name _; do
        [ -n "$name" ] || continue
        if ! out=$(docker logs --since "$SINCE" --tail 0 "$name" 2>&1 >/dev/null); then
            warn "$(pad "$svc") cannot read the logs of $name: $out"
            continue
        fi
        classified=$(docker logs --since "$SINCE" "$name" 2>&1 | NP_IGNORE=$IGNORE_RE awk "$AWK_CLASSIFY")
        if [ -z "$classified" ]; then
            clean="$clean $svc"
            continue
        fi
        n_crit=$(printf '%s\n' "$classified" | grep -c "^C$TAB")
        n_err=$(printf '%s\n' "$classified" | grep -c "^E$TAB")
        label=$(pad "$svc")
        [ "$name" = "$svc" ] || label="$label $name:"
        if [ "$n_crit" -gt 0 ]; then
            fail "$label $n_crit critical and $n_err error line(s)"
        else
            warn "$label $n_err error line(s)"
        fi
        groups=$(printf '%s\n' "$classified" | awk "$AWK_GROUP" | sort -t "$TAB" -k1,1nr)
        ngroups=$(printf '%s\n' "$groups" | grep -c .)
        printf '%s\n' "$groups" | head -n "$max" | while IFS="$TAB" read -r count line; do
            detail "$(printf '%4dx  %s' "$count" "$line")"
        done
        if [ "$ngroups" -gt "$max" ]; then
            detail "... and $((ngroups - max)) more kinds of errors; see 'docker logs --since $SINCE $name' or use --verbose"
        fi
    done <<EOF
$CTR
EOF
    [ -z "$clean" ] || pass "no errors in:$clean"
}

# ---------------------------------------------------------------------------
# --clear-queues

# Delete the waiting and in-flight tasks of the celery queues in every redis
# database, after listing them and asking for confirmation.
clear_queues() {
    local out dbs snap waiting inflight db cleared held rc=0 workers
    section "Clear the redis task queues of compose project $PROJECT"
    if [ -z "$REDIS_C" ]; then
        [ "${REDIS_HP%%:*}" = redis ] || die "redis is external ($REDIS_HP); --clear-queues needs the redis service of this stack"
        die "redis is not running"
    fi
    out=$(rcli PING 2>&1)
    [ "$out" = PONG ] || die "redis does not answer PING: $out"
    dbs=$(rcli INFO keyspace 2>&1 | tr -d '\r' | sed -n 's/^db\([0-9][0-9]*\):.*/\1/p')
    # shellcheck disable=SC2086
    snap=$(queue_snapshot $dbs)
    out=$(printf '%s\n' "$snap" | awk -F'\t' 'NF && $2 != "Q" && $2 != "U"' | head -n 1)
    [ -z "$out" ] || die "could not read the task queues from redis: $(printf '%s' "$out" | cut -f2-)"
    BROKER_DBS=$(printf '%s\n' "$snap" | awk -F'\t' '$2 == "Q" { print $1 }' | sort -un)
    if [ -z "$BROKER_DBS" ]; then
        pass "no celery queues found in redis; nothing to clear"
        return 0
    fi

    printf '%s\n' "$snap" | awk -F'\t' '$2 == "Q" && $5 > 0' | while IFS="$TAB" read -r db _ q _ n; do
        info "db$db queue $q: $n task(s) waiting"
    done
    printf '%s\n' "$snap" | awk -F'\t' '$2 == "U" && $3 > 0' | while IFS="$TAB" read -r db _ n age task rkey; do
        info "db$db: $n task(s) in flight, the oldest ${task:-?} (queue ${rkey:-?}) for $(human_duration "$age")"
    done
    waiting=$(printf '%s\n' "$snap" | awk -F'\t' '$2 == "Q" { n += $5 } END { print n + 0 }')
    inflight=$(printf '%s\n' "$snap" | awk -F'\t' '$2 == "U" { n += $3 } END { print n + 0 }')
    if [ $((waiting + inflight)) -eq 0 ]; then
        pass "the task queues are empty and no tasks are in flight; nothing to clear"
        return 0
    fi

    [ $ASSUME_YES -eq 1 ] || [ -t 0 ] || die "not clearing the queues without confirmation; add --yes to clear them without asking"
    if ! confirm "Delete these $waiting waiting and $inflight in-flight task(s)? They will not run."; then
        say "Nothing cleared."
        return 0
    fi

    held=0
    for db in $BROKER_DBS; do
        out=$(rlua "$db" "$LUA_QUEUES" clear 2>&1)
        if printf '%s\n' "$out" | awk -F'\t' 'NF && $1 != "Q" && $1 != "U" { bad = 1 } END { exit !bad }'; then
            fail "db$db: could not clear the task queues: $(printf '%s\n' "$out" | awk -F'\t' 'NF && $1 != "Q" && $1 != "U"' | head -n 1)"
            rc=3
            continue
        fi
        waiting=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "Q" { n += $4 } END { print n + 0 }')
        cleared=$(printf '%s\n' "$out" | awk -F'\t' '$1 == "U" { n += $2 } END { print n + 0 }')
        pass "db$db: deleted $waiting waiting and $cleared in-flight task(s)"
        held=$((held + cleared))
    done

    # every task a worker has taken is in flight, and the worker runs it even
    # after it is deleted from redis
    if [ "$held" -gt 0 ]; then
        workers=$(printf '%s\n' "$CTR" | awk -F'|' '($1 == "kibbitzer" || $1 == "celery" || $1 == "committer") && $3 == "running" { printf "%s ", $2 }')
        [ -z "$workers" ] || info "the workers may still run in-flight tasks they had taken; to drop those as well, restart them with 'docker restart ${workers% }'"
    fi
    return $rc
}

# ---------------------------------------------------------------------------
# --reset-workdir

# "N repo(s) (a, b)" for the repos, one per line, in $1
repo_list() {
    printf '%d repo(s) (%s)' "$(printf '%s\n' "$1" | grep -c .)" "$(printf '%s\n' "$1" | paste -sd, - | sed 's/,/, /g')"
}

# Discard the uncommitted files and stale git locks left behind in the git
# repos of the policy workdir with git reset --hard and git clean, after
# listing them and asking for confirmation: once for the repos without locks
# and once for the repos with stale locks.
reset_workdir() {
    local root c out repos locked
    root=$(env_get "$ENV_API" WORKDIR_VOLUME_PATH)
    root=${root:-/data/policy-workdir}
    section "Reset the git repos in the policy workdir ($root) of compose project $PROJECT"
    c=$(first_running api celery committer) || die "no api, celery or committer container runs to reset the git repos in $root in"
    out=$(workdir_py "$c" "$root" list) || die "could not list the git repos in $root: $(printf '%s\n' "$out" | tail -n 1)"
    report_workdir "$out"
    repos=$(printf '%s\n' "$out" | sed -n "s/^RESET$TAB//p")
    locked=$(printf '%s\n' "$out" | sed -n "s/^UNLOCK$TAB//p")
    if [ -z "$repos$locked" ]; then
        say "Nothing to reset."
        return 0
    fi

    [ $ASSUME_YES -eq 1 ] || [ -t 0 ] || die "not resetting the repos without confirmation; add --yes to reset them without asking"
    [ -z "$repos" ] || confirm "Discard the uncommitted files in $(repo_list "$repos") with git reset --hard and git clean? They are lost." || repos=
    [ -z "$locked" ] || confirm "Remove the stale git locks in $(repo_list "$locked") and reset them with git reset --hard and git clean? Their uncommitted files are lost." || locked=
    if [ -z "$repos$locked" ]; then
        say "Nothing reset."
        return 0
    fi

    if [ -n "$repos" ]; then
        out=$(workdir_py "$c" "$root" reset "$repos") || die "could not reset the git repos in $root: $(printf '%s\n' "$out" | tail -n 1)"
        report_workdir "$out"
    fi
    if [ -n "$locked" ]; then
        out=$(workdir_py "$c" "$root" unlock "$locked") || die "could not reset the git repos in $root: $(printf '%s\n' "$out" | tail -n 1)"
        report_workdir "$out"
    fi
    [ $N_FAIL -eq 0 ] || return 3
}

# ---------------------------------------------------------------------------
# support bundle

# mask secrets in environment variables, compose files (also in a git diff) and URLs
redact() {
    local words='(PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|API_KEY|KEY|CREDENTIAL|password|passwd|secret|token|apikey|api_key|key|credential)'
    sed -E \
        -e "s/([A-Za-z0-9_.:-]*$words[A-Za-z0-9_.:-]*=)[^\"]*/\1***/g" \
        -e "s/^([+[:space:]-]*\"?[A-Za-z0-9_.:-]*$words[A-Za-z0-9_.:-]*\"?[[:space:]]*:[[:space:]]*).+$/\1***/" \
        -e 's#(://[^:/@"[:space:]]*:)[^@/"[:space:]]+@#\1***@#g' \
        -e 's/(requirepass"?,?[[:space:]]*"?)[^"[:space:]]+/\1***/g'
}

setup_bundle() {
    [ $BUNDLE -eq 1 ] || return 0
    BUNDLE_NAME="netpicker-support-$(hostname | cut -d. -f1)-$(date +%Y%m%d-%H%M%S)"
    BUNDLE_DIR="$WORK/$BUNDLE_NAME"
    mkdir -p "$BUNDLE_DIR/logs" "$BUNDLE_DIR/inspect" "$BUNDLE_DIR/compose" || die "cannot create $BUNDLE_DIR"
    REPORT_FILE="$BUNDLE_DIR/report.txt"
}

collect_bundle() {
    local svc name f running dest
    [ $BUNDLE -eq 1 ] || return 0
    {
        echo "# date"; date
        echo; echo "# uname -a"; uname -a
        echo; echo "# uptime"; uptime
        echo; echo "# df -h"; df -h
        echo; echo "# df -i"; df -i
        echo; echo "# free -m"; free -m
        echo; echo "# docker version"; docker version
        echo; echo "# docker info"; docker info
        echo; echo "# docker compose version"; docker compose version
        echo; echo "# docker system df"; docker system df
    } >"$BUNDLE_DIR/system.txt" 2>&1

    running=$(printf '%s\n' "$CTR" | awk -F'|' '$3 == "running" { print $2 }')
    {
        docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
            --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
        echo
        # shellcheck disable=SC2086
        [ -z "$running" ] || docker stats --no-stream $running
    } >"$BUNDLE_DIR/containers.txt" 2>&1

    while IFS='|' read -r svc name _; do
        [ -n "$name" ] || continue
        docker inspect "$name" 2>&1 | redact >"$BUNDLE_DIR/inspect/$name.json"
        docker logs --timestamps --tail "$BUNDLE_LOG_TAIL" "$name" 2>&1 | redact >"$BUNDLE_DIR/logs/$name.log"
    done <<EOF
$CTR
EOF

    printf '%s\n' "$COMPOSE_FILES" | while IFS= read -r f; do
        [ -n "$f" ] && [ -r "$f" ] && redact <"$f" >"$BUNDLE_DIR/compose/$(basename "$f")"
    done
    if [ -n "$COMPOSE_WD" ] && [ -r "$COMPOSE_WD/.env" ]; then
        redact <"$COMPOSE_WD/.env" >"$BUNDLE_DIR/compose/env"
    fi
    [ -z "$CUR_CFG" ] || printf '%s\n' "$CUR_CFG" | redact >"$BUNDLE_DIR/compose/effective-config.yml"

    if [ -n "$REPO" ]; then
        {
            echo "# repo $REPO"; rgit log -1 --format='%H%d %s'
            echo; echo "# git status"; rgit status
            echo; echo "# git log"; rgit log --oneline --decorate -15
            echo; echo "# local changes since ${BASE:-HEAD}"; rgit diff --no-ext-diff --no-textconv --no-color "${BASE:-HEAD}" | redact
            echo; echo "# untracked files"; rgit ls-files --others --exclude-standard
        } >"$BUNDLE_DIR/repo.txt" 2>&1
    fi

    {
        echo "# INFO"; printf '%s\n' "$REDIS_INFO"
        echo; echo "# queues at the start of the sample (db, Q, queue, separator, length / db, U, unacked, oldest age, task, queue)"
        printf '%s\n' "$SNAP1"
        echo; echo "# queues after ${ELAPSED:-0}s"; printf '%s\n' "$SNAP2"
        for f in "$WORK"/inspect.*; do
            [ -f "$f" ] || continue
            echo; echo "# workers on redis db ${f##*.} (W, worker, concurrency, active, reserved, scheduled, queues)"
            cat "$f"
        done
    } >"$BUNDLE_DIR/redis.txt" 2>&1

    {
        echo "# agents in the database (A, agent id, tenant, name, heartbeat age, devices / U, tenant, devices without an agent)"
        printf '%s\n' "$AGENTS_DB"
        echo; echo "# agents connected to the api (C, agent id, tenant, host, api process)"
        printf '%s\n' "$AGENTS_LIVE"
        echo; echo "# agent services of the stack (agent id, service)"
        printf '%s\n' "$AGENT_MAP"
    } >"$BUNDLE_DIR/agents.txt" 2>&1

    {
        echo "# alembic_version setting: $(env_get "$ENV_API" alembic_version)"
        echo; echo "# heads of the api image"; alembic_cmd heads
        echo; echo "# database revision"; db_revision
        echo; echo "# history of the api image"; alembic_cmd history | head -n 60
    } >"$BUNDLE_DIR/alembic.txt" 2>&1

    dest="$PWD/$BUNDLE_NAME.tar.gz"
    [ -w "$PWD" ] || dest="${TMPDIR:-/tmp}/$BUNDLE_NAME.tar.gz"
    REPORT_FILE=
    if tar -czf "$dest" -C "$WORK" "$BUNDLE_NAME"; then
        say ""
        say "Support bundle: $dest"
        say "Review it before you share it: secrets in environment variables, compose files and URLs are"
        say "masked, but the logs can still contain sensitive data such as device names and addresses."
    else
        say "Could not write the support bundle to $dest"
    fi
}

# ---------------------------------------------------------------------------

print_summary() {
    local item
    section "Summary"
    printf '%s' "$FAIL_LIST" | tr "$TAB" '\n' | while IFS= read -r item; do
        [ -z "$item" ] || say "${C_RED}[FAIL]${C_RESET} $item"
    done
    printf '%s' "$WARN_LIST" | tr "$TAB" '\n' | while IFS= read -r item; do
        [ -z "$item" ] || say "${C_YELLOW}[WARN]${C_RESET} $item"
    done
    say ""
    if [ $N_FAIL -gt 0 ]; then
        RESULT=2
        say "${C_BOLD}${C_RED}Result: FAIL${C_RESET} ($N_PASS passed, $N_WARN warning(s), $N_FAIL failure(s))"
    elif [ $N_WARN -gt 0 ]; then
        RESULT=1
        say "${C_BOLD}${C_YELLOW}Result: WARN${C_RESET} ($N_PASS passed, $N_WARN warning(s))"
    else
        RESULT=0
        say "${C_BOLD}${C_GREEN}Result: OK${C_RESET} ($N_PASS passed)"
    fi
}

main() {
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/netpicker-troubleshoot.XXXXXX") || die "cannot create a temporary directory"
    trap 'rm -rf "$WORK"' EXIT
    preflight
    detect_project
    load_containers
    if [ $CLEAR_QUEUES -eq 1 ]; then
        resolve_targets
        clear_queues
        exit $?
    fi
    if [ $RESET_WORKDIR -eq 1 ]; then
        resolve_targets
        reset_workdir
        exit $?
    fi
    setup_bundle
    resolve_targets
    load_compose
    find_repo
    print_environment
    check_version
    check_host
    check_disk
    check_containers
    check_compose
    check_resources
    check_migrations
    check_connectivity
    check_agents
    check_redis
    check_workdir
    check_device_events
    check_logs
    print_summary
    collect_bundle
    exit $RESULT
}

main
