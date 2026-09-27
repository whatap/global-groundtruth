# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# jjsong-ggt-zfs: a permanent VM whose zpool `yard` (vdb+vdc, special vdd)
# collzfs is written for. See ~/.claude/lab-environment.md. Read-only,
# load-light: --stdout and --bundle only (no --zdb, no --filesizes, no window
# override); the collector needs root for some zpool/zfs calls, so both
# argument sets run as root over sudo -n. --bundle writes its tar.gz under
# /tmp on the VM (systemd tmpfiles ages it out) rather than the login home.
DESC="jjsong-ggt-zfs, zpool yard, collzfs --stdout/--bundle as root"
COLLECTORS="collection-server/collect-collzfs.sh"
ssh_target whatap@192.168.122.231
ARGSETS=(
    "stdout|0|bash -s||--stdout"
    "bundle|0|bash -s||--bundle --out /tmp"
)
# _ssh is defined by ssh_target (bash function definitions are not lexically
# scoped: once ssh_target has run, _ssh is a global function in this shell).
t_health() { _ssh 'zpool list -H -o health yard 2>/dev/null' | grep -qx ONLINE && echo "pool yard ONLINE"; }
# collector-ERE|argset-ERE|ERE that must appear in the report (!ERE: must not)
CHECKS=(
    "collzfs|stdout|-- pool yard --"
    "collzfs|stdout|status: COMPLETE"
)
