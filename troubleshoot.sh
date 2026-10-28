#!/usr/bin/env bash
#
# Troubleshoot a running Netpicker Docker Compose stack.
#
# Checks that all services are up and healthy, that the database is at the
# alembic revision the api image expects, that the containers can reach each
# other, that the celery task queues in redis are not stuck and that the
# container logs are free of errors.
#
# Run it on the Docker host as a user that can access the Docker daemon. It
# only reads state; when the api container is down it starts a throw-away
# copy of the api image (without network) to read the alembic revisions.

set -o pipefail

usage() {
    cat <<'EOF'
Usage: ./troubleshoot.sh [options]

Checks a running Netpicker Docker stack: containers and their health checks,
the database migration (alembic) revision, connectivity between containers,
the redis task queues and errors in the container logs.

Options:
  -p, --project NAME     Docker Compose project name (default: auto-detect)
  -s, --since DURATION   how far back to scan the logs, in "docker logs --since"
                         format, e.g. 30m, 6h or 2026-01-31T12:00:00 (default: 1h)
  -i, --interval SECS    how long to watch the task queues (default: 15)
      --task-age SECS    warn about tasks unacknowledged for longer than this
                         (default: 3600)
      --ignore REGEX     ignore log lines matching the extended regex REGEX;
                         can be given more than once
  -b, --bundle           also write a support bundle (.tar.gz) to the current
                         directory with logs, container details, redis and
                         migration state; secrets are masked on a best-effort basis
  -v, --verbose          show more log lines per container
      --no-color         disable colored output
  -h, --help             show this help

Exit status: 0 all checks passed, 1 warnings, 2 failures, 3 could not run.
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

REQUIRED_SERVICES="db redis minio gitd gitdctrl api celery committer agent kibbitzer frontend"
OPTIONAL_SERVICES="swagger cadvisor syslog-ng"
# one-shot services, checked by their own section
ONESHOT_SERVICES="db_migration"

INSPECT_TIMEOUT=2
BUNDLE_LOG_TAIL=20000

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
        -p | --project) need_value "$@"; PROJECT=$2; shift 2 ;;
        -s | --since) need_value "$@"; SINCE=$2; shift 2 ;;
        -i | --interval) need_value "$@"; need_number "$1" "$2"; INTERVAL=$2; shift 2 ;;
        --task-age) need_value "$@"; need_number "$1" "$2"; TASK_AGE=$2; shift 2 ;;
        --ignore) need_value "$@"; IGNORE_RE="${IGNORE_RE:+$IGNORE_RE|}($2)"; shift 2 ;;
        -b | --bundle) BUNDLE=1; shift ;;
        -v | --verbose) VERBOSE=1; shift ;;
        --no-color) COLOR=no; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
    esac
done

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

    v=$(env_get "$ENV_AGENT" SHENV_API_URL)
    AGENT_API_HP=$(url_hostport "${v:-http://api:8000}")
    v=$(env_get "$ENV_AGENT" NETPICKER_GIT_URL)
    AGENT_GIT_HP=$(url_hostport "${v:-http://frontend/git}")
    v=$(env_get "$ENV_AGENT" REDIS_URL)
    AGENT_REDIS_HP=$(url_hostport "${v:-redis://redis}" 6379)

    v=$(env_get "$ENV_KIB" SHENV_API_URL)
    KIB_API_HP=$(url_hostport "${v:-http://api:8000}")
    v=$(env_get "$ENV_KIB" SHENV_TAC_HOST)
    p=$(env_get "$ENV_KIB" SHENV_TAC_PORT)
    KIB_TAC_HP="${v:-agent}:${p:-8765}"
    v=$(env_get "$ENV_KIB" SHENV_REDIS_URL)
    KIB_REDIS_HP=$(url_hostport "${v:-redis://redis}" 6379)
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
# Output: Q<TAB>queue<TAB>separator<TAB>length and
#         U<TAB>unacked count<TAB>oldest age in seconds<TAB>task<TAB>routing key
IFS= read -r -d '' LUA_QUEUES <<'EOF'
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
                if type(len) == "number" then n = n + len end
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
return out
EOF

