# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# The apm-java image started the way the k8s operator injects the agent:
# JAVA_TOOL_OPTIONS only, nothing on the command line.
DESC="Temurin 21, Java agent only via JAVA_TOOL_OPTIONS (operator shape)"
COLLECTORS="apm/java/collect-apmjava.sh"
IMAGE_DIR=apm-java
docker_target jjsong-ggt-apm-java-jto jjsong-ggt-apm-java:1 \
    -e JAVA_TOOL_OPTIONS=-javaagent:/opt/whatap/whatap.agent.java.jar \
    --entrypoint java
RUN_CMD=(-Xmx64m -XX:+UseSerialGC -jar /app/app.jar)
apm_argsets app
t_health() { t_sh app 'pgrep -f app.jar >/dev/null && echo "app JVM running"'; }
CHECKS=(
    "apmjava|app-sh|env JAVA_TOOL_OPTIONS=-javaagent:/opt/whatap/whatap\.agent\.java\.jar"
)
