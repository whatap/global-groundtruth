# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# jjsong-ggt-collsrv: a permanent on-prem WhaTap collection-server install
# (front/keeper/proxy/yard/notihub/eureka/account/gateway), the target for
# both collection-server collectors. See ~/.claude/lab-environment.md.
# Read-only, load-light: collserver as the login user (WHATAP_HOME is its
# own), --stdout and a plain --bundle (no --jvm/--du/--with-rotated);
# collmysql as root over sudo -n, because the binary log
# files (/var/lib/mysql/binlog.*) are mode 640 owner mysql and unreadable by
# the login user, while root authenticates over the unix socket with no
# password. --bundle's tar.gz goes to /tmp on the VM, not the login home.
DESC="jjsong-ggt-collsrv, on-prem install; collserver --stdout/--bundle, collmysql --stdout/--binlog"
COLLECTORS="collection-server/collect-collserver.sh collection-server/collect-collmysql.sh"
ssh_target whatap@192.168.122.232
argsets() {
    case "$1" in
        */collect-collserver.sh)
            printf '%s\n' \
                "stdout|-|bash -s||--stdout" \
                "bundle|-|bash -s||--bundle --out /tmp" ;;
        */collect-collmysql.sh)
            printf '%s\n' \
                "stdout|0|bash -s||--stdout" \
                "binlog|0|bash -s||--stdout --binlog" ;;
    esac
}
# _ssh is defined by ssh_target (see zfs.sh for why this is safe to reuse).
t_health() { _ssh 'cd /data/whatap/bin && TERM=dumb ./control.sh all status 2>/dev/null | grep -q "account is Running"' && echo "collection-server modules running"; }
# collector-ERE|argset-ERE|ERE that must appear in the report (!ERE: must not)
CHECKS=(
    "collserver|stdout|status: COMPLETE"
    "collserver|stdout|-- account H2 database --"
    "collserver|stdout|backup files in"
    "collserver|stdout|yardbase path: "
    "collmysql|stdout|status: COMPLETE"
    "collmysql|binlog|status: COMPLETE"
)
