# jjsong-ggt-nms:1 — Rocky 9 + systemd, WhaTap NMS Control Manager
# (whatap-nms rpm from the public repo.whatap.io yum repo), dummy license,
# server 127.0.0.1 (never reaches a real collection server).
#
# The rpm's %post scriptlet calls `systemctl daemon-reload`/`enable`/`start`
# and needs a real systemd (dbus) running as PID 1 to succeed — a plain
# `docker build` RUN layer has no init, so `rpm -ivh` run at build time
# fails partway (venv built, but daemon-reload errors out under `set -e`
# and the scriptlet aborts before enabling the units). So the rpm is only
# *fetched* at build time; the actual `rpm -ivh` + `wtinitset` + starting
# the two services the installer leaves stopped (nmscore, icmptcphealthd;
# nmsautomationd too) run once at container first boot, when systemd is
# genuinely PID 1 (nms-install.service, gated by a marker file so a restart
# does not reinstall).
#
# Run with: --tmpfs /run --tmpfs /tmp --cgroupns=host
#           -v /sys/fs/cgroup:/sys/fs/cgroup:rw
FROM rockylinux:9

ARG WHATAP_NMS_RPM=http://repo.whatap.io/centos/9/x86_64/whatap-nms-1.3.3-1.el9.x86_64.rpm

# curl-minimal conflicts with the rpm's %post; net-snmp-utils gives the
# collector's own --snmp probe (and F14's snmpget/snmpwalk presence check)
# something to find; python3.9 satisfies the rpm's Python >= 3.9 preinstall
# check (Rocky 9's python3 stream default).
RUN dnf -y -q swap curl-minimal curl \
    && dnf -y -q install systemd python3.9 procps-ng iproute util-linux which findutils net-snmp-utils \
    && dnf clean all

RUN curl -fsSL -o /root/whatap-nms.rpm "$WHATAP_NMS_RPM"

COPY nms-first-boot.sh /usr/local/sbin/nms-first-boot.sh
COPY nms-install.service /etc/systemd/system/nms-install.service
RUN chmod 755 /usr/local/sbin/nms-first-boot.sh \
    && systemctl enable nms-install.service

STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
