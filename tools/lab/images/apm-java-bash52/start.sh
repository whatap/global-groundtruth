#!/bin/sh
# PID 1 of jjsong-ggt-apm-java-bash52. Both JVMs run as uid 1500 app.
# 1: a JDK copied to /opt/jdkcopy at boot, whose bin/java is removed while
#    the JVM keeps running from it (readlink -f still resolves it, but it is
#    no longer -x): "binary deleted or not executable" in section B.
# 2: the real WhaTap Java agent via -javaagent, whatap.conf naming a real
#    weaving module (spring-boot-3.0) and a bogus one (nonexistent-9.9).
set -e
mkdir -p /var/log/apm
cp -r /opt/java/openjdk /opt/jdkcopy
chown -R app:app /opt/jdkcopy
setpriv --reuid=1500 --regid=1500 --clear-groups \
    /opt/jdkcopy/bin/java -cp /app Sleep >/var/log/apm/deleted.log 2>&1 &
# let the JVM actually start (map its own binary) before the dir goes away
sleep 2
rm -rf /opt/jdkcopy
setpriv --reuid=1500 --regid=1500 --clear-groups \
    java -javaagent:/opt/whatap/whatap.agent.java.jar -Xmx128m -jar /app/app.jar \
    >/var/log/apm/agent.log 2>&1 &
exec sleep infinity
