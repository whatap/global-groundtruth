# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Temurin 21 + the real WhaTap Java agent 2.2.77 on the command line
# (-javaagent), JVM as uid 1500 app. See tools/lab/README.md.
DESC="Temurin 21, Java agent via -javaagent, JVM uid 1500"
COLLECTORS="apm/java/collect-apmjava.sh"
docker_target jjsong-ggt-apm-java jjsong-ggt-apm-java:1
apm_argsets app
t_health() { t_sh app 'pgrep -f whatap.agent.java.jar >/dev/null && echo "agent JVM running"'; }
CHECKS=(
    "apmjava|app-sh|-javaagent:/opt/whatap/whatap\.agent\.java\.jar"
    "apmjava|app-sh|-- agent jar: /opt/whatap/whatap\.agent\.java\.jar"
)
