#!/usr/bin/env bash
# Run collectors before and after a change inside lab targets, and diff them.
#
#   tools/lab/run.sh [--base REF] [--only REGEX] [--out DIR] TARGET...
#       for each TARGET: bring it up if it is not running (reuse otherwise),
#       run every collector that applies, once from REF (default HEAD, taken
#       with git archive) and once from the working tree, with the target's
#       argument sets; store masked stdout / stderr / rc under
#       DIR/<target>/{base,new}/, check the target's expected facts on both,
#       print a per-target summary. Exit 1 on any difference or failed check.
#   tools/lab/run.sh --list               targets, what they cover, collectors
#   tools/lab/run.sh --status [TARGET...] state, uptime, memory, health
#   tools/lab/run.sh --up TARGET...       first start (or restart) and wait healthy
#   tools/lab/run.sh --build TARGET...    rebuild the image from tools/lab/images/
#   tools/lab/run.sh --down TARGET...     manual escape hatch: remove the container
#
# Targets are long-running and permanent: a run never tears one down. Docker
# targets use DOCKER_HOST, else the lab VM ggt-docker when it answers, else
# the local daemon (build/debug only; a warning says so). Masking and the
# diff are capture-compare.sh's own mask() and compare(), read from that file.
# --only REGEX limits collectors (matched against their path under
# collectors/). Targets: tools/lab/targets/<name>.sh; see tools/lab/README.md.
set -u

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$LAB/../.." && pwd)"
export LAB REPO

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# mask() and compare() come from capture-compare.sh so the two tools cannot
# drift apart; the file is read, not run (its case dispatch would exit).
eval "$(sed -n -e '/^mask() {/,/^}/p' -e '/^compare() {/,/^}/p' "$REPO/tools/capture-compare.sh")"
declare -F mask >/dev/null && declare -F compare >/dev/null \
    || { echo "lab: could not read mask()/compare() from tools/capture-compare.sh" >&2; exit 2; }

# resolve the docker daemon once, in this shell, when a named target is a
# docker target, so every subshell and $(...) inherits DOCKER_HOST
docker_once() {
    local t
    for t in "$@"; do
        grep -q '^docker_target' "$LAB/targets/$t.sh" 2>/dev/null || continue
        # shellcheck source=tools/lab/lib.sh
        . "$LAB/lib.sh"; lab_docker_host; export _LAB_DOCKER_DONE; return
    done
}

