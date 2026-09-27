# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# jjsong-ggt-k8sproxy: a permanent kubeadm cluster reproducing the MEA
# 2026-08-18 webhook-failing-open case (lowercase https_proxy on the
# apiserver, no_proxy missing .svc/CIDRs). See ~/.claude/lab-environment.md.
# Two argument sets, because the collector's own s_client-style serving-chain
# probe needs a route to the pod/service CIDR that only exists INSIDE the VM:
#   "here" — this machine, KUBECONFIG=~/.kube/config-ggt-k8sproxy, the
#            bastion shape (kubectl reaches the cluster over the LAN)
#   "vm"    — ssh into the VM itself and run the collector there, in-cluster
# This is not one of lib.sh's three kinds (docker/ssh/local): it is local_target
# with t_exec overridden so the ARGSETS "user" field ("-" vs "vm") picks which
# host runs the script, everything else (t_up/t_down/t_status) stays local_target's.
DESC="jjsong-ggt-k8sproxy, MEA webhook-fail-open repro; collect-k8s.sh from here (KUBECONFIG) and from inside the VM"
COLLECTORS="k8s/collect-k8s.sh"
KUBECFG="$HOME/.kube/config-ggt-k8sproxy"
local_target
argsets() {
    printf '%s\n' \
        "here|-|bash|KUBECONFIG=$KUBECFG|--stdout" \
        "vm|vm|bash -s||--stdout"
}
t_exec() {
    local user="$1" shell="$2" env="$3" script="$4"
    shift 4
    case "$user" in
        vm)
            local q="" a
            for a in "$@"; do q="$q $(printf '%q' "$a")"; done
            timeout "$LAB_TIMEOUT" ssh -o BatchMode=yes k8sproxy "env $env $shell --$q" < "$script" ;;
        -)
            local rc
            mkdir -p "$LAB_WORK/cwd" "$LAB_WORK/bin"
            cp "$script" "$LAB_WORK/bin/" && script="$LAB_WORK/bin/$(basename "$script")"
            # shellcheck disable=SC2086  # $env and $shell are word lists
            case "$shell" in
                *" -s") (cd "$LAB_WORK/cwd" && env $env timeout "$LAB_TIMEOUT" $shell -- "$@" < "$script"); rc=$? ;;
                *)      (cd "$LAB_WORK/cwd" && env $env timeout "$LAB_TIMEOUT" "$shell" "$script" "$@" </dev/null); rc=$? ;;
            esac
            rm -rf "$LAB_WORK/cwd"
            return $rc ;;
        *) echo "lab: k8sproxy: USER must be '-' (here) or 'vm'" >&2; return 2 ;;
    esac
}
t_up() {
    [ -f "$KUBECFG" ] || { echo "lab: k8sproxy: no kubeconfig at $KUBECFG" >&2; return 1; }
    ssh -o BatchMode=yes -o ConnectTimeout=5 k8sproxy true 2>/dev/null || { echo "lab: k8sproxy: ssh k8sproxy does not answer" >&2; return 1; }
}
t_status() {
    local nodes
    nodes="$(KUBECONFIG="$KUBECFG" kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    echo "k8sproxy ($nodes node(s) via $KUBECFG), $(ssh -o BatchMode=yes -o ConnectTimeout=5 k8sproxy 'echo up $(cut -d. -f1 /proc/uptime)s' 2>/dev/null || echo 'ssh unreachable')"
}
t_health() { KUBECONFIG="$KUBECFG" kubectl get --raw /healthz 2>/dev/null | grep -qx ok && echo "apiserver healthz ok"; }
# collector-ERE|argset-ERE|ERE that must appear in the report (!ERE: must not)
CHECKS=(
    "collect-k8s|here|https_proxy"
    "collect-k8s|here|fail_open_count"
    "collect-k8s|vm|https_proxy"
    "collect-k8s|vm|fail_open_count"
)
