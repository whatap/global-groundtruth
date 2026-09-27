# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# jjsong-ggt-nms: Rocky 9 + systemd, WhaTap NMS Control Manager (whatap-nms
# 1.3.3-1.el9 rpm from the public repo.whatap.io yum repo), dummy license
# znun32arkonto-... / server 127.0.0.1 (wtinitset's own doc example key,
# never reaches a real collection server). All four units (uvicorn, nmscore,
# icmptcphealthd, nmsautomationd) are up — the installer's new-install branch
# only auto-starts uvicorn, so the image's first-boot unit
# (tools/lab/images/nms/nms-install.service) runs wtinitset and starts the
# rest once, at real (systemd-PID-1) boot; see that Dockerfile's comment for
# why the rpm cannot simply be `rpm -ivh`'d in a Dockerfile RUN (no dbus at
# `docker build` time, so the rpm's %post `systemctl daemon-reload` aborts
# the scriptlet under `set -e`). All nms processes run as root, so every
# argument set runs as uid 0 (a non-root run would only lose established
# :6600 session ownership detail, per README section G — nothing here is
# gated behind CAP_SYS_PTRACE the way the APM targets are).
DESC="jjsong-ggt-nms, Rocky 9 + systemd, whatap-nms 1.3.3 rpm, all 4 units running (dummy license)"
COLLECTORS="nms/collect-nms.sh"
docker_target jjsong-ggt-nms jjsong-ggt-nms:1 \
    --tmpfs /run --tmpfs /tmp --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw
ARGSETS=(
    "help|0|sh -s||"
    "badarg|0|sh -s||--no-such-arg"
    "stdout|0|bash -s||--stdout"
)
t_health() { t_sh 0 '[ "$(systemctl is-active uvicorn nmscore icmptcphealthd nmsautomationd 2>/dev/null | grep -cx active)" = 4 ] && echo "uvicorn+nmscore+icmptcphealthd+nmsautomationd active"'; }
# collector-ERE|argset-ERE|ERE that must appear in the report (!ERE: must not)
CHECKS=(
    "collect-nms|stdout|status: COMPLETE"
    "collect-nms|stdout|nms install root \\(resolved\\): /usr/share/whatap-nms"
    "collect-nms|stdout|uvicorn\\.service: active=active enabled=enabled"
    "collect-nms|stdout|nmscore\\.service: active=active enabled=enabled"
    "collect-nms|stdout|icmptcphealthd\\.service: active=active enabled=enabled"
    "collect-nms|stdout|mibmods\\.toml"
    "collect-nms|stdout|wtinitset -v:"
)