targets_all() { for f in "$LAB"/targets/*.sh; do basename "$f" .sh; done; }

# load_target NAME: source the target file into the current (sub)shell
load_target() {
    TARGET_NAME="$1"
    [ -f "$LAB/targets/$1.sh" ] || { echo "lab: no target $1 (tools/lab/run.sh --list)" >&2; return 2; }
    DESC=""; COLLECTORS=""; ARGSETS=(); CHECKS=(); KIND=""
    unset -f argsets t_health 2>/dev/null
    # shellcheck source=tools/lab/lib.sh
    . "$LAB/lib.sh"
    # shellcheck disable=SC1090
    . "$LAB/targets/$1.sh"
    [ -n "$KIND" ] || { echo "lab: target $1 declares no kind (docker_target/ssh_target/local_target)" >&2; return 2; }
}

# argsets of one collector: the target's argsets() when it defines one
argsets_for() {
    if declare -F argsets >/dev/null; then argsets "$1"; else printf '%s\n' "${ARGSETS[@]}"; fi
}

health() {  # wait up to 90 s for t_health, when the target defines it
    local i
    declare -F t_health >/dev/null || return 0
    for i in $(seq 1 30); do
        t_health >/dev/null 2>&1 && return 0
        [ "$i" = 1 ] && echo "lab: $TARGET_NAME: waiting for health" >&2
        sleep 3
    done
    echo "lab: $TARGET_NAME: not healthy: $(t_health 2>&1 | head -3)" >&2
    return 1
}

cmd_list() {
    local t
    for t in $(targets_all); do
        ( load_target "$t" >/dev/null 2>&1 || exit 0
          printf '%-16s %-6s %s\n' "$t" "$KIND" "$DESC"
          printf '%-16s %-6s collectors: %s\n' "" "" "$COLLECTORS" )
    done
}

cmd_status() {
    local t rc=0
    for t in "$@"; do
        ( load_target "$t" || exit 2
          s="$(t_status)"; src=$?
          h=""; if [ $src = 0 ] && declare -F t_health >/dev/null; then h="$(t_health 2>&1 | head -1)" || h="UNHEALTHY: $h"; fi
          printf '%-16s %s%s\n' "$t" "$s" "${h:+ | $h}"
          exit $src ) || rc=1
    done
    return $rc
}

cmd_each() {  # up|down|build TARGET...
    local op="$1" t rc=0; shift
    for t in "$@"; do
        ( load_target "$t" || exit 2
          case "$op" in
              up)    t_up && health ;;
              down)  t_down ;;
              build) [ "$KIND" = docker ] || { echo "lab: $t: not a docker target" >&2; exit 0; }
                     lab_docker_host; t_build ;;
          esac ) || rc=1
    done
    [ "$op" = up ] && cmd_status "$@"
    return $rc
}

# run_target NAME: the before/after run of one target, summary on stdout
run_target() {
    load_target "$1" || return 2
    local o="$OUT/$1" c p n line an user shell env args tree base_rc=0 f
    local -a av
    t_up || { echo "$1: NOT UP (see above)"; return 3; }
    health || { echo "$1: NOT HEALTHY"; return 3; }
    mkdir -p "$o/base" "$o/new"
    LAB_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ggtlab.XXXXXX")"; export LAB_WORK
    for c in $COLLECTORS; do
        printf '%s\n' "$c" | grep -qE "${ONLY:-.}" || continue
        n="$(basename "$c" .sh)"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            IFS='|' read -r an user shell env args <<<"$line"
            read -r -a av <<<"$args"
            for tree in base new; do
                if [ "$tree" = base ]; then p="$BASE_TREE/collectors/$c"; else p="$REPO/collectors/$c"; fi
                f="$o/$tree/$n.$an"
                if [ ! -f "$p" ]; then echo absent > "$f.rc"; : > "$f.out"; : > "$f.err"; continue; fi
                printf 'lab: %s %s %-10s %s\n' "$1" "$tree" "$an" "$n" >&2
                t_exec "$user" "$shell" "$env" "$p" "${av[@]}" > "$LAB_WORK/o" 2> "$LAB_WORK/e"
                echo $? > "$f.rc"
                mask < "$LAB_WORK/o" > "$f.out"; mask < "$LAB_WORK/e" > "$f.err"
            done
        done < <(argsets_for "$c")
    done
    rm -rf "$LAB_WORK"

    # checks: collector-regex|argset-regex|ERE that must appear in stdout
    # of a file of that collector and argument set (!ERE: in none of them)
    local chk cre are ere tot=0 okn=0 okb=0 fails="" hit
    for chk in "${CHECKS[@]}"; do
        IFS='|' read -r cre are ere <<<"$chk"
        printf '%s\n' "$COLLECTORS" | tr ' ' '\n' | grep -E "${ONLY:-.}" | grep -qE "$cre" || continue
        for tree in new base; do
            # a leading ! means the pattern must appear in none of the files
            hit=0; case "$ere" in '!'*) hit=1 ;; esac
            for f in "$o/$tree"/*.out; do
                n="$(basename "$f" .out)"
                printf '%s\n' "${n%.*}" | grep -qE "$cre" && printf '%s\n' "${n##*.}" | grep -qE "^($are)$" || continue
                case "$ere" in
                    '!'*) grep -qE -- "${ere#!}" "$f" && hit=0 && break ;;
                    *)    grep -qE -- "$ere" "$f" && hit=1 && break ;;
                esac
            done
            if [ "$tree" = new ]; then tot=$((tot + 1)); [ $hit = 1 ] && okn=$((okn + 1)) || fails="$fails
    FAIL  $chk"; else [ $hit = 1 ] && okb=$((okb + 1)); fi
        done
    done

    local d nf nd rcs
    d="$(compare "$o/base" "$o/new")" || base_rc=1
    printf '%s\n' "$d" > "$o/diff.txt"
    nf="$(find "$o/new" -type f | wc -l)"
    nd="$(printf '%s\n' "$d" | grep -cE '^(== |MISSING |EXTRA )')"
    rcs="$(for f in "$o/new"/*.rc; do printf '%s=%s ' "$(basename "$f" .rc)" "$(cat "$f")"; done)"
    printf '== %s (%s)\n' "$1" "$(t_status 2>/dev/null)"
    printf '   files %s, differ %s, checks %s/%s (base %s/%s)\n' "$nf" "$nd" "$okn" "$tot" "$okb" "$tot"
    printf '   rc new: %s\n' "$rcs"
    [ -n "$fails" ] && printf '   checks failed on the working tree:%s\n' "$fails"
    [ "$nd" -gt 0 ] && printf '%s\n' "$d" | sed 's/^/   /'
    [ "$base_rc" = 0 ] && [ "$okn" = "$tot" ]
}

# ---- main ----------------------------------------------------------------
BASE=HEAD; ONLY=""; OUT=""; TARGETS=()
[ $# -gt 0 ] || usage
case "$1" in
    --list)   cmd_list; exit $? ;;
    --status) shift
              [ $# -gt 0 ] || { mapfile -t _all < <(targets_all); set -- "${_all[@]}"; }
              docker_once "$@"; cmd_status "$@"
              exit $? ;;
    --up|--down|--build) op="${1#--}"; shift; [ $# -gt 0 ] || usage; docker_once "$@"; cmd_each "$op" "$@"; exit $? ;;
    -h|--help) usage ;;
esac
while [ $# -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:?}"; shift 2 ;;
        --only) ONLY="${2:?}"; shift 2 ;;
        --out)  OUT="${2:?}"; shift 2 ;;
        -*)     echo "lab: unknown option $1" >&2; usage ;;
        *)      TARGETS+=("$1"); shift ;;
    esac
done
[ ${#TARGETS[@]} -gt 0 ] || usage
export ONLY
git -C "$REPO" rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "lab: --base $BASE is not a commit" >&2; exit 2; }
OUT="${OUT:-${TMPDIR:-/tmp}/ggtlab-out/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
BASE_TREE="$(mktemp -d "${TMPDIR:-/tmp}/ggtlab-base.XXXXXX")"
trap 'rm -rf "$BASE_TREE"' EXIT
git -C "$REPO" archive --format=tar "$BASE" collectors | tar -x -C "$BASE_TREE" || exit 2
LAB_RUNID="$$"; export LAB_RUNID
echo "lab: base $BASE ($(git -C "$REPO" rev-parse --short "$BASE")) vs working tree; output $OUT" >&2

docker_once "${TARGETS[@]}"
rc=0
for t in "${TARGETS[@]}"; do
    ( run_target "$t" ); r=$?
    [ $r -gt $rc ] && rc=$r
done
echo "output: $OUT"
exit $rc
