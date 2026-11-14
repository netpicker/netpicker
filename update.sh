#!/usr/bin/env bash
#
# Update a Netpicker Docker Compose installation to the latest version, with
# checks first.
#
# The update goes wrong in a few common ways: local edits to the compose files
# of this repo make 'git pull' fail or get lost, a stack that runs the pinned
# compose file has a pinned database revision, only some of the :latest images
# are pulled, or the api container cannot use the docker socket because the
# group in group_add is not the group of the socket. This script checks for
# those first, explains what it finds and fixes it after asking, then pulls
# the new images while Netpicker still runs, stops it, backs up the volumes,
# starts the new version and checks that it is healthy. When that fails it
# offers to roll back to the version that ran before.
#
# With --dry-run it only runs the checks and shows what it would change.

set -o pipefail

usage() {
    cat <<'EOF'
Usage: ./update.sh [options]

Updates Netpicker to the latest version of the main branch of this repo and
the :latest images. First it checks the installation and fixes what would
make the update fail, asking before each change:

  - Docker and Docker Compose versions, access to the Docker daemon
  - the git repo: local edits of the compose files are moved to
    docker-compose.override.yml, so 'git pull' keeps them; a directory that
    is not a git clone is turned into one
  - a stack on docker-compose.pinned.yml is offered the switch to latest
  - the group of the docker socket for group_add (DOCKER_GID in .env)
  - which images are outdated, the Docker Hub connection and rate limit
  - free disk space for the new images and the backup

Then it pulls all images while Netpicker still runs, stops it, backs up its
volumes with backup.sh, starts the new version and waits until it is healthy.
When the new version does not come up it offers to roll back.

Options:
  -n, --dry-run, --check  only run the checks and show what an update would
                          change; changes nothing (only fetches from git)
  -y, --yes               apply the recommended fixes and update without asking
  -p, --project NAME      Docker Compose project name (default: auto-detect)
      --timeout SECS      how long to wait for the stack to become healthy
                          (default: 600)
      --rollback [STAMP]  roll back the last update (or the one of STAMP, see
                          the directories in .update/), then exit
      --cleanup           delete the rollback data (backups, old image tags,
                          .update/) of all updates but the last, then exit
      --no-color          disable colored output
  -h, --help              show this help

Exit status: 0 done (dry run: ready to update), 1 done with warnings, 2 the
update failed or needs a fix by hand, 3 could not run.
EOF
}

DRY_RUN=0
ASSUME_YES=0
PROJECT=
TIMEOUT=600
COLOR=auto
ROLLBACK=0
ROLLBACK_STAMP=
CLEANUP=0

while [ $# -gt 0 ]; do
    case "$1" in
        -n | --dry-run | --check) DRY_RUN=1 ;;
        -y | --yes) ASSUME_YES=1 ;;
        -p | --project)
            [ -n "${2:-}" ] || { echo "Option $1 needs a value" >&2; exit 3; }
            PROJECT=$2
            shift
            ;;
        --timeout)
            case "${2:-}" in '' | *[!0-9]*) echo "Option $1 needs a number" >&2; exit 3 ;; esac
            TIMEOUT=$2
            shift
            ;;
        --rollback)
            ROLLBACK=1
            case "${2:-}" in [0-9]*) ROLLBACK_STAMP=$2; shift ;; esac
            ;;
        --cleanup) CLEANUP=1 ;;
        --no-color) COLOR=no ;;
        -h | --help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
    esac
    shift
done

DIR=$(cd "$(dirname "$0")" && pwd)
DIR_P=$(cd "$DIR" && pwd -P)
cd "$DIR" || exit 3

REPO_URL=${NETPICKER_REPO_URL:-https://github.com/netpicker/netpicker.git}
BRANCH=${NETPICKER_BRANCH:-main}
STAMP=$(date +%Y%m%d-%H%M%S)
STATE_ROOT="$DIR/.update"
STATE="$STATE_ROOT/$STAMP"
MAIN_FILE=docker-compose.yml
PINNED_FILE=docker-compose.pinned.yml
OVERRIDE_FILE=docker-compose.override.yml
# Docker Compose 2.17 has everything this script uses; 2.24 adds !reset and
# !override, which override files need to remove settings
COMPOSE_MIN=2.17.0
COMPOSE_RESET=2.24.0

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

N_WARN=0
N_FAIL=0
# the changes the update makes, one per line
PLAN=

say() { printf '%s\n' "$*"; }
section() { say ""; say "${C_BOLD}== $* ==${C_RESET}"; }
pass() { say "${C_GREEN}[ OK ]${C_RESET} $*"; }
warn() { N_WARN=$((N_WARN + 1)); say "${C_YELLOW}[WARN]${C_RESET} $*"; }
fail() { N_FAIL=$((N_FAIL + 1)); say "${C_RED}[FAIL]${C_RESET} $*"; }
info() { say "${C_CYAN}[INFO]${C_RESET} $*"; }
step() { say "${C_BOLD}-->${C_RESET} $*"; }
detail() { say "       $*"; }
details() {
    local line
    while IFS= read -r line; do detail "${C_DIM}$line${C_RESET}"; done
}
die() { echo "${C_RED}error:${C_RESET} $*" >&2; exit 3; }
plan() { PLAN="$PLAN$*
"; }

# ask QUESTION [y|n]: true for yes. A dry run and --yes take the default
# answer, which is yes unless given as n.
ask() {
    local q=$1 def=${2:-y} answer
    if [ $DRY_RUN -eq 1 ]; then
        say "       ${C_DIM}? $q -> dry run: $([ "$def" = y ] && echo yes || echo no)${C_RESET}"
        [ "$def" = y ]
        return
    fi
    if [ $ASSUME_YES -eq 1 ]; then
        say "       ? $q -> $([ "$def" = y ] && echo yes || echo no) (--yes)"
        [ "$def" = y ]
        return
    fi
    while :; do
        if [ "$def" = y ]; then printf '       %s? %s [Y/n] ' "$C_BOLD" "$q$C_RESET"; else printf '       %s? %s [y/N] ' "$C_BOLD" "$q$C_RESET"; fi
        read -r answer </dev/tty || answer=n
        case "${answer:-$def}" in
            y | Y | yes | YES | Yes) return 0 ;;
            n | N | no | NO | No) return 1 ;;
        esac
    done
}

# choose QUESTION DEFAULT KEY=TEXT...: print the key of the chosen answer
choose() {
    local q=$1 def=$2 answer opt keys=
    shift 2
    if [ $DRY_RUN -eq 1 ] || [ $ASSUME_YES -eq 1 ]; then
        say "       ${C_DIM}? $q -> $def ($([ $DRY_RUN -eq 1 ] && echo 'dry run' || echo '--yes'))${C_RESET}" >&2
        echo "$def"
        return
    fi
    for opt in "$@"; do
        say "         ${opt%%=*}) ${opt#*=}" >&2
        keys="$keys ${opt%%=*}"
    done
    while :; do
        printf '       %s? %s [%s] ' "$C_BOLD" "$q$C_RESET" "$def" >&2
        read -r answer </dev/tty || answer=
        answer=${answer:-$def}
        case " $keys " in *" $answer "*) echo "$answer"; return ;; esac
    done
}

human_kib() {
    awk -v k="$1" 'BEGIN {
        n = split("K M G T P", u)
        for (i = 1; k >= 1024 && i < n; i++) k /= 1024
        printf(i == 1 ? "%d%s\n" : "%.1f%s\n", k, u[i])
    }'
}

# ver_ge A B: true if version A >= version B (2.21.0, v2.24.6-desktop.1)
ver_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        gsub(/^v/, "", a); gsub(/^v/, "", b); sub(/[-+].*$/, "", a); sub(/[-+].*$/, "", b)
        na = split(a, pa, "."); nb = split(b, pb, ".")
        for (i = 1; i <= (na > nb ? na : nb); i++) {
            if (pa[i] + 0 > pb[i] + 0) exit 0
            if (pa[i] + 0 < pb[i] + 0) exit 1
        }
        exit 0
    }'
}

# ---------------------------------------------------------------------------
# helpers

WORK=$(mktemp -d "${TMPDIR:-/tmp}/netpicker-update.XXXXXX") || die "cannot create a temporary directory"
trap 'rm -rf "$WORK"' EXIT

# git on the repo; GIT_PROBE points at a git dir outside of $DIR while a
# directory that is not a git clone is only checked (see check_repo)
GIT_PROBE=
g() {
    if [ -n "$GIT_PROBE" ]; then
        git --git-dir="$GIT_PROBE" --work-tree="$DIR" "$@"
    else
        git -C "$DIR" "$@"
    fi
}

# .env of the stack: env_get KEY, env_set KEY VALUE, env_unset KEY
env_get() {
    [ -f "$DIR/.env" ] || return 1
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$DIR/.env" | tail -n 1 | sed "s/^[\"']//; s/[\"'][[:space:]]*\$//; s/[[:space:]]*\$//"
}
env_set() {
    if [ -f "$DIR/.env" ] && grep -q "^[[:space:]]*$1[[:space:]]*=" "$DIR/.env"; then
        sed "s|^[[:space:]]*$1[[:space:]]*=.*|$1=$2|" "$DIR/.env" >"$WORK/env.new" && cat "$WORK/env.new" >"$DIR/.env"
    else
        [ ! -s "$DIR/.env" ] || [ -z "$(tail -c 1 "$DIR/.env")" ] || echo >>"$DIR/.env"
        echo "$1=$2" >>"$DIR/.env"
    fi
}
env_unset() {
    [ -f "$DIR/.env" ] || return 0
    grep -v "^[[:space:]]*$1[[:space:]]*=" "$DIR/.env" >"$WORK/env.new"
    cat "$WORK/env.new" >"$DIR/.env"
}

# put_file SRC DEST: copy SRC to DEST with a new inode, so a running script
# that is replaced (update.sh itself) keeps reading the old one
put_file() {
    mkdir -p "$(dirname "$2")" &&
        cp -p "$1" "$2.tmp.$$" && mv -f "$2.tmp.$$" "$2"
}

# dc FILES ARGS...: docker compose with the compose files FILES (absolute
# paths, separated by colons)
dc() {
    local files=$1 f args=()
    shift
    local IFS=:
    for f in $files; do args+=(-f "$f"); done
    unset IFS
    docker compose --project-directory "$DIR" -p "$PROJECT" "${args[@]}" "$@"
}

# rel PATH: PATH relative to $DIR when it is in $DIR
rel() {
    case "$1" in
        "$DIR"/*) echo "${1#"$DIR"/}" ;;
        "$DIR_P"/*) echo "${1#"$DIR_P"/}" ;;
        *) echo "$1" ;;
    esac
}
rel_list() {
    local f out= IFS=:
    for f in $1; do out="$out${out:+, }$(rel "$f")"; done
    echo "$out"
}

# the repository of an image reference, without tag or digest
image_repo() {
    printf '%s\n' "$1" | sed 's/@.*//; s#\(.*/\)\{0,1\}\([^/:]*\):[^/]*$#\1\2#'
}
image_tag() {
    case "$1" in
        *@*) echo "${1#*@}" ;;
        *) local last=${1##*/}; case "$last" in *:*) echo "${last#*:}" ;; *) echo latest ;; esac ;;
    esac
}

