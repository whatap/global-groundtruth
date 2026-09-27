# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# The real jjsong-k8s-cp1/w1/w2/w3 cluster (v1.32.13, cilium), reached with
# this machine's default kubeconfig (context kubernetes-admin@kubernetes).
# Read-only: --stdout only, no --apm-target/--apm-exec/--exec-per-node (those
# exec into pods; this cluster is not ours to touch beyond reading). It has
# real operator-injected Java APM pods in the `coursematerials` namespace
# (see ~/.claude/lab-environment.md), so section J's cluster-wide init-container
# inventory (always on, no --apm-target needed) has something to find.
DESC="jjsong-k8s cluster (default kubeconfig), read-only, real operator-injected APM pods in coursematerials"
COLLECTORS="k8s/collect-k8s.sh"
local_target
ARGSETS=( "stdout|-|bash||--stdout" )
t_health() { kubectl get --raw /healthz 2>/dev/null | grep -qx ok && echo "apiserver healthz ok"; }
t_status() {
    local nodes; nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    echo "jjsong-k8s ($nodes node(s), default kubeconfig)"
}
# collector-ERE|argset-ERE|ERE that must appear in the report (!ERE: must not)
CHECKS=(
    "collect-k8s|stdout|status: COMPLETE"
    "collect-k8s|stdout|coursematerials"
)
