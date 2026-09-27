# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Many JVMs in one container for the apmjava edge cases (image
# tools/lab/images/java-zoo, what each JVM is for: its start.sh and
# tools/lab/README.md). The collector runs as uid 1500, the uid of every JVM
# but two: the JAVA_TOOL_OPTIONS-only JVM (uid 1600) and the listener (1700).
DESC="12 JVMs: no-release JDK, JDK 8/7, OpenJ9, vshell, JTO-only other uid, port 6700 + 70 sessions, >8 attached, 450-line whatap.conf, CRLF v.properties"
COLLECTORS="apm/java/collect-apmjava.sh"
docker_target jjsong-ggt-java-zoo jjsong-ggt-java-zoo:1
apm_argsets app
t_health() {
    t_sh 0 'n=$(pgrep -fc " [Z]oo "); s=$(ss -tn state established "( sport = :7070 )" | tail -n +2 | wc -l)
            echo "$n zoo JVMs (want 12), $s sessions on 7070 (want 70)"; [ "$n" = 12 ] && [ "$s" = 70 ]'
}
# collector|argset|ERE that must appear in the report (!ERE: must not)
CHECKS=(
    "apmjava|app-sh|release file: n/a \(path not found: /opt/jdk17-norelease/release\)"
    "apmjava|app-sh|^ +/opt/jdk8/release[: ]"
    "apmjava|app-sh|IMPLEMENTOR=\"IBM Corporation\""
    "apmjava|app-sh|-- java binary: /opt/zulu7/"
    "apmjava|app-sh|exe: /opt/axway/apigateway/platform/bin/vshell"
    "apmjava|app-sh|environ: n/a \(permission denied: /proc/[0-9]+/environ\)"
    "apmjava|app-sh|server port\(s\) for the session list: 6600 6700 "
    "apmjava|app-sh|:6700 +users:"
    "apmjava|app-sh|first 60 of 70 sessions"
    "apmjava|app-sh|remaining [0-9]+ attached JVMs not detailed in this section \(cap: 8\)"
    "apmjava|app-sh|config file \(verbatim\) \(first 400 lines; file size [0-9]+ bytes\)"
    "apmjava|app-sh|# ggt-lab padding line 400$"
    "apmjava|app-sh|!# ggt-lab padding line 401$"
    "apmjava|app-sh|^ +VERSION = 2\.[0-9.]+$"
)