# python3 for the helpers below: on the host when it has PyYAML, or else in
# the api image, which has it
PY_IMAGE=
py() {
    local script=$1
    shift
    if [ -z "$PY_MODE" ]; then
        if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
            PY_MODE=host
        else
            PY_MODE=docker
            [ -n "$PY_IMAGE" ] || PY_IMAGE=$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '(^|/)netpicker/api:' | head -n 1)
            [ -n "$PY_IMAGE" ] || { echo "no python3 with PyYAML on this host and no netpicker/api image to run it in" >&2; return 3; }
        fi
    fi
    if [ "$PY_MODE" = host ]; then
        python3 -c "$script" "$@"
    else
        docker run --rm --network none -u "$(id -u):$(id -g)" -v "$WORK:$WORK:z" \
            --entrypoint python3 "$PY_IMAGE" -c "$script" "$@"
    fi
}
PY_MODE=

# Facts from a compose config in JSON: S|service|image|container name,
# G|group_add of the api, A|alembic_version of the api, K|host path mounted
# as the docker socket into the api
IFS= read -r -d '' PY_FACTS <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
svcs = c.get("services") or {}
for name in sorted(svcs):
    s = svcs[name] or {}
    print("S|%s|%s|%s" % (name, s.get("image") or "", s.get("container_name") or ""))
api = svcs.get("api") or {}
print("G|" + ",".join(str(x) for x in api.get("group_add") or []))
env = api.get("environment") or {}
if isinstance(env, list):
    env = dict(e.split("=", 1) if "=" in e else (e, None) for e in env)
print("A|" + str(env.get("alembic_version") or ""))
for v in api.get("volumes") or []:
    if isinstance(v, dict) and v.get("target") == "/var/run/docker.sock":
        print("K|" + str(v.get("source") or ""))
EOF

# Compare two compose configs (JSON from 'docker compose config') and write
# the override file that turns the first into the second.
#   argv: base.json current.json existing-override|"" has-reset(0|1)
#         mode(diff|residual) out-full out-clean
# Prints records: ADD|SKIP|MANUAL|RES <tab> where <tab> what, and PIN <tab>
# where <tab> value for the settings in the override that hold back the update.
# out-full is the existing override with the differences merged in; out-clean
# the same without the PINs.
IFS= read -r -d '' PY_DIFF <<'EOF'
import copy, json, re, sys, datetime
import yaml

base_p, cur_p, ovr_p, has_reset, mode, out_full, out_clean = sys.argv[1:8]
has_reset = has_reset == "1"
residual = mode == "residual"
B = json.load(open(base_p))
C = json.load(open(cur_p))

class Reset(object):
    pass

class Override(list):
    pass

class Loader(yaml.SafeLoader):
    pass

Loader.add_constructor("!reset", lambda l, n: Reset())
Loader.add_constructor("!override", lambda l, n: Override(l.construct_sequence(n, deep=True)))

class Dumper(yaml.SafeDumper):
    pass

Dumper.add_representer(Reset, lambda d, o: d.represent_scalar("!reset", "null"))
Dumper.add_representer(Override, lambda d, o: d.represent_sequence("!override", list(o)))

NP = re.compile(r"(^|/)netpicker/[^/]+$")
# lists that an override replaces instead of appending to
REPLACED = ("command", "entrypoint", "test")
# lists of which an override replaces the items with the same key
KEYED = {"volumes": "target", "secrets": "target", "configs": "target"}

def repo(img):
    img = str(img).split("@")[0]
    head, _, last = img.rpartition("/")
    return (head + "/" if head else "") + last.split(":")[0]

def where(p):
    if len(p) >= 2 and p[0] == "services":
        return p[1] + (": " + ".".join(str(x) for x in p[2:]) if len(p) > 2 else "")
    return ".".join(str(x) for x in p)

def fmt(v):
    s = v if isinstance(v, str) else json.dumps(v, sort_keys=True)
    return s if len(s) <= 90 else s[:87] + "..."

def note(kind, p, text):
    if residual:
        kind = "RES"
    print("%s\t%s\t%s" % (kind, where(p), text))

# the settings update.sh manages itself
def skipped(p, b, c):
    if len(p) == 3 and p[0] == "services" and p[2] == "image" and b and c:
        if NP.search(repo(b)) and repo(b) == repo(c):
            if not residual:
                note("SKIP", p, "%s -> %s: an image pinned to a version; the update installs the latest images" % (b, c))
            return True
    if len(p) == 4 and p[0] == "services" and p[2] == "environment" and p[3] == "alembic_version":
        if not residual:
            note("SKIP", p, "%s -> %s: the compose file of the version sets this" % (b, c))
        return True
    if len(p) == 3 and p[0] == "services" and p[2] == "group_add":
        if not residual:
            note("SKIP", p, "%s -> %s: set with DOCKER_GID in .env instead" % (b, c))
        return True
    return False

def ldiff(b, c, p):
    key = p[-1]
    if key in REPLACED:
        note("ADD", p, "%s -> %s" % (fmt(b), fmt(c)))
        return c
    added = [x for x in c if x not in b]
    removed = [x for x in b if x not in c]
    kf = KEYED.get(key) if p[0] == "services" else None
    if kf:
        keys = set(y.get(kf) for y in added if isinstance(y, dict))
        removed = [x for x in removed if not (isinstance(x, dict) and x.get(kf) in keys)]
    if not removed:
        for x in added:
            note("ADD", p, "added " + fmt(x))
        return added or None
    if has_reset:
        note("ADD", p, "%s -> %s" % (fmt(b), fmt(c)))
        return Override(c)
    note("MANUAL", p, "%s -> %s: an override file can only add to this list; "
         "removing items needs Docker Compose 2.24 or newer (!override)" % (fmt(b), fmt(c)))
    return added or None

def diff(b, c, p):
    res = {}
    for k in c:
        q = p + (k,)
        if k not in b:
            if skipped(q, None, c[k]):
                continue
            if c[k] is None:
                continue
            res[k] = c[k]
            note("ADD", q, "added " + fmt(c[k]))
        elif b[k] != c[k]:
            if skipped(q, b[k], c[k]):
                continue
            if isinstance(b[k], dict) and isinstance(c[k], dict):
                sub = diff(b[k], c[k], q)
                if sub:
                    res[k] = sub
            elif isinstance(b[k], list) and isinstance(c[k], list):
                r = ldiff(b[k], c[k], q)
                if r is not None:
                    res[k] = r
            elif c[k] is None:
                if has_reset:
                    res[k] = Reset()
                    note("ADD", q, "removed (was %s)" % fmt(b[k]))
                else:
                    note("MANUAL", q, "removed (was %s); removing a setting in an override file needs Docker Compose 2.24 or newer (!reset)" % fmt(b[k]))
            else:
                res[k] = c[k]
                note("ADD", q, "%s -> %s" % (fmt(b[k]), fmt(c[k])))
    for k in b:
        if k in c or b[k] is None:
            continue
        q = p + (k,)
        if skipped(q, b[k], None):
            continue
        if has_reset:
            res[k] = Reset()
            note("ADD", q, "removed (was %s)" % fmt(b[k]))
        else:
            note("MANUAL", q, "removed (was %s); removing a setting in an override file needs Docker Compose 2.24 or newer (!reset)" % fmt(b[k]))
    return res

D = {}
bs, cs = B.get("services") or {}, C.get("services") or {}
for s in cs:
    if s not in bs:
        D.setdefault("services", {})[s] = cs[s]
        note("ADD", ("services", s), "a service of your own, image %s" % cs[s].get("image"))
    else:
        r = diff(bs[s], cs[s], ("services", s))
        if r:
            D.setdefault("services", {})[s] = r
for s in bs:
    if s not in cs:
        # a service with a profile that is not active does not start
        D.setdefault("services", {})[s] = {"profiles": ["disabled"]}
        note("ADD", ("services", s), "removed; the override disables it with a profile")
for top in ("volumes", "networks", "secrets", "configs"):
    r = diff(B.get(top) or {}, C.get(top) or {}, (top,))
    if r:
        D[top] = r

if residual:
    sys.exit(0)

