# jjsong-ggt-java-zoo:1 — many JVMs in one container, for the apmjava edge
# cases a verification otherwise has to fake. What each JVM is for:
# tools/lab/README.md (target java-zoo) and start.sh.
# Agent jar: the public apm-init-java image (2.2.77 at 2026-09-27, whose
# whatap/v.properties has CRLF line ends). Dummy license, server 127.0.0.1.
ARG AGENT_IMAGE=public.ecr.aws/whatap/apm-init-java:latest
FROM ${AGENT_IMAGE} AS agent
FROM eclipse-temurin:17-jdk AS jdk17
FROM eclipse-temurin:8-jdk AS jdk8
FROM ibm-semeru-runtimes:open-8-jdk AS semeru8
FROM azul/zulu-openjdk:7 AS zulu7
COPY Zoo.java /build/
RUN cd /build && javac -source 7 -target 7 Zoo.java

FROM eclipse-temurin:21-jdk
RUN apt-get update -qq && apt-get install -y -qq procps iproute2 unzip >/dev/null && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1500 app && useradd -m -u 1600 jto && useradd -M -u 1700 collsrv
COPY --from=jdk17 /opt/java/openjdk /opt/jdk17-norelease
COPY --from=jdk8 /opt/java/openjdk /opt/jdk8
COPY --from=semeru8 /opt/java/openjdk /opt/semeru8
COPY --from=zulu7 /usr/lib/jvm/zulu7-ca-amd64 /opt/zulu7
COPY --from=zulu7 /build/Zoo.class /zoo/
COPY --from=agent /whatap/whatap.agent.java.jar /opt/whatap/
COPY start.sh /start.sh
# the JDK without a release file; the vshell launcher: a copy of the java
# launcher whose ../lib and ../conf lead to the Temurin 21 runtime
RUN set -e; rm /opt/jdk17-norelease/release; \
    P=/opt/axway/apigateway/platform; mkdir -p $P/bin; cp /opt/java/openjdk/bin/java $P/bin/vshell; \
    ln -s /opt/java/openjdk/lib $P/lib; ln -s /opt/java/openjdk/conf $P/conf; \
    conf() { printf 'license=ggt-lab-dummy-license\nwhatap.server.host=127.0.0.1\nwhatap.server.port=%s\nwhatap.name=%s\n' "$2" "$1"; }; \
    { conf ggtzoo-main 6600; i=5; while [ $i -le 450 ]; do printf '# ggt-lab padding line %s\n' $i; i=$((i+1)); done; \
      echo 'ggt_lab_after_line_450=tail'; } > /opt/whatap/whatap.conf; \
    for h in norelease jdk8 semeru8 zulu7 vshell jto sleeper1 sleeper2 sleeper3; do \
      mkdir -p /opt/whatap-homes/$h; conf ggtzoo-$h 6600 > /opt/whatap-homes/$h/whatap.conf; done; \
    mkdir -p /opt/whatap-homes/zooport; conf ggtzoo-zooport 6700 > /opt/whatap-homes/zooport/whatap.conf; \
    chown -R app /opt/whatap /opt/whatap-homes; chown -R jto /opt/whatap-homes/jto; chmod 755 /start.sh; \
    /opt/zulu7/bin/java -version; /opt/semeru8/bin/java -version; $P/bin/vshell -version
CMD ["/start.sh"]
