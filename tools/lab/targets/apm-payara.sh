# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Payara Server 6 (GlassFish lineage) + the real WhaTap Java agent baked into
# domain1's domain.xml <jvm-options> (no -javaagent on any command line the
# collector can see other than /proc/<pid>/cmdline itself), JVM as uid 1000
# payara. See tools/lab/README.md.
DESC="Payara Server 6 (GlassFish), Java agent via domain.xml jvm-options, JVM uid 1000 payara"
COLLECTORS="apm/java/collect-apmjava.sh"
docker_target jjsong-ggt-apm-payara jjsong-ggt-apm-payara:1
apm_argsets payara
t_health() { t_sh payara 'pgrep -f whatap.agent.java.jar >/dev/null && echo "agent JVM running"'; }
CHECKS=(
    "apmjava|app-sh|-javaagent:/opt/whatap/whatap\.agent\.java\.jar"
    "apmjava|app-sh|-- agent jar: /opt/whatap/whatap\.agent\.java\.jar"
)