def merge(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        out = dict(a)
        for k, v in b.items():
            out[k] = merge(a[k], v) if k in a else v
        return out
    if isinstance(a, list) and isinstance(b, list) and not isinstance(b, Override):
        return list(a) + [x for x in b if x not in a]
    return b

existing = {}
if ovr_p:
    existing = yaml.load(open(ovr_p), Loader=Loader) or {}
final = merge(existing, D)

# settings in the override that hold back the update
clean = copy.deepcopy(final)
for s, svc in list((final.get("services") or {}).items()):
    if not isinstance(svc, dict):
        continue
    img = svc.get("image")
    if isinstance(img, str) and NP.search(repo(img)) and not repo(img).endswith("netpicker/minio"):
        tag = img.split("@")[1] if "@" in img else (img.rpartition("/")[2].split(":")[1] if ":" in img.rpartition("/")[2] else "latest")
        if tag != "latest" and s in bs:
            print("PIN\t%s: image\t%s" % (s, img))
            clean["services"][s] = {k: v for k, v in clean["services"][s].items() if k != "image"}
    env = svc.get("environment")
    if isinstance(env, dict) and "alembic_version" in env:
        print("PIN\t%s: environment.alembic_version\t%s" % (s, env["alembic_version"]))
        e = dict(env)
        del e["alembic_version"]
        clean["services"][s] = dict(clean["services"][s], environment=e)
        if not e:
            del clean["services"][s]["environment"]
    elif isinstance(env, list) and any(str(x).startswith("alembic_version=") for x in env):
        print("PIN\t%s: environment.alembic_version\t%s" % (s, [x for x in env if str(x).startswith("alembic_version=")][0]))
        clean["services"][s] = dict(clean["services"][s], environment=[x for x in env if not str(x).startswith("alembic_version=")])
    if "group_add" in svc and s in bs:
        print("PIN\t%s: group_add\t%s" % (s, svc["group_add"]))
        clean["services"][s] = {k: v for k, v in clean["services"][s].items() if k != "group_add"}
for s in list((clean.get("services") or {})):
    if clean["services"][s] == {}:
        del clean["services"][s]

HEADER = ("# Local settings of this Netpicker installation. Docker Compose reads this file\n"
          "# on top of docker-compose.yml; git pull and update.sh leave it as it is.\n"
          "# See docker-compose.override.yml.sample for the settings you can make here.\n")

def write(path, data, header):
    with open(path, "w") as f:
        if not data:
            return
        if header:
            f.write(HEADER)
            if D:
                f.write("# update.sh moved the local edits of the compose files here on %s.\n" % datetime.date.today())
            f.write("\n")
        yaml.dump(data, f, Dumper=Dumper, sort_keys=False, default_flow_style=False, width=1000)

write(out_full, final, not ovr_p)
write(out_clean, clean, not ovr_p)
EOF

# ---------------------------------------------------------------------------
# checks

check_tools() {
    local v err
    section "Docker"
    command -v docker >/dev/null 2>&1 || {
        fail "docker is not installed"
        detail "Install Docker Engine: https://docs.docker.com/engine/install/"
        return 1
    }
    if ! err=$(docker info 2>&1 >/dev/null); then
        case "$err" in
            *permission\ denied*)
                fail "$(id -un) may not use the Docker daemon"
                detail "Add the user to the docker group and log in again, or run update.sh with sudo:"
                detail "  sudo usermod -aG docker $(id -un)"
                ;;
            *) fail "cannot reach the Docker daemon: $(printf '%s\n' "$err" | grep . | tail -n 1)"
               detail "Is Docker running? Try: sudo systemctl start docker" ;;
        esac
        return 1
    fi
    pass "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null) is running"
    if ! v=$(docker compose version --short 2>/dev/null); then
        fail "Docker Compose v2 (the 'docker compose' plugin) is not installed"
        if command -v docker-compose >/dev/null 2>&1; then
            detail "Only the old docker-compose ($(docker-compose version --short 2>/dev/null)) is installed; Netpicker needs v2."
        fi
        detail "Install it with your package manager, e.g. 'sudo apt install docker-compose-plugin'"
        detail "or 'sudo dnf install docker-compose-plugin'."
        return 1
    fi
    COMPOSE_VERSION=${v#v}
    if ! ver_ge "$COMPOSE_VERSION" "$COMPOSE_MIN"; then
        fail "Docker Compose $COMPOSE_VERSION is too old; update.sh needs $COMPOSE_MIN or newer"
        detail "Update the docker-compose-plugin package."
        return 1
    fi
    HAS_RESET=0
    if ver_ge "$COMPOSE_VERSION" "$COMPOSE_RESET"; then
        HAS_RESET=1
        pass "Docker Compose $COMPOSE_VERSION"
    else
        pass "Docker Compose $COMPOSE_VERSION"
        detail "Compose $COMPOSE_RESET or newer can also remove settings in override files; not needed unless you removed settings."
    fi
    command -v git >/dev/null 2>&1 || {
        fail "git is not installed; install it, e.g. 'sudo apt install git' or 'sudo dnf install git'"
        return 1
    }
    command -v curl >/dev/null 2>&1 || info "curl is not installed; skipping the Docker Hub checks"
    return 0
}

