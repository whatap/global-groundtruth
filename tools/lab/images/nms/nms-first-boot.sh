#!/bin/bash
# Runs once, at the container's first real boot (systemd genuinely PID 1):
# install the rpm fetched at build time, set the dummy access key/server,
# and start the two services the installer's new-install branch leaves
# enabled-but-stopped (nmscore, icmptcphealthd) plus nmsautomationd.
# Gated by MARK so a container restart does not redo this.
set -e
MARK=/var/lib/whatap-nms-installed

if [ ! -f "$MARK" ]; then
    rpm -ivh /root/whatap-nms.rpm
    # Docs' own example key: syntactically valid so wtinitset accepts it,
    # obviously not a real customer key. Server 127.0.0.1: no real
    # collection server is ever contacted.
    wtinitset -a znun32arkonto-76rbkt4ftlrwh9-s0dywogeww1lhs -s 127.0.0.1
    systemctl start nmscore.service icmptcphealthd.service nmsautomationd.service
    mkdir -p "$(dirname "$MARK")"
    touch "$MARK"
fi
