# shellcheck shell=bash disable=SC2034  # KIND, ARGSETS, ... are read by run.sh
# Helpers a target file (tools/lab/targets/<name>.sh) calls to declare how it
# starts, stops and runs a collector. Sourced by tools/lab/run.sh; not run on
# its own. A target file sets DESC, COLLECTORS, ARGSETS (and optionally
# CHECKS, argsets(), t_health()) and calls exactly one of docker_target,
# ssh_target, local_target. Contract: tools/lab/README.md.
#
# Every kind defines:
#   t_up        make the target reachable; reuse what is already running
#   t_down      manual escape hatch: stop and remove it
#   t_status    one line: state, uptime, memory
#   t_exec USER SHELL ENV SCRIPT ARGS...
#               run SCRIPT inside the target as USER with SHELL ("sh -s",
#               "bash -s", "dash -s" feed it on stdin; "sh", "bash", "dash"
#               run it as a file), ENV a space-separated VAR=value list;
#               collector stdout/stderr pass through, rc is the collector's

LAB_TIMEOUT="${LAB_TIMEOUT:-400}"   # seconds per collector run

# the docker daemon the lab uses: DOCKER_HOST when set, else the permanent lab
# VM when it answers, else the local daemon with a warning (build/debug only)
lab_docker_host() {
    [ -n "${_LAB_DOCKER_DONE:-}" ] && return 0
    _LAB_DOCKER_DONE=1
    if [ -n "${DOCKER_HOST:-}" ]; then
        echo "lab: docker daemon DOCKER_HOST=$DOCKER_HOST" >&2
    elif [ "${LAB_DOCKER:-}" = local ]; then
        echo "lab: docker daemon: local (LAB_DOCKER=local)" >&2
    elif ssh -o BatchMode=yes -o ConnectTimeout=4 "${LAB_DOCKER_VM:-ggt-docker}" true 2>/dev/null; then
        export DOCKER_HOST="ssh://${LAB_DOCKER_VM:-ggt-docker}"
        echo "lab: docker daemon DOCKER_HOST=$DOCKER_HOST" >&2
    else
        echo "lab: WARNING ${LAB_DOCKER_VM:-ggt-docker} is not reachable; using the LOCAL docker daemon." >&2
        echo "lab:          Local is for building and debugging only: long-running targets belong on the lab VM," >&2
        echo "lab:          so stop what you start here (tools/lab/run.sh --down TARGET) when done." >&2
    fi
}

_env_flags() {  # "A=1 B=2" -> -e A=1 -e B=2
    local v
    for v in $1; do printf -- '-e\n%s\n' "$v"; done
}

# docker_target CONTAINER IMAGE [docker run options...]
# The container is long-running (--restart unless-stopped): t_up starts it
# only when absent, starts it when stopped, and builds IMAGE from
# tools/lab/images/$IMAGE_DIR (default: the target name) when the image is
# missing on the daemon.
docker_target() {
    KIND=docker; CONTAINER="$1"; IMAGE="$2"; shift 2
    RUN_OPTS=("$@"); RUN_CMD=()   # a target may set RUN_CMD (args after the image)
    : "${IMAGE_DIR:=$TARGET_NAME}"
    t_build() {
        [ -d "$LAB/images/$IMAGE_DIR" ] || { echo "lab: $TARGET_NAME: no tools/lab/images/$IMAGE_DIR to build $IMAGE from" >&2; return 1; }
        echo "lab: $TARGET_NAME: building $IMAGE from tools/lab/images/$IMAGE_DIR" >&2
        docker build -q -t "$IMAGE" "$LAB/images/$IMAGE_DIR" >&2
    }
    t_up() {
        local st
        lab_docker_host
        st="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"
        case "$st" in
            running) return 0 ;;
            '') docker image inspect "$IMAGE" >/dev/null 2>&1 || t_build || return 1
                echo "lab: $TARGET_NAME: starting $CONTAINER" >&2
                docker run -d --name "$CONTAINER" --restart unless-stopped "${RUN_OPTS[@]}" "$IMAGE" "${RUN_CMD[@]}" >/dev/null ;;
            *)  echo "lab: $TARGET_NAME: $CONTAINER is $st; starting it" >&2
                docker start "$CONTAINER" >/dev/null ;;
        esac
    }
    t_down() {
        lab_docker_host
        docker rm -f "$CONTAINER" >/dev/null 2>&1 && echo "lab: $TARGET_NAME: removed $CONTAINER" >&2
    }
    t_status() {
        local st mem
        lab_docker_host
        st="$(docker inspect -f '{{.State.Status}} since {{.State.StartedAt}}' "$CONTAINER" 2>/dev/null)" || { echo "absent"; return 1; }
        mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER" 2>/dev/null)"
        echo "$CONTAINER $st${mem:+, mem $mem}"
        case "$st" in running*) return 0 ;; *) return 1 ;; esac
    }
    t_exec() {
        local user="$1" shell="$2" env="$3" script="$4" d rc
        shift 4
        local -a ef
        mapfile -t ef < <(_env_flags "$env")
        # shellcheck disable=SC2086  # $shell is "sh -s": two words
        case "$shell" in
            *" -s")
                timeout "$LAB_TIMEOUT" docker exec -i -u "$user" "${ef[@]}" "$CONTAINER" $shell -- "$@" < "$script" ;;
            *)
                d="/tmp/ggtlab.$LAB_RUNID"
                docker exec -i -u 0 "$CONTAINER" sh -c "mkdir -p $d && cat > $d/$(basename "$script") && chmod -R 755 $d" < "$script"
                timeout "$LAB_TIMEOUT" docker exec -u "$user" -w "$d" "${ef[@]}" "$CONTAINER" "$shell" "$d/$(basename "$script")" "$@" </dev/null
                rc=$?
                docker exec -u 0 "$CONTAINER" rm -rf "$d" </dev/null
                return $rc ;;
        esac
    }
    # in-container helper for t_health: t_sh USER 'command'
    t_sh() { docker exec -u "$1" "$CONTAINER" sh -c "$2" </dev/null; }
}