# Agents connected to the api websocket: every api process keeps a set
# AgentBroker.<host>.<pid> of its connected agents.
# Output: servers<TAB>agents
IFS= read -r -d '' LUA_AGENTS <<'EOF'
local servers, agents, cursor = 0, 0, "0"
repeat
  local r = redis.call("SCAN", cursor, "MATCH", "AgentBroker.*", "COUNT", 1000)
  cursor = r[1]
  for _, key in ipairs(r[2]) do
    local n = redis.pcall("SCARD", key)
    if type(n) == "number" then
      servers = servers + 1
      agents = agents + n
    end
  end
until cursor == "0"
return servers .. "\t" .. agents
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

IFS= read -r -d '' PY_DB_REVISION <<'EOF'
from sqlalchemy import create_engine, text

from app.settings import common_config

with create_engine(common_config.ALEMBIC_URI).connect() as conn:
    for (version,) in conn.execute(text("SELECT version_num FROM alembic_version")):
        print(version)
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

# rlua DB SCRIPT: run a Lua script in a redis database
rlua() {
    if [ -n "$REDIS_PW" ]; then
        printf '%s' "$2" | REDISCLI_AUTH=$REDIS_PW docker exec -i -e REDISCLI_AUTH "$REDIS_C" \
            sh -c 'redis-cli --raw -n "$1" EVAL "$(cat)" 0' sh "$1"
    else
        printf '%s' "$2" | docker exec -i "$REDIS_C" \
            sh -c 'redis-cli --raw -n "$1" EVAL "$(cat)" 0' sh "$1"
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

# print the revision(s) in the alembic_version table
db_revision() {
    local dbc name user out c
    dbc=
    case "$DB_HP" in
        db:*) dbc=$(svc_running db) ;;
    esac
    if [ -n "$dbc" ]; then
        name=$(env_get "$ENV_API" API_DB_NAME)
        user=$(env_get "$ENV_API" API_DB_USER)
        if out=$(docker exec "$dbc" psql -X -q -t -A -U "${user:-netpicker}" -d "${name:-netpicker}" \
            -c 'SELECT version_num FROM alembic_version' </dev/null 2>&1); then
            printf '%s\n' "$out"
            return 0
        fi
        case "$out" in
            *alembic_version*) printf '%s\n' "$out"; return 1 ;;
        esac
    fi
    # external database, or psql did not work: ask the api code
    if ! c=$(first_running api celery committer); then
        echo "${out:-no running db, api, celery or committer container to query the database}"
        return 1
    fi
    out=$(docker exec "$c" python3 -c "$PY_DB_REVISION" </dev/null 2>&1)
    local rc=$?
    printf '%s\n' "$out" | tail -n 3
    return $rc
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
    local files ref ver c
    section "Environment"
    info "Host $(hostname), $(date '+%Y-%m-%d %H:%M:%S %Z'), Docker $DOCKER_VERSION"
    info "Compose project $PROJECT with $(printf '%s\n' "$CTR" | grep -c .) containers"
    if [ -n "$API_ANY" ]; then
        files=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$API_ANY" 2>/dev/null)
        [ -z "$files" ] || info "Compose files: $files"
        ref=$(ctr_field "$API_ANY" 9)
        c=$(svc_running api)
        if [ -n "$c" ]; then
            ver=$(docker exec "$c" python3 -c 'import importlib.metadata as m; print(m.version("netyce-api"))' </dev/null 2>/dev/null)
        fi
        info "api image $ref${ver:+ (netyce-api $ver)}"
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
    echo "agent|tcp|$AGENT_API_HP|api"
    echo "agent|tcp|$AGENT_REDIS_HP|redis"
    echo "agent|tcp|$AGENT_GIT_HP|frontend git"
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