# Find the compose project, the compose files it runs with and whether it uses
# the pinned compose file. Sets PROJECT, STACK_FILES, STACK_UP, MODE.
detect_stack() {
    local rows p wd f n plain cf
    section "Netpicker stack"
    rows=$( {
        docker ps -a --filter "label=com.docker.compose.project.working_dir=$DIR" \
            --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.config_files"}}|{{.Label "com.docker.compose.service"}}|{{.State}}'
        [ "$DIR" = "$DIR_P" ] || docker ps -a --filter "label=com.docker.compose.project.working_dir=$DIR_P" \
            --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.config_files"}}|{{.Label "com.docker.compose.service"}}|{{.State}}'
    } | sort -u)
    if [ -z "$PROJECT" ]; then
        PROJECT=$(printf '%s\n' "$rows" | awk -F'|' '$3 == "api" { print $1; exit }')
        [ -n "$PROJECT" ] || PROJECT=$(printf '%s\n' "$rows" | awk -F'|' 'NF { print $1; exit }')
        n=$(printf '%s\n' "$rows" | awk -F'|' 'NF { print $1 }' | sort -u | grep -c .)
        [ "$n" -le 1 ] || warn "$n compose projects run from $DIR; using $PROJECT (choose another with -p)"
    fi
    if [ -z "$PROJECT" ]; then
        # a stack that runs from another directory
        wd=$(docker ps -a --filter label=com.docker.compose.service=api \
            --format '{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Image}}' |
            awk -F'|' '$3 ~ /(^|\/)netpicker\/api/ { print; exit }')
        if [ -n "$wd" ]; then
            p=${wd%%|*}
            wd=${wd#*|}
            wd=${wd%%|*}
            fail "Netpicker (project $p) runs from $wd, not from $DIR"
            detail "Run update.sh in that directory: $wd/update.sh"
            detail "(copy it there if that installation is older than update.sh)"
            return 1
        fi
        PROJECT=$(env_get COMPOSE_PROJECT_NAME)
        [ -n "$PROJECT" ] || PROJECT=$(basename "$DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
        warn "no containers of Netpicker found; the update starts it as project '$PROJECT'"
    fi
    rows=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
        --format '{{.Label "com.docker.compose.config_files"}}{{.Label "com.docker.compose.project.config_files"}}|{{.Label "com.docker.compose.service"}}|{{.State}}|{{.Names}}')
    STACK_UP=$(printf '%s\n' "$rows" | awk -F'|' '$3 == "running"' | grep -c .)
    STACK_FILES=$(printf '%s\n' "$rows" | awk -F'|' '$2 == "api" { print $1; exit }')
    [ -n "$STACK_FILES" ] || STACK_FILES=$(printf '%s\n' "$rows" | awk -F'|' 'NF { print $1; exit }')
    STACK_FILES=$(printf '%s\n' "$STACK_FILES" | tr ',' ':')

    # the files plain 'docker compose' takes in this directory
    cf=$(env_get COMPOSE_FILE)
    if [ -n "$cf" ]; then
        plain=
        local IFS="${COMPOSE_PATH_SEPARATOR:-:}"
        for f in $cf; do
            case "$f" in /*) ;; *) f="$DIR/${f#./}" ;; esac
            plain="$plain${plain:+:}$f"
        done
        unset IFS
    else
        plain="$DIR/$MAIN_FILE"
        [ ! -f "$DIR/$OVERRIDE_FILE" ] || plain="$plain:$DIR/$OVERRIDE_FILE"
    fi
    PLAIN_FILES=$plain
    if [ -z "$STACK_FILES" ]; then
        STACK_FILES=$plain
    else
        # the labels have the physical paths
        STACK_FILES=$(printf '%s\n' "$STACK_FILES" | sed "s#$DIR_P/#$DIR/#g")
    fi
    if [ -n "$rows" ]; then
        info "project '$PROJECT': $STACK_UP of $(printf '%s\n' "$rows" | grep -c .) containers running, started with $(rel_list "$STACK_FILES")"
    fi
    if [ -n "$rows" ] && [ "$STACK_FILES" != "$PLAIN_FILES" ]; then
        info "plain 'docker compose' in $DIR reads $(rel_list "$PLAIN_FILES"); the stack was started with other files (with -f options or COMPOSE_FILE)"
    fi
    MODE=latest
    case ":$STACK_FILES:" in *"/$PINNED_FILE:"*) MODE=pinned ;; esac
    local IFS=:
    for f in $STACK_FILES; do
        [ -f "$f" ] || { unset IFS; fail "the stack was started with $f, which no longer exists"; return 1; }
    done
    unset IFS
    return 0
}

frontend_version() {
    local html
    html=$(docker exec "$1" wget -q -T 5 -O - http://127.0.0.1/ </dev/null 2>/dev/null) || return 1
    printf '%s\n' "$html" | grep -o -i -E 'version[^0-9<]{0,40}[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?' | sed -n 1p |
        grep -o -E '[0-9]+(\.[0-9]+)+(-[0-9A-Za-z.]+)?$'
}

running_version() {
    local c
    c=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=frontend | head -n 1)
    [ -n "$c" ] && frontend_version "$c"
}

# Turn a directory that is not a git clone into one: fetch the repo into a
# git dir in $WORK and find the commit whose compose files are closest to the
# files here. The repo is moved into place by apply_repo.
probe_repo() {
    local probe="$WORK/probe" f c best= best_n= n main
    git init -q "$probe" && git -C "$probe" remote add origin "$REPO_URL" || return 1
    if ! git -C "$probe" fetch -q --tags origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>"$WORK/git.err"; then
        fail "cannot fetch $REPO_URL: $(grep . "$WORK/git.err" | tail -n 1)"
        detail "update.sh needs access to GitHub. Behind a proxy, set it for git with:"
        detail "  git config --global http.proxy http://proxy.example.com:8080"
        return 1
    fi
    main=$MAIN_FILE
    [ "$MODE" != pinned ] || main=$PINNED_FILE
    # the commit whose files differ least from the files here: changed lines,
    # plus files here that the commit does not have (from a later version)
    step "looking for the version of your files in the history of $BRANCH"
    for c in $(git -C "$probe" rev-list --first-parent -n 400 "origin/$BRANCH"); do
        git --git-dir="$probe/.git" --work-tree="$DIR" read-tree "$c" 2>/dev/null || continue
        n=$( {
            git --git-dir="$probe/.git" --work-tree="$DIR" diff --numstat | awk '$3 != "update.sh" { n += ($1 == "-" ? 10 : $1 + $2) } END { print n + 0 }'
            git --git-dir="$probe/.git" --work-tree="$DIR" ls-files --others --exclude-standard | grep -vc -E '(^|/)(update\.sh|\.env|docker-compose\.override\.ya?ml|netpicker_backup.*\.tar)$'
        } | awk '{ n += $1 } END { print n + 0 }')
        if [ -z "$best_n" ] || [ "$n" -lt "$best_n" ]; then
            best=$c best_n=$n
        fi
        [ "$n" -gt 0 ] || break
    done
    [ -n "$best" ] || best=$(git -C "$probe" rev-parse "origin/$BRANCH")
    git -C "$probe" symbolic-ref HEAD "refs/heads/$BRANCH"
    git -C "$probe" update-ref "refs/heads/$BRANCH" "$best"
    GIT_PROBE="$probe/.git"
    g reset -q
    g branch -q --set-upstream-to "origin/$BRANCH" 2>/dev/null
    if [ "$best_n" = 0 ]; then
        info "your files are the ones of commit $(g log -1 --format='%h (%ad, %s)' --date=short "$best")"
    else
        info "your files are closest to commit $(g log -1 --format='%h (%ad, %s)' --date=short "$best"): $best_n line(s) differ"
        if [ "$best_n" -gt 50 ]; then
            warn "your files differ a lot from every version of the repo; check the changes below carefully"
        fi
    fi
    return 0
}

# Sets UP (the upstream ref), BASE (where the local changes start), OLD_HEAD,
# OLD_BRANCH, and the lists of changed files.
check_repo() {
    local up behind ahead branch f url err
    section "Git repository"
    CONVERT=0
    if [ ! -e "$DIR/.git" ]; then
        warn "$DIR is not a git clone of the Netpicker repo, so updates cannot be pulled"
        detail "update.sh can turn it into one: it fetches $REPO_URL and keeps your files;"
        detail "your changes to them are handled below like local edits."
        if ! ask "Turn $DIR into a git clone"; then
            fail "update.sh needs a git clone; or clone the repo into a new directory: git clone $REPO_URL"
            return 1
        fi
        probe_repo || return 1
        CONVERT=1
        plan "turn $DIR into a git clone of $REPO_URL"
    else
        if ! err=$(g rev-parse --git-dir 2>&1 >/dev/null); then
            case "$err" in
                *dubious\ ownership*)
                    fail "git refuses to work in $DIR: the directory belongs to another user"
                    detail "Run update.sh as the owner of $DIR ($(ls -ld "$DIR" | awk '{ print $3 }')), or allow it with:"
                    detail "  git config --global --add safe.directory $DIR"
                    ;;
                *) fail "git does not work in $DIR: $(printf '%s\n' "$err" | tail -n 1)" ;;
            esac
            return 1
        fi
        if [ -e "$(g rev-parse --git-path MERGE_HEAD)" ] || [ -d "$(g rev-parse --git-path rebase-merge)" ] ||
            [ -d "$(g rev-parse --git-path rebase-apply)" ] || [ -e "$(g rev-parse --git-path CHERRY_PICK_HEAD)" ]; then
            fail "a git merge, rebase or cherry-pick is in progress in $DIR (an earlier 'git pull' that stopped?)"
            detail "Finish it, or undo it with 'git merge --abort' or 'git rebase --abort', then run update.sh again."
            g status --short | head -n 10 | details
            return 1
        fi
        url=$(g remote get-url origin 2>/dev/null)
        if [ -z "$url" ]; then
            warn "the repo has no remote 'origin'"
            ask "Add $REPO_URL as origin" || { fail "update.sh needs the remote 'origin' to pull from"; return 1; }
            if [ $DRY_RUN -eq 0 ]; then g remote add origin "$REPO_URL"; else GIT_NO_ORIGIN=1; fi
            url=$REPO_URL
        elif ! printf '%s\n' "$url" | grep -q 'netpicker/netpicker'; then
            info "origin is $url, not $REPO_URL; pulling from it"
        fi
        if [ "${GIT_NO_ORIGIN:-0}" = 1 ]; then
            # dry run without origin: fetch into a copy of the repo
            git clone -q --no-checkout "$DIR" "$WORK/probe" && git -C "$WORK/probe" remote set-url origin "$REPO_URL" || return 1
            GIT_PROBE="$WORK/probe/.git"
            g reset -q "$(git -C "$DIR" rev-parse HEAD)" 2>/dev/null
        fi
        step "git fetch origin (only updates what git knows about origin, not your files)"
        if ! g fetch -q --tags --force origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>"$WORK/git.err"; then
            fail "cannot fetch from $url: $(grep . "$WORK/git.err" | tail -n 1)"
            detail "update.sh needs access to GitHub. Behind a proxy, set it for git with:"
            detail "  git config --global http.proxy http://proxy.example.com:8080"
            return 1
        fi
    fi
    UP="origin/$BRANCH"
    OLD_HEAD=$(g rev-parse HEAD)
    OLD_BRANCH=$(g symbolic-ref --short -q HEAD)
    BASE=$(g merge-base HEAD "$UP")
    read -r behind ahead <<EOF
$(g rev-list --left-right --count "$UP...HEAD")
EOF
    if [ "$OLD_BRANCH" != "$BRANCH" ] && [ $CONVERT -eq 0 ]; then
        info "the repo is on ${OLD_BRANCH:-a detached HEAD ($(g describe --tags --always HEAD))}; the update moves it to $BRANCH, the latest version"
    fi
    if [ "${behind:-0}" -eq 0 ]; then
        pass "the repo is up to date with $UP"
    else
        info "$behind new commit(s) on $UP:"
        g log --format='%h %ad %s' --date=short "HEAD..$UP" | head -n 8 | details
        [ "$behind" -le 8 ] || detail "${C_DIM}... and $((behind - 8)) more${C_RESET}"
    fi
    if [ "${ahead:-0}" -gt 0 ]; then
        warn "$ahead local commit(s) that are not on $UP:"
        g log --format='%h %ad %s' --date=short "$UP..HEAD" | head -n 8 | details
        detail "Their changes are handled below like the edits that are not committed;"
        detail "the commits stay on the branch backup/update-$STAMP."
        plan "keep the local commits on the branch backup/update-$STAMP"
    fi

    # the files that differ from BASE: compose files, other tracked files and
    # untracked files that the update would overwrite. Mode-only changes and
    # line ending changes that git hides do not count.
    CHANGED=$(g diff --numstat "$BASE" -- | awk -F'\t' '$1 != 0 || $2 != 0 { print $3 }')
    DELETED=$(g diff --name-only --diff-filter=D "$BASE" --)
    COMPOSE_CHANGED= OTHER_CHANGED= IN_THE_WAY=
    for f in $CHANGED; do
        case "$f" in
            "$MAIN_FILE" | "$PINNED_FILE") COMPOSE_CHANGED="$COMPOSE_CHANGED $f" ;;
            *) case " $DELETED " in *" $f "*) ;; *) OTHER_CHANGED="$OTHER_CHANGED $f" ;; esac ;;
        esac
    done
    IN_THE_WAY=$(g ls-files --others --exclude-standard | grep -Fx -f <(g diff --name-only --diff-filter=A "$BASE" "$UP") 2>/dev/null)
    if [ -z "$CHANGED$IN_THE_WAY" ]; then
        pass "no local edits of the files of the repo"
    fi
    if [ -n "$DELETED" ]; then
        info "deleted locally, the update restores them: $(echo $DELETED)"
    fi
    for f in $IN_THE_WAY; do
        warn "$f is not in git, but the update adds a file with that name"
        detail "update.sh renames yours to $f.bak.$STAMP"
        plan "rename $f to $f.bak.$STAMP"
    done
    check_other_files
    return 0
}

# Edits of files other than the compose files: merge them into the new version
check_other_files() {
    local f n
    MERGED=
    mkdir -p "$WORK/merge"
    for f in $OTHER_CHANGED; do
        # e.g. update.sh, downloaded before the update
        if g show "$UP:$f" 2>/dev/null | cmp -s - "$DIR/$f"; then
            continue
        fi
        if g diff --quiet "$BASE" "$UP" -- "$f"; then
            info "$f: edited locally; the update does not change it, so your version stays"
            MERGED="$MERGED $f:keep"
            continue
        fi
        if ! g cat-file -e "$UP:$f" 2>/dev/null; then
            info "$f: edited locally; the update deletes it, so it is kept as $f.bak.$STAMP"
            MERGED="$MERGED $f:gone"
            plan "keep your $f as $f.bak.$STAMP (the update deletes it)"
            continue
        fi
        g show "$BASE:$f" >"$WORK/merge/base" 2>/dev/null || : >"$WORK/merge/base"
        g show "$UP:$f" >"$WORK/merge/new"
        cp "$DIR/$f" "$WORK/merge/$(echo "$f" | tr / _).merged"
        git merge-file -q "$WORK/merge/$(echo "$f" | tr / _).merged" "$WORK/merge/base" "$WORK/merge/new"
        n=$?
        if [ $n -eq 0 ]; then
            info "$f: edited locally and changed by the update; your edits merge cleanly into the new version"
            MERGED="$MERGED $f:merge"
            plan "merge your edits of $f into the new version"
        else
            warn "$f: edited locally and changed by the update in the same places"
            detail "The update installs the new version; yours is kept as $f.local.$STAMP to redo your edits."
            MERGED="$MERGED $f:conflict"
            plan "replace your $f with the new version, keeping yours as $f.local.$STAMP"
        fi
    done
}

# compose_json OUT FILES: the compose config of FILES in JSON
compose_json() {
    local out=$1
    shift
    dc "$1" config --format json >"$out" 2>"$WORK/compose.err"
}

# Check the compose files: the switch from pinned to latest, local edits and
# the override file. Sets NEW_FILES and writes the new override to
# $WORK/override.new.
check_compose() {
    local f base_files= cur_files="$STACK_FILES" out kind where what n_add=0 n_manual=0 choice pins ovr= ovr_arg= IFS
    section "Compose files"
    NEW_MAIN=$MAIN_FILE
    if [ "$MODE" = pinned ]; then
        warn "the stack runs $PINNED_FILE: fixed image versions and a fixed database revision"
        detail "With the pinned file an update needs the matching images AND alembic_version; editing"
        detail "the tags by hand and forgetting the alembic_version hash is a common cause of failed updates."
        detail "$MAIN_FILE runs the :latest images and migrates the database to the version of the image."
        if ask "Switch to $MAIN_FILE (latest)"; then
            plan "switch the stack from $PINNED_FILE to $MAIN_FILE (latest images)"
        else
            NEW_MAIN=$PINNED_FILE
            info "staying on $PINNED_FILE; the update installs the versions of its new version"
        fi
    fi

    if ! compose_json "$WORK/cur.json" "$cur_files"; then
        fail "the compose files of the stack are broken: $(grep . "$WORK/compose.err" | tail -n 1)"
        detail "Fix them; 'docker compose config' shows the error."
        return 1
    fi
    check_pinned_revision

    # the stack files as they are in BASE, with the files that are not in the
    # repo (the override, files elsewhere) as they are now
    mkdir -p "$WORK/base"
    IFS=:
    for f in $STACK_FILES; do
        case "$(rel "$f")" in
            "$MAIN_FILE" | "$PINNED_FILE")
                g show "$BASE:$(rel "$f")" >"$WORK/base/$(rel "$f")" 2>/dev/null || cp "$f" "$WORK/base/$(rel "$f")"
                base_files="$base_files${base_files:+:}$WORK/base/$(rel "$f")"
                ;;
            "$OVERRIDE_FILE") ovr=$f ;;
            *) base_files="$base_files${base_files:+:}$f" ;;
        esac
    done
    unset IFS
    # the override goes last, as it does with plain 'docker compose'
    [ -z "$ovr" ] || base_files="$base_files:$ovr"
    if ! compose_json "$WORK/base.json" "$base_files"; then
        fail "cannot read the compose files of commit $(g rev-parse --short "$BASE"): $(grep . "$WORK/compose.err" | tail -n 1)"
        return 1
    fi
    [ -z "$ovr" ] || { cp "$ovr" "$WORK/override.old"; ovr_arg="$WORK/override.old"; }
    out=$(py "$PY_DIFF" "$WORK/base.json" "$WORK/cur.json" "$ovr_arg" "$HAS_RESET" diff \
        "$WORK/override.full" "$WORK/override.clean" 2>"$WORK/py.err") || {
        fail "cannot compare the compose files: $(grep . "$WORK/py.err" | tail -n 1)"
        return 1
    }
    for f in $COMPOSE_CHANGED; do
        case ":$STACK_FILES:" in
            *":$DIR/$f:"*) ;;
            *) info "$f is edited locally but the stack does not use it; the update resets it (a copy is kept in .update/$STAMP)"
               plan "reset $f, which the stack does not use (a copy goes to .update/$STAMP)" ;;
        esac
    done
    n_add=$(printf '%s\n' "$out" | grep -c "^ADD$TAB")
    n_manual=$(printf '%s\n' "$out" | grep -c "^MANUAL$TAB")
    if printf '%s\n' "$out" | grep -q "^\(ADD\|SKIP\|MANUAL\)$TAB"; then
        warn "the compose files of the stack are edited locally; 'git pull' fails or loses these edits:"
        printf '%s\n' "$out" | while IFS="$TAB" read -r kind where what; do
            case "$kind" in
                ADD) detail "${C_BOLD}+${C_RESET} $where: $what" ;;
                SKIP) detail "${C_DIM}- $where: $what${C_RESET}" ;;
                MANUAL) detail "${C_RED}!${C_RESET} $where: $what" ;;
            esac
        done
        detail "+ moves to $OVERRIDE_FILE, - is not needed after the update, ! needs your attention."
    fi
    if [ "$n_add" -gt 0 ]; then
        detail "Keep local settings in $OVERRIDE_FILE: Docker Compose reads it on top of the"
        detail "compose file, and git pull leaves it alone. This would be the new $OVERRIDE_FILE:"
        sed 's/^/  | /' "$WORK/override.full" | details
        choice=$(choose "Move your edits to $OVERRIDE_FILE" m \
            "m=move them to $OVERRIDE_FILE (recommended)" \
            "d=discard them (a copy of the files is kept in .update/$STAMP)" \
            "a=abort the update")
        case "$choice" in
            m) MOVE_EDITS=1; plan "move your edits of the compose files to $OVERRIDE_FILE" ;;
            d) MOVE_EDITS=0; plan "discard your edits of the compose files (a copy goes to .update/$STAMP)" ;;
            *) fail "aborted: keep your edits in $OVERRIDE_FILE yourself and run update.sh again"; return 1 ;;
        esac
    fi
    if [ "$n_manual" -gt 0 ]; then
        warn "$n_manual edit(s) marked ! cannot move to $OVERRIDE_FILE with Docker Compose $COMPOSE_VERSION"
        detail "After the update, redo them in $DIR/$OVERRIDE_FILE by hand, or update Docker Compose"
        detail "to $COMPOSE_RESET or newer and run update.sh again. The old files are kept in .update/$STAMP."
    fi

    # settings in the override that hold the update back
    cp "$WORK/override.full" "$WORK/override.new"
    [ "${MOVE_EDITS:-1}" = 1 ] || { if [ -n "$ovr" ]; then cp "$ovr" "$WORK/override.new"; else : >"$WORK/override.new"; fi; }
    pins=$(printf '%s\n' "$out" | grep "^PIN$TAB")
    if [ -n "$pins" ]; then
        warn "$OVERRIDE_FILE sets what the update must change:"
        printf '%s\n' "$pins" | while IFS="$TAB" read -r kind where what; do
            detail "$where: $what"
        done
        detail "Images pinned to a version stay on that version, a pinned alembic_version holds back"
        detail "the database, and group_add is set with DOCKER_GID in .env now."
        if ask "Remove these settings from $OVERRIDE_FILE"; then
            if [ "${MOVE_EDITS:-1}" = 1 ]; then
                cp "$WORK/override.clean" "$WORK/override.new"
            else
                # only the pins of the existing override
                py "$PY_DIFF" "$WORK/base.json" "$WORK/base.json" "$ovr_arg" "$HAS_RESET" diff \
                    "$WORK/override.x" "$WORK/override.new" >/dev/null 2>&1
            fi
            plan "remove the pinned settings from $OVERRIDE_FILE"
        else
            warn "the override keeps the pinned settings; the update may not change what they pin"
        fi
    fi
    if [ -n "$ovr" ] && cmp -s "$ovr" "$WORK/override.new"; then
        NEW_OVERRIDE=0
    elif [ -z "$ovr" ] && [ ! -s "$WORK/override.new" ]; then
        NEW_OVERRIDE=0
    else
        NEW_OVERRIDE=1
    fi

    # the files after the update: the new main file in place of the old one
    NEW_FILES=
    IFS=:
    for f in $STACK_FILES; do
        case "$(rel "$f")" in
            "$MAIN_FILE" | "$PINNED_FILE") f="$DIR/$NEW_MAIN" ;;
            "$OVERRIDE_FILE") continue ;;
        esac
        case ":$NEW_FILES:" in *":$f:"*) ;; *) NEW_FILES="$NEW_FILES${NEW_FILES:+:}$f" ;; esac
    done
    unset IFS
    if [ -n "$ovr" ] || [ -s "$WORK/override.new" ]; then
        NEW_FILES="$NEW_FILES:$DIR/$OVERRIDE_FILE"
    fi

    # check the new compose config with the new compose files and override
    mkdir -p "$WORK/new"
    local new_test=
    IFS=:
    for f in $NEW_FILES; do
        case "$(rel "$f")" in
            "$MAIN_FILE" | "$PINNED_FILE") g show "$UP:$(rel "$f")" >"$WORK/new/$(rel "$f")"; f="$WORK/new/$(rel "$f")" ;;
            "$OVERRIDE_FILE") f="$WORK/override.new" ;;
        esac
        new_test="$new_test${new_test:+:}$f"
    done
    unset IFS
    if [ ! -s "$WORK/override.new" ]; then
        new_test=$(printf '%s\n' "$new_test" | sed "s#:$WORK/override.new##")
    fi
    if ! compose_json "$WORK/new.json" "$new_test"; then
        fail "the compose config after the update would be broken: $(grep . "$WORK/compose.err" | tail -n 1)"
        detail "Check $OVERRIDE_FILE; the new version may have changed what it overrides."
        return 1
    fi
    if [ "$n_add" -gt 0 ] && [ "${MOVE_EDITS:-1}" = 1 ]; then
        # the old compose files with the new override must give what runs now
        local check_files=
        IFS=:
        for f in $base_files; do
            [ "$f" = "$ovr" ] || check_files="$check_files${check_files:+:}$f"
        done
        unset IFS
        check_files="$check_files:$WORK/override.full"
        if compose_json "$WORK/check.json" "$check_files"; then
            out=$(py "$PY_DIFF" "$WORK/check.json" "$WORK/cur.json" "" 1 residual "$WORK/x" "$WORK/y" 2>/dev/null)
            if [ -z "$out" ]; then
                pass "$OVERRIDE_FILE reproduces the edited compose files"
            else
                warn "$OVERRIDE_FILE cannot reproduce all edits:"
                printf '%s\n' "$out" | cut -f2- | tr "$TAB" ' ' | details
            fi
        fi
    fi
    pass "the compose config after the update is valid ($(rel_list "$NEW_FILES"))"
    local plain_new="$DIR/$MAIN_FILE"
    { [ -f "$DIR/$OVERRIDE_FILE" ] || [ -s "$WORK/override.new" ]; } && plain_new="$plain_new:$DIR/$OVERRIDE_FILE"
    if [ "$NEW_FILES" = "$plain_new" ]; then
        if [ -n "$(env_get COMPOSE_FILE)" ]; then
            SET_COMPOSE_FILE=-
            plan "remove COMPOSE_FILE from .env, so plain 'docker compose' runs $MAIN_FILE"
        fi
    else
        SET_COMPOSE_FILE=$(rel_list "$NEW_FILES" | sed 's/, /:/g')
        if [ "$(env_get COMPOSE_FILE)" != "$SET_COMPOSE_FILE" ]; then
            info "plain 'docker compose' reads $(rel_list "$plain_new"), not the files of the stack"
            if ask "Set COMPOSE_FILE=$SET_COMPOSE_FILE in .env, so plain 'docker compose' (and up.sh) runs the right files"; then
                plan "set COMPOSE_FILE=$SET_COMPOSE_FILE in .env"
            else
                SET_COMPOSE_FILE=
                info "remember to give these files with -f to every docker compose command"
            fi
        else
            SET_COMPOSE_FILE=
        fi
    fi
    return 0
}

# A pinned alembic_version that is not the head of the api image: the tags
# were edited without the hash, so the database stays at an older revision
check_pinned_revision() {
    local want img head rev
    want=$(py "$PY_FACTS" "$WORK/cur.json" | sed -n 's/^A|//p')
    case "$want" in '' | head) return 0 ;; esac
    img=$(py "$PY_FACTS" "$WORK/cur.json" | awk -F'|' '$1 == "S" && $2 == "api" { print $3 }')
    docker image inspect "$img" >/dev/null 2>&1 || return 0
    head=$(alembic_head "$img")
    [ -n "$head" ] && [ "$head" != "$want" ] || return 0
    rev=$(dc "$STACK_FILES" exec -T db psql -U netpicker -d netpicker -tAc 'SELECT version_num FROM alembic_version' 2>/dev/null | tr -d '[:space:]')
    warn "alembic_version is pinned to $want, but the api image $img expects revision $head"
    detail "The image tags were changed without the alembic_version hash, so db_migration keeps the"
    detail "database at ${rev:-$want} and the api runs against a database it was not made for."
    detail "The update fixes this: the compose file of the new version sets both together."
}

# The group of the docker socket for group_add of the api
check_socket() {
    local src gid img configured want
    section "Docker socket"
    src=$(py "$PY_FACTS" "$WORK/new.json" | sed -n 's/^K|//p' | head -n 1)
    if [ -z "$src" ]; then
        info "the api does not mount the docker socket; skipped"
        return 0
    fi
    img=$(py "$PY_FACTS" "$WORK/cur.json" | awk -F'|' '$1 == "S" && $2 == "api" { print $3 }')
    docker image inspect "$img" >/dev/null 2>&1 || img=$PY_IMAGE
    [ -n "$img" ] || img=$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '(^|/)netpicker/' | head -n 1)
    # the group as the containers see it, which is what counts with Docker
    # Desktop and user namespaces too
    gid=
    [ -z "$img" ] || gid=$(docker run --rm --network none -v "$src:/docker.sock" --entrypoint stat "$img" -c %g /docker.sock 2>/dev/null)
    [ -n "$gid" ] || gid=$(stat -L -c %g "$src" 2>/dev/null || stat -L -f %g "$src" 2>/dev/null)
    if [ -z "$gid" ]; then
        warn "cannot tell the group of the docker socket $src"
        return 0
    fi
    configured=$(py "$PY_FACTS" "$WORK/new.json" | sed -n 's/^G|//p')
    if ! grep -q 'DOCKER_GID' "$WORK/new/$NEW_MAIN" 2>/dev/null; then
        want=
    else
        want=$gid
    fi
    case ",$configured," in
        *",$gid,"*)
            pass "the api can use the docker socket: its group $gid is in group_add"
            ;;
        *)
            if [ "$gid" = 0 ] && [ -z "$want" ]; then
                pass "the docker socket belongs to group 0"
            elif [ -n "$want" ]; then
                warn "the docker socket belongs to group $gid, but group_add of the api is ${configured:-empty}"
                detail "Without it the api cannot use the docker socket and fails to manage the agents."
                if ask "Set DOCKER_GID=$gid in .env"; then
                    SET_GID=$gid
                    plan "set DOCKER_GID=$gid in .env (group_add of the api)"
                else
                    warn "group_add stays ${configured:-empty}"
                fi
            else
                warn "the docker socket belongs to group $gid, but group_add of the api is ${configured:-empty}"
                detail "Set group_add of the api to \"$gid\" in $OVERRIDE_FILE."
            fi
            ;;
    esac
    return 0
}

# registry_digest IMAGE: print the digest of IMAGE on Docker Hub and set
# RATE_REMAINING; fails for other registries or without curl
RATE_REMAINING=
registry_digest() {
    local ref=$1 repo tag token headers
    command -v curl >/dev/null 2>&1 || return 1
    repo=$(image_repo "$ref")
    tag=$(image_tag "$ref")
    case "$tag" in sha256:*) return 1 ;; esac
    case "$repo" in
        docker.io/*) repo=${repo#docker.io/} ;;
        */*/* | *.*/* | *:*/* | localhost/*) return 1 ;;
    esac
    case "$repo" in */*) ;; *) repo="library/$repo" ;; esac
    token=$(curl -fsS --max-time 10 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" 2>/dev/null |
        sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    [ -n "$token" ] || return 2
    headers=$(curl -fsSI --max-time 10 -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
        "https://registry-1.docker.io/v2/$repo/manifests/$tag" 2>/dev/null | tr -d '\r') || return 2
    RATE_REMAINING=$(printf '%s\n' "$headers" | sed -n 's/^[Rr]ate[Ll]imit-[Rr]emaining: *\([0-9]*\).*/\1/p')
    printf '%s\n' "$headers" | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p'
}