# ssh_target HOST   (a host or VM that is already up; t_up only checks it)
# USER "-" is the login user, "0" is root through sudo -n.
ssh_target() {
    KIND=ssh; SSH_HOST="$1"
    _ssh() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" "$@"; }
    t_up() { _ssh true 2>/dev/null || { echo "lab: $TARGET_NAME: ssh $SSH_HOST does not answer" >&2; return 1; }; }
    t_down() { echo "lab: $TARGET_NAME: an ssh target is not started or stopped by the lab" >&2; }
    t_status() {
        _ssh 'echo "$(hostname) up $(cut -d. -f1 /proc/uptime)s, $(free -m | awk "/^Mem:/{print \$7}") MiB available"' 2>/dev/null \
            || { echo "unreachable"; return 1; }
    }
    t_exec() {
        local user="$1" shell="$2" env="$3" script="$4" pre="" q="" a
        shift 4
        [ "$user" = 0 ] && pre="sudo -n"
        for a in "$@"; do q="$q $(printf '%q' "$a")"; done
        case "$shell" in
            *" -s") timeout "$LAB_TIMEOUT" ssh -o BatchMode=yes "$SSH_HOST" "$pre env $env $shell --$q" < "$script" ;;
            *) echo "lab: $TARGET_NAME: ssh targets run collectors on stdin only (use '$shell -s')" >&2; return 2 ;;
        esac
    }
    t_sh() { _ssh "$2" </dev/null; }
}

# local_target   (this host; capture-compare.sh behaviour)
# USER must be "-" (the invoking user); runs in a scratch working directory.
local_target() {
    KIND=local
    t_up() { return 0; }
    t_down() { echo "lab: $TARGET_NAME: this host is not started or stopped by the lab" >&2; }
    t_status() { echo "this host ($(hostname)), $(free -m | awk '/^Mem:/{print $7}') MiB available"; }
    t_exec() {
        local user="$1" shell="$2" env="$3" script="$4" rc
        shift 4
        [ "$user" = - ] || { echo "lab: $TARGET_NAME: USER must be '-' for the local target" >&2; return 2; }
        # the same path for the base and the working-tree copy, so $0 matches
        mkdir -p "$LAB_WORK/cwd" "$LAB_WORK/bin"
        cp "$script" "$LAB_WORK/bin/" && script="$LAB_WORK/bin/$(basename "$script")"
        # shellcheck disable=SC2086  # $env and $shell are word lists
        case "$shell" in
            *" -s") (cd "$LAB_WORK/cwd" && env $env timeout "$LAB_TIMEOUT" $shell -- "$@" < "$script"); rc=$? ;;
            *)      (cd "$LAB_WORK/cwd" && env $env timeout "$LAB_TIMEOUT" "$shell" "$script" "$@" </dev/null); rc=$? ;;
        esac
        rm -rf "$LAB_WORK/cwd"
        return $rc
    }
    t_sh() { sh -c "$2" </dev/null; }
}

# apm_argsets APPUSER: the argument sets every apm container target runs —
# help and a bad argument (cheap), --stdout on stdin as the app's uid under
# sh and bash (kubectl exec / docker exec shape) and as root, as a file, and
# the deadline mode (RUN_DEADLINE=2 CMD_TIMEOUT=1; flips with host load).
# Format of one set: name|user|shell|ENV|args
apm_argsets() {
    ARGSETS=(
        "help|$1|sh -s||"
        "badarg|$1|sh -s||--no-such-arg"
        "app-sh|$1|sh -s||--stdout"
        "app-bash|$1|bash -s||--stdout"
        "root-sh|0|sh -s||--stdout"
        "app-file|$1|sh||--stdout"
        "dl|$1|sh -s|RUN_DEADLINE=2 CMD_TIMEOUT=1|--stdout"
    )
}