check_agents_connected() {
    local local_agents out servers agents
    [ -n "$REDIS_C" ] || return 0
    local_agents=$(printf '%s\n' "$CTR" | awk -F'|' '$3 == "running" && $9 ~ /netpicker\/agent/' | grep -c .)
    out=$(rlua "$API_REDIS_DB" "$LUA_AGENTS" 2>&1)
    servers=$(printf '%s' "$out" | cut -f1)
    agents=$(printf '%s' "$out" | cut -f2)
    case "$servers$agents" in
        '' | *[!0-9]*)
            warn "could not count the agents connected to the api: $out"
            return
            ;;
    esac
    if [ "$agents" -gt 0 ]; then
        pass "$agents agent(s) connected to the api websocket ($local_agents agent container(s) running in this stack)"
    elif [ "$local_agents" -gt 0 ]; then
        fail "no agent is connected to the api websocket although $local_agents agent container(s) run; check the agent logs"
    else
        warn "no agent is connected to the api websocket"
    fi
}

check_connectivity() {
    local src c ok failed s mode hp label out rc
    section "Connectivity between containers"
    for src in api celery committer agent kibbitzer frontend; do
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
$(connectivity_matrix)
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
    check_agents_connected
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

report_workers() {
    local db f worker conc act res sch queues svc c host
    for db in $BROKER_DBS; do
        f="$WORK/inspect.$db"
        if [ -z "$INSPECT_C" ]; then
            fail "db$db: no api, celery or committer container runs to inspect the workers with"
            continue
        fi
        if grep -q "^E$TAB" "$f"; then
            warn "db$db: could not inspect the workers: $(grep "^E$TAB" "$f" | head -n 1 | cut -f2-)"
            continue
        fi
        if ! grep -q "^W$TAB" "$f"; then
            if [ -s "$f" ]; then
                warn "db$db: could not inspect the workers: $(tail -n 1 "$f")"
            else
                fail "db$db: no celery worker answers on this broker"
            fi
            continue
        fi
        while IFS="$TAB" read -r _ worker conc act res sch queues; do
            svc=$(host_service "${worker#*@}")
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
            if ! cat "$WORK"/inspect.* 2>/dev/null | grep -q "@$host$TAB"; then
                fail "$(pad "$svc") $c: its celery worker does not answer control commands; it may be hung or overloaded"
            fi
        done
    done
}

report_queues() {
    local db q n1 n2 ncons conc active empty f u1 count age task rkey held orphans
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
    report_workers
    report_queues
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
# support bundle

# mask secrets in environment variables, compose files and URLs
redact() {
    local words='(PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|API_KEY|KEY|CREDENTIAL|password|passwd|secret|token|apikey|api_key|key|credential)'
    sed -E \
        -e "s/([A-Za-z0-9_.:-]*$words[A-Za-z0-9_.:-]*=)[^\"]*/\1***/g" \
        -e "s/^([[:space:]-]*\"?[A-Za-z0-9_.:-]*$words[A-Za-z0-9_.:-]*\"?[[:space:]]*:[[:space:]]*).+$/\1***/" \
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
    local svc name files wd f running dest
    [ $BUNDLE -eq 1 ] || return 0
    {
        echo "# date"; date
        echo; echo "# uname -a"; uname -a
        echo; echo "# uptime"; uptime
        echo; echo "# df -h"; df -h
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

    if [ -n "$API_ANY" ]; then
        files=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$API_ANY" 2>/dev/null)
        wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$API_ANY" 2>/dev/null)
        printf '%s\n' "$files" | tr ',' '\n' | while IFS= read -r f; do
            [ -n "$f" ] && [ -r "$f" ] && redact <"$f" >"$BUNDLE_DIR/compose/$(basename "$f")"
        done
        if [ -n "$wd" ] && [ -r "$wd/.env" ]; then
            redact <"$wd/.env" >"$BUNDLE_DIR/compose/env"
        fi
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
    setup_bundle
    resolve_targets
    print_environment
    check_containers
    check_migrations
    check_connectivity
    check_redis
    check_logs
    print_summary
    collect_bundle
    exit $RESULT
}

main