# The images: which are outdated and whether the containers run them
check_images() {
    local rows svc img ctr id cid digest remote stale= current= unknown= notrun= reach=1 n=0 ver
    section "Images"
    rows=$(py "$PY_FACTS" "$WORK/new.json" | awk -F'|' '$1 == "S" { print $2 "|" $3 }')
    IMAGES=$(printf '%s\n' "$rows" | cut -d'|' -f2 | sort -u | grep .)
    for img in $IMAGES; do
        n=$((n + 1))
        id=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)
        remote=
        if [ $reach -eq 1 ]; then
            remote=$(registry_digest "$img")
            case $? in 2) reach=0; remote= ;; esac
        fi
        if [ -z "$id" ]; then
            stale="$stale $img(not pulled yet)"
        elif [ -n "$remote" ]; then
            if docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$img" 2>/dev/null | grep -q "@$remote$"; then
                current="$current $img"
            else
                stale="$stale $img"
            fi
        else
            unknown="$unknown $img"
        fi
    done
    # containers that do not run the image their tag points to (pulled, but
    # not recreated)
    while IFS='|' read -r svc img; do
        [ -n "$svc" ] || continue
        cid=$(docker ps -a -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$svc" | head -n 1)
        [ -n "$cid" ] || continue
        ctr=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)
        id=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)
        [ -z "$id" ] || [ "$ctr" = "$id" ] || notrun="$notrun $svc"
    done <<EOF
