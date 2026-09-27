#!/bin/bash
# PID 1 of the Ubuntu 8.0 containers (under docker --init). Arguments go to
# mysqld (--server-id=N, --read-only=ON ...). auto.cnf was removed at build,
# so every container generates its own server_uuid on first start.
mkdir -p /var/run/mysqld && chown mysql:mysql /var/run/mysqld
exec /usr/sbin/mysqld "$@"
