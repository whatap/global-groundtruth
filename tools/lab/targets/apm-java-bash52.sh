# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Ubuntu 24.04 noble base (bash 5.2.21, dash 0.5.12-6ubuntu5): the only lab
# target that is not jammy/bookworm bash, for the collector-on-stdin path
# ("bash -s"/"sh -s", apm_argsets app-bash/app-sh). Two JVMs uid 1500 app:
# one whose JDK copy dir is deleted after it starts (section B "binary
# deleted since the JVM started"), one with the real WhaTap Java agent and a
# whatap.conf weaving list of a real module + a bogus one. See
# images/apm-java-bash52/Dockerfile and start.sh, and README.md.
DESC="Ubuntu 24.04 noble (bash 5.2.21, dash), JDK-copy-deleted JVM + agent JVM with weaving=spring-boot-3.0,nonexistent-9.9"
COLLECTORS="apm/java/collect-apmjava.sh"
docker_target jjsong-ggt-apm-java-bash52 jjsong-ggt-apm-java-bash52:1
apm_argsets app
t_health() { t_sh app 'pgrep -f whatap.agent.java.jar >/dev/null && echo "agent JVM running"'; }
CHECKS=(
    "apmjava|app-sh|-javaagent:/opt/whatap/whatap\.agent\.java\.jar"
    "apmjava|app-sh|binary deleted since the JVM started"
    "apmjava|app-sh|[0-9]+ entries matching weaving/\* \([0-9]+ printed\):"
    "apmjava|app-sh|^ +spring-boot-3\.0\.jar$"
    "apmjava|app-sh|weaving=spring-boot-3\.0,nonexistent-9\.9"
)
