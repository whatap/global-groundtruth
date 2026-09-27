#!/bin/sh
# PID 1 of jjsong-ggt-java-zoo: start every JVM of the zoo, then idle.
# Runs as root only to hand each JVM its uid; every JVM drops to its own.
# Layout and the reason for each JVM: tools/lab/README.md, target java-zoo.
S="-Xmx32m -Xms8m -Xss256k -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -XX:ReservedCodeCacheSize=16m"
J9="-Xmx32m -Xms8m -Xss256k -Xgcpolicy:optthruput -Xshareclasses:none"
AG=-javaagent:/opt/whatap/whatap.agent.java.jar
as() { u="$1"; shift; setpriv --reuid="$u" --regid="$u" --clear-groups "$@" </dev/null >>/var/log/zoo/"$u".log 2>&1 & }
mkdir -p /var/log/zoo
# the collection-server stand-in: 6600 (default), 6700 (zoo-port), 7070 (sessions)
as 1700 /opt/java/openjdk/bin/java $S -cp /zoo Zoo hold 6600 6700 7070
sleep 2
cd /home/app || exit 1
# 1 main: Temurin 21, -javaagent, whatap.conf over 400 lines
as 1500 /opt/java/openjdk/bin/java $S $AG -Dwhatap.home=/opt/whatap -cp /zoo Zoo sleep
# 2 a JDK 17 install without its release file
as 1500 /opt/jdk17-norelease/bin/java $S $AG -Dwhatap.home=/opt/whatap-homes/norelease -cp /zoo Zoo sleep
# 3 Temurin 8 (libjvm under jre/lib/amd64/server)
as 1500 /opt/jdk8/bin/java $S $AG -Dwhatap.home=/opt/whatap-homes/jdk8 -cp /zoo Zoo sleep
# 4 IBM Semeru 8 (OpenJ9)
as 1500 /opt/semeru8/bin/java $J9 $AG -Dwhatap.home=/opt/whatap-homes/semeru8 -cp /zoo Zoo sleep
# 5 Zulu 7: the agent jar is Java 8 bytecode, so only the -Dwhatap. marker
as 1500 /opt/zulu7/bin/java $S -Dwhatap.home=/opt/whatap-homes/zulu7 -cp /zoo Zoo sleep
# 6 a launcher named vshell (a copy of the java launcher, as Axway API Gateway ships)
as 1500 /opt/axway/apigateway/platform/bin/vshell $S $AG -Dwhatap.home=/opt/whatap-homes/vshell -cp /zoo Zoo sleep
# 7 attached only through JAVA_TOOL_OPTIONS, running as uid 1600 (not the collector's uid)
JAVA_TOOL_OPTIONS="$AG -Dwhatap.home=/opt/whatap-homes/jto" as 1600 /opt/java/openjdk/bin/java $S -cp /zoo Zoo sleep
# 8 server port 6700 in its whatap.conf and one session to 6700 (the agent opens
#   none under the dummy license, so the JVM opens it), plus 70 sessions to 7070
as 1500 /opt/java/openjdk/bin/java $S $AG -Dwhatap.home=/opt/whatap-homes/zooport -cp /zoo Zoo sess 127.0.0.1 6700:1 7070:70
# 9-11 cheap marker-only JVMs, so the attached count passes the cap of 8
for n in 1 2 3; do
    as 1500 /opt/java/openjdk/bin/java $S -Dwhatap.home=/opt/whatap-homes/sleeper$n -cp /zoo Zoo sleep
done
exec sleep infinity