$(py "$PY_FACTS" "$WORK/cur.json" | awk -F"|" '$1 == "S" { print $2 "|" $3 }')
EOF
    ver=$(running_version)
    [ -z "$ver" ] || info "Netpicker $ver runs now"
    [ -z "$current" ] || pass "up to date with Docker Hub: $(echo $current | sed 's/ /, /g')"
    if [ -n "$stale" ]; then
        info "the update pulls newer images: $(echo $stale | sed 's/ /, /g')"
        case "$stale" in
            *netpicker/*)
                if [ -n "$(echo $current | tr ' ' '\n' | grep 'netpicker/' | grep -v 'netpicker/\(db\|minio\)')" ]; then
                    warn "some Netpicker images are up to date and others not: they were not pulled together"
                    detail "The images of one version belong together; the update pulls all of them."
                fi
                ;;
        esac
    fi
    [ -z "$unknown" ] || info "cannot compare with the registry: $(echo $unknown | sed 's/ /, /g')"
    if [ -n "$notrun" ]; then
        warn "containers that run an older image than the one pulled: $(echo $notrun | sed 's/ /, /g')"
        detail "Images were pulled without recreating the containers; the update recreates all of them."
    fi
    [ $reach -eq 1 ] || REGISTRY_DOWN=1
    return 0
}

check_registry() {
    local mirrors proxy
    section "Registry"
    if ! command -v curl >/dev/null 2>&1; then
        info "curl is not installed; the pull shows whether Docker Hub is reachable"
        return 0
    fi
    mirrors=$(docker info -f '{{range .RegistryConfig.Mirrors}}{{.}} {{end}}' 2>/dev/null)
    proxy=$(docker info -f '{{.HTTPSProxy}}' 2>/dev/null)
    if [ "${REGISTRY_DOWN:-0}" = 1 ]; then
        if [ -n "$mirrors$proxy" ]; then
            info "this host cannot reach Docker Hub directly; Docker pulls through ${mirrors:+mirror $mirrors}${proxy:+proxy $proxy}"
        else
            warn "cannot reach Docker Hub (registry-1.docker.io) from this host"
            detail "The images are pulled before Netpicker stops, so a failing pull leaves it running."
            detail "Behind a proxy, configure it for Docker: https://docs.docker.com/engine/daemon/proxy/"
        fi
        return 0
    fi
    pass "Docker Hub is reachable"
    if [ -n "$RATE_REMAINING" ]; then
        if [ "$RATE_REMAINING" -lt "$(printf '%s\n' "$IMAGES" | grep -c .)" ]; then
            warn "only $RATE_REMAINING pulls left in the Docker Hub rate limit of this IP address"
            detail "Log in to raise the limit: docker login (any free Docker Hub account)."
        else
            pass "$RATE_REMAINING pulls left in the Docker Hub rate limit of this IP address"
        fi
    fi
    return 0
}

# volumes_kib VOLUME...: their size in KiB, from 'docker system df -v'
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

check_disk() {
    local root images_kib=0 img s avail vols vols_kib backups f
    section "Disk space"
    for img in $IMAGES; do
        s=$(docker image inspect -f '{{.Size}}' "$img" 2>/dev/null) || continue
        images_kib=$((images_kib + s / 1024))
    done
    # the new images need about as much as the old ones; less with shared layers
    root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
    if [ -n "$root" ] && [ -d "$root" ]; then
        avail=$(df -Pk "$root" 2>/dev/null | awk 'NR == 2 { print $4 }')
        if [ -n "$avail" ]; then
            if [ "$avail" -lt "$images_kib" ]; then
                fail "only $(human_kib "$avail") free for Docker in $root; the new images need up to $(human_kib "$images_kib")"
                offer_prune || return 0
            elif [ "$avail" -lt $((images_kib + 2097152)) ]; then
                warn "$(human_kib "$avail") free for Docker in $root; the new images need up to $(human_kib "$images_kib")"
                offer_prune
            else
                pass "$(human_kib "$avail") free for Docker in $root (the new images need up to $(human_kib "$images_kib"))"
            fi
        fi
    else
        info "the Docker data directory is not on this host (Docker Desktop?); skipped its free space"
    fi
    vols=$( {
        docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT"
        docker volume ls -q | grep "^${PROJECT}_"
    } | sort -u)
    if [ -z "$vols" ]; then
        info "no volumes yet, nothing to back up"
        return 0
    fi
    # shellcheck disable=SC2086
    vols_kib=$(volumes_kib $vols)
    avail=$(df -Pk "$DIR" | awk 'NR == 2 { print $4 }')
    if [ "$avail" -lt $((vols_kib + vols_kib / 10 + 102400)) ]; then
        fail "only $(human_kib "$avail") free in $DIR; the backup of the volumes needs $(human_kib "$vols_kib")"
        # shellcheck disable=SC2012
        backups=$(ls -t "$DIR"/netpicker_backup*.tar 2>/dev/null)
        if [ -n "$backups" ]; then
            detail "Old backups take space here:"
            for f in $backups; do detail "  $(basename "$f") ($(du -h "$f" | cut -f1))"; done
            detail "Delete the ones you do not need; ./update.sh --cleanup deletes all but the last."
        fi
    else
        pass "$(human_kib "$avail") free in $DIR for the backup ($(human_kib "$vols_kib"))"
    fi
    return 0
}

offer_prune() {
    local reclaim
    reclaim=$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null | awk -F'|' '$1 == "Images" { print $2 }')
    detail "Unused images can take space: ${reclaim:-unknown} reclaimable."
    if ask "Remove the images that no container uses (docker image prune -a)" n; then
        if [ $DRY_RUN -eq 0 ]; then
            docker image prune -a -f | tail -n 1 | details
            N_FAIL=$((N_FAIL > 0 ? N_FAIL - 1 : 0))
        fi
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# the update

save_state() {
    local f img id tag
    mkdir -p "$STATE/files" || die "cannot create $STATE"
    {
        echo "PROJECT=$PROJECT"
        echo "OLD_HEAD=$OLD_HEAD"
        echo "OLD_BRANCH=$OLD_BRANCH"
        echo "OLD_FILES=$STACK_FILES"
        echo "NEW_FILES=$NEW_FILES"
        echo "CONVERT=$CONVERT"
    } >"$STATE/meta"
    # the files the update changes, as they are now
    for f in $COMPOSE_CHANGED $OTHER_CHANGED $IN_THE_WAY .env "$OVERRIDE_FILE" "$MAIN_FILE" "$PINNED_FILE"; do
        [ -f "$DIR/$f" ] || continue
        mkdir -p "$STATE/files/$(dirname "$f")"
        cp -p "$DIR/$f" "$STATE/files/$f"
    done
    [ -f "$DIR/.env" ] || touch "$STATE/no-env"
    [ -f "$DIR/$OVERRIDE_FILE" ] || touch "$STATE/no-override"
    # tag the images that run now, so a rollback can go back to them
    : >"$STATE/images"
    for img in $(py "$PY_FACTS" "$WORK/cur.json" | awk -F'|' '$1 == "S" { print $3 }' | sort -u); do
        id=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null) || continue
        case "$img" in *@*) continue ;; esac
        tag="$(image_repo "$img"):pre-update-$STAMP"
        docker tag "$id" "$tag" && echo "$img|$id|$tag" >>"$STATE/images"
    done
}

apply_repo() {
    local f how
    step "updating the files of the repo"
    if [ $CONVERT -eq 1 ]; then
        mv "$WORK/probe/.git" "$DIR/.git" || die "cannot move the git repo into $DIR"
        GIT_PROBE=
    fi
    for f in $IN_THE_WAY; do
        mv "$DIR/$f" "$DIR/$f.bak.$STAMP"
    done
    if [ "$(g rev-list --count "$UP..HEAD")" -gt 0 ]; then
        g branch -f "backup/update-$STAMP" HEAD
    fi
    if ! g checkout -q -f -B "$BRANCH" "$UP" 2>"$WORK/git.err"; then
        fail "git checkout failed: $(tail -n 1 "$WORK/git.err")"
        return 1
    fi
    g branch -q --set-upstream-to "$UP" 2>/dev/null
    for how in $MERGED; do
        f=${how%:*}
        case "$how" in
            *:keep) put_file "$STATE/files/$f" "$DIR/$f" ;;
            *:gone) put_file "$STATE/files/$f" "$DIR/$f.bak.$STAMP" ;;
            *:merge) put_file "$WORK/merge/$(echo "$f" | tr / _).merged" "$DIR/$f" ;;
            *:conflict) put_file "$STATE/files/$f" "$DIR/$f.local.$STAMP" ;;
        esac
    done
    if [ "$NEW_OVERRIDE" = 1 ]; then
        if [ -s "$WORK/override.new" ]; then
            cat "$WORK/override.new" >"$DIR/$OVERRIDE_FILE"
        else
            rm -f "$DIR/$OVERRIDE_FILE"
        fi
    fi
    if [ "$SET_COMPOSE_FILE" = - ]; then
        env_unset COMPOSE_FILE
    elif [ -n "$SET_COMPOSE_FILE" ]; then
        env_set COMPOSE_FILE "$SET_COMPOSE_FILE"
    fi
    [ -z "$SET_GID" ] || env_set DOCKER_GID "$SET_GID"
    pass "the repo is at $(g log -1 --format='%h %s')"
}

# restore the files and the git checkout of before the update
restore_files() {
    local f
    [ -f "$STATE/meta" ] || return 1
    # shellcheck disable=SC1091
    . "$STATE/meta"
    if [ "$CONVERT" = 1 ]; then
        rm -rf "$DIR/.git"
    elif [ -n "$OLD_BRANCH" ]; then
        g checkout -q -f -B "$OLD_BRANCH" "$OLD_HEAD"
    else
        g checkout -q -f --detach "$OLD_HEAD"
    fi
    (cd "$STATE/files" && find . -type f) | while IFS= read -r f; do
        f=${f#./}
        put_file "$STATE/files/$f" "$DIR/$f"
    done
    [ ! -f "$STATE/no-env" ] || rm -f "$DIR/.env"
    [ ! -f "$STATE/no-override" ] || rm -f "$DIR/$OVERRIDE_FILE"
}

restore_images() {
    local img id tag
    while IFS='|' read -r img id tag; do
        [ -n "$img" ] || continue
        docker tag "$tag" "$img" 2>/dev/null || docker tag "$id" "$img"
    done <"$STATE/images"
}

# wait until the services of the stack are healthy: running, and healthy when
# they have a health check; one-shot services exited with 0
wait_healthy() {
    local files=$1 start now rows bad waiting svcs s state health code line last=
    start=$(date +%s)
    svcs=$(dc "$files" config --services 2>/dev/null)
    while :; do
        rows=$(dc "$files" ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}' 2>/dev/null)
        bad= waiting=
        for s in $svcs; do
            line=$(printf '%s\n' "$rows" | awk -F'|' -v s="$s" '$1 == s { print; exit }')
            IFS='|' read -r _ state health code <<EOF
$line
EOF
            case "$state/$health" in
                running/healthy | running/) ;;
                exited/*)
                    if [ "$s" = db_migration ] && [ "$code" = 0 ]; then :; else bad="$bad $s(exited $code)"; fi ;;
                restarting/*) waiting="$waiting $s(restarting)" ;;
                running/*) waiting="$waiting $s($health)" ;;
                *) waiting="$waiting $s(${state:-no container})" ;;
            esac
        done
        case "$bad" in *db_migration*) WAIT_BAD=$bad; return 1 ;; esac
        if [ -z "$bad$waiting" ]; then
            return 0
        fi
        now=$(date +%s)
        if [ $((now - start)) -ge "$TIMEOUT" ]; then
            WAIT_BAD="$bad$waiting"
            return 1
        fi
        if [ "$waiting$bad" != "$last" ]; then
            detail "${C_DIM}$((now - start))s, waiting for:$waiting$bad${C_RESET}"
            last="$waiting$bad"
        fi
        sleep 5
    done
}

# alembic heads of an api image
alembic_head() {
    docker run --rm --network none --entrypoint sh "$1" -c 'cd /opt && alembic heads' 2>/dev/null |
        awk '/\(head\)/ { print $1 }'
}

verify_stack() {
    local files=$1 api_img head want rev img svc cid ctr id ok=0 ver
    api_img=$(dc "$files" config --format json 2>/dev/null >"$WORK/final.json" && py "$PY_FACTS" "$WORK/final.json" | awk -F'|' '$1 == "S" && $2 == "api" { print $3 }')
    want=$(py "$PY_FACTS" "$WORK/final.json" | sed -n 's/^A|//p')
    head=$(alembic_head "$api_img")
    [ "$want" = head ] || [ -z "$want" ] || head=$want
    rev=$(dc "$files" exec -T db psql -U netpicker -d netpicker -tAc 'SELECT version_num FROM alembic_version' 2>/dev/null | tr -d '[:space:]')
    if [ -z "$rev" ]; then
        info "cannot read the revision of the database; skipped"
    elif [ "$rev" = "$head" ]; then
        pass "the database is at revision $rev, the one of the api image"
    else
        fail "the database is at revision $rev, the api image expects ${head:-unknown}"
        ok=1
    fi
    if dc "$files" exec -T api python3 -c "import socket; s = socket.socket(socket.AF_UNIX); s.connect('/var/run/docker.sock')" >/dev/null 2>&1; then
        pass "the api can use the docker socket"
    elif dc "$files" exec -T api test -S /var/run/docker.sock 2>/dev/null; then
        fail "the api cannot use the docker socket: permission denied"
        detail "Set DOCKER_GID in .env to the group of /var/run/docker.sock (stat -L -c %g /var/run/docker.sock)"
        ok=1
    fi
    py "$PY_FACTS" "$WORK/final.json" | awk -F'|' '$1 == "S" { print $2 "|" $3 }' >"$WORK/final.images"
    while IFS='|' read -r svc img; do
        cid=$(dc "$files" ps -a -q "$svc" 2>/dev/null | head -n 1)
        [ -n "$cid" ] || continue
        ctr=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)
        id=$(docker image inspect -f '{{.Id}}' "$img" 2>/dev/null)
        [ "$ctr" = "$id" ] || { fail "$svc does not run the pulled image $img"; ok=1; }
    done <"$WORK/final.images"
    ver=$(running_version)
    [ -z "$ver" ] || pass "Netpicker $ver runs"
    return $ok
}

show_failure() {
    local files=$1 s
    fail "the new version did not come up:$WAIT_BAD"
    for s in $WAIT_BAD; do
        s=${s%%(*}
        detail "${C_BOLD}last log lines of $s:${C_RESET}"
        dc "$files" logs --no-color --tail 15 "$s" 2>&1 | cut -c1-200 | details
    done
    detail "./troubleshoot.sh checks the whole stack; ./troubleshoot.sh -b writes a support bundle"
    detail "to send to support@netpicker.io."
}

rollback() {
    local backup
    section "Rollback"
    # shellcheck disable=SC1091
    . "$STATE/meta"
    step "stopping the new version"
    dc "$NEW_FILES" down --remove-orphans 2>&1 | tail -n 2 | details
    backup=$(cat "$STATE/backup" 2>/dev/null)
    if [ -n "$backup" ] && [ -f "$backup" ]; then
        detail "The new version may have migrated the database already; the old version needs the"
        detail "database of before the update, from the backup $(basename "$backup")."
        if ask "Restore the volumes from $(basename "$backup")"; then
            # restore.sh of the new version, before the old files come back
            cp "$DIR/restore.sh" "$WORK/restore.sh"
            bash "$WORK/restore.sh" -y --no-stop -p "$PROJECT" "$backup" 2>&1 | details ||
                { fail "the restore failed"; return 1; }
        fi
    fi
    step "restoring the files and the images of before the update"
    restore_files
    restore_images
    step "starting the old version"
    dc "$OLD_FILES" up -d --remove-orphans 2>&1 | tail -n 3 | details
    if wait_healthy "$OLD_FILES"; then
        pass "the old version runs again"
        echo rolled-back >"$STATE/status"
        return 0
    fi
    show_failure "$OLD_FILES"
    return 1
}

do_rollback() {
    local s
    if [ -n "$ROLLBACK_STAMP" ]; then
        STATE="$STATE_ROOT/$ROLLBACK_STAMP"
    else
        # shellcheck disable=SC2012
        s=$(ls -1 "$STATE_ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | tail -n 1)
        STATE="$STATE_ROOT/$s"
    fi
    [ -n "$STATE" ] && [ -f "$STATE/meta" ] || die "no update to roll back in $STATE_ROOT"
    # shellcheck disable=SC1091
    . "$STATE/meta"
    [ -n "$PROJECT" ] || die "no project name in $STATE/meta"
    info "rolling back the update of $(basename "$STATE") (project $PROJECT, git $OLD_HEAD)"
    [ "$(cat "$STATE/status" 2>/dev/null)" != rolled-back ] || warn "this update was rolled back already"
    ask "Roll back: stop Netpicker and start the version of before the update" || exit 0
    rollback && exit 0
    exit 2
}

do_cleanup() {
    local dirs last d img id tag backup
    # shellcheck disable=SC2012
    dirs=$(ls -1 "$STATE_ROOT" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort)
    last=$(printf '%s\n' "$dirs" | tail -n 1)
    dirs=$(printf '%s\n' "$dirs" | grep -vx "$last")
    if [ -z "$dirs" ]; then
        info "nothing to clean up; the rollback data of the last update ($last) stays"
        exit 0
    fi
    info "rollback data of these updates: $(echo $dirs)"
    for d in $dirs; do
        backup=$(cat "$STATE_ROOT/$d/backup" 2>/dev/null)
        [ -z "$backup" ] || [ ! -f "$backup" ] || detail "$(basename "$backup") ($(du -h "$backup" | cut -f1))"
    done
    ask "Delete the backups, the old image tags and .update/<stamp> of these updates" n || exit 0
    for d in $dirs; do
        while IFS='|' read -r img id tag; do
            [ -z "$tag" ] || docker rmi "$tag" >/dev/null 2>&1
        done <"$STATE_ROOT/$d/images"
        backup=$(cat "$STATE_ROOT/$d/backup" 2>/dev/null)
        [ -z "$backup" ] || rm -f "$backup"
        rm -rf "${STATE_ROOT:?}/$d"
    done
    # backups that update.sh did not make stay
    pass "deleted the rollback data of $(echo $dirs | wc -w | tr -d ' ') update(s)"
    exit 0
}

run_update() {
    local backup
    section "Update"
    step "saving the state for a rollback in .update/$STAMP"
    save_state
    apply_repo || { restore_files; return 2; }
    if ! dc "$NEW_FILES" config -q 2>"$WORK/compose.err"; then
        fail "the new compose config is broken: $(grep . "$WORK/compose.err" | tail -n 1)"
        restore_files
        info "restored the files of before the update; Netpicker runs as before"
        return 2
    fi
    step "pulling the images (Netpicker keeps running)"
    if ! dc "$NEW_FILES" pull 2>&1 | grep -v -E 'Pulling fs layer|Waiting|Downloading|Extracting|Verifying|Download complete|Pull complete|Already exists' | tail -n 20 | details; then
        fail "pulling the images failed"
        if ask "Restore the files of before the update (Netpicker still runs the old version)"; then
            restore_files
            restore_images
        fi
        return 2
    fi
    # the pull can fail for one image without failing the pipe above
    local img missing=
    for img in $(py "$PY_FACTS" "$WORK/new.json" | awk -F'|' '$1 == "S" { print $3 }' | sort -u); do
        docker image inspect "$img" >/dev/null 2>&1 || missing="$missing $img"
    done
    if [ -n "$missing" ]; then
        fail "images missing after the pull:$missing"
        restore_files
        restore_images
        return 2
    fi
    pass "pulled all images"
    local api_img head want
    api_img=$(py "$PY_FACTS" "$WORK/new.json" | awk -F'|' '$1 == "S" && $2 == "api" { print $3 }')
    head=$(alembic_head "$api_img")
    want=$(py "$PY_FACTS" "$WORK/new.json" | sed -n 's/^A|//p')
    if [ -n "$head" ]; then
        if [ "$want" = head ] || [ "$want" = "$head" ]; then
            pass "alembic_version is $want, the api image migrates the database to $head"
        else
            fail "alembic_version is $want, but the head of the api image is $head"
            detail "db_migration would migrate the database to a revision the api does not expect."
            restore_files
            restore_images
            info "restored the files of before the update; Netpicker runs as before"
            return 2
        fi
    fi

    step "stopping Netpicker"
    dc "$STACK_FILES" down --remove-orphans 2>&1 | tail -n 2 | details
    step "backing up the volumes"
    backup="$DIR/netpicker_backup-$STAMP.tar"
    if [ -z "$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")$(docker volume ls -q | grep "^${PROJECT}_")" ]; then
        info "no volumes yet, nothing to back up"
    elif "$DIR/backup.sh" --no-stop -y -p "$PROJECT" -o "$backup" 2>&1 | details; then
        echo "$backup" >"$STATE/backup"
    else
        fail "the backup failed"
        if ask "Start the old version again (and update later)"; then
            restore_files
            restore_images
            [ "$STACK_UP" -eq 0 ] || dc "$STACK_FILES" up -d 2>&1 | tail -n 3 | details
            return 2
        fi
        ask "Update without a backup" n || return 2
    fi
    step "starting the new version"
    dc "$NEW_FILES" up -d --remove-orphans 2>&1 | grep -v -E '^ *(Container|Network|Volume) .* (Created|Creating|Starting|Started|Waiting|Healthy)$' | tail -n 10 | details
    step "waiting for the services to become healthy (up to ${TIMEOUT}s)"
    if wait_healthy "$NEW_FILES" && verify_stack "$NEW_FILES"; then
        echo ok >"$STATE/status"
        return 0
    fi
    [ -z "$WAIT_BAD" ] || show_failure "$NEW_FILES"
    echo failed >"$STATE/status"
    if ask "Roll back to the version of before the update" "$([ $ASSUME_YES -eq 1 ] && echo n || echo y)"; then
        rollback
    else
        info "roll back later with: ./update.sh --rollback $STAMP"
    fi
    return 2
}

main() {
    local rc
    if [ $DRY_RUN -eq 0 ] && [ $ASSUME_YES -eq 0 ] && ! { : </dev/tty; } 2>/dev/null; then
        die "update.sh asks questions; run it in a terminal, or with --yes or --dry-run"
    fi
    say "${C_BOLD}Netpicker update${C_RESET}$([ $DRY_RUN -eq 0 ] || echo " (dry run: changes nothing)") in $DIR"
    [ $ROLLBACK -eq 0 ] || { check_tools >/dev/null || die "Docker does not work"; do_rollback; }
    [ $CLEANUP -eq 0 ] || do_cleanup

    check_tools || finish
    detect_stack || finish
    check_repo || finish
    check_compose || finish
    check_socket
    check_images
    check_registry
    check_disk

    section "Plan"
    if [ $N_FAIL -gt 0 ]; then
        fail "$N_FAIL problem(s) above need a fix first; nothing was changed"
        finish
    fi
    printf '%s' "$PLAN" | sed 's/^/  - /'
    say "  - pull all images, while Netpicker keeps running"
    say "  - stop Netpicker, back up its volumes to netpicker_backup-$STAMP.tar"
    say "  - start the new version and check that it is healthy; roll back if it is not"
    if [ $DRY_RUN -eq 1 ]; then
        say ""
        pass "dry run: ready to update; nothing was changed"
        finish
    fi
    ask "Start the update; Netpicker is down from the backup until the new version is up" || exit 0
    run_update
    rc=$?
    section "Done"
    if [ $rc -eq 0 ]; then
        pass "Netpicker is updated"
        if [ -s "$STATE/backup" ]; then
            detail "Rollback data: .update/$STAMP and $(basename "$(cat "$STATE/backup")")"
        else
            detail "Rollback data: .update/$STAMP"
        fi
        detail "Roll back with: ./update.sh --rollback $STAMP; free the space with: ./update.sh --cleanup"
        [ ! -f "$DIR/$OVERRIDE_FILE" ] || detail "Your local settings are in $OVERRIDE_FILE."
    fi
    [ $rc -eq 0 ] || exit 2
    finish
}

finish() {
    if [ $N_FAIL -gt 0 ]; then exit 2; fi
    if [ $N_WARN -gt 0 ]; then exit 1; fi
    exit 0
}

main
