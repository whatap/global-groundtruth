# jjsong-ggt-apm-java-bash52:1 — the only lab target on Ubuntu 24.04 noble's
# shells (bash 5.2.21, dash 0.5.12-6ubuntu5): every other apmjava target is
# built on a jammy/bookworm base (bash 5.1/5.2.15). Exists for the collector
# run under "bash -s" and "sh -s" (stdin, no shell version this repo has
# tested collect-apmjava.sh against yet).
#
# Two JVMs, both uid 1500 app (see start.sh): one whose JDK copy directory is
# deleted out from under it after it starts (a binary readlink -f still
# resolves but is no longer -x: "binary deleted or not executable" in
# section B — reconstructed from a real support case, see
# tools/lab/README.md, target apm-java-bash52), and one with the real WhaTap
# Java agent attached via -javaagent whose whatap.conf weaving list names a
# real module (spring-boot-3.0) and a made-up one (nonexistent-9.9).
#
# Dummy license, server 127.0.0.1: the agent never reaches a collection
# server.
ARG AGENT_IMAGE=public.ecr.aws/whatap/apm-init-java:latest
FROM ${AGENT_IMAGE} AS agent
FROM eclipse-temurin:21-jdk-noble
RUN apt-get update -qq && apt-get install -y -qq procps iproute2 unzip util-linux >/dev/null && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1500 app && mkdir -p /opt/whatap /app
COPY --from=agent /whatap/whatap.agent.java.jar /opt/whatap/
COPY whatap.conf /opt/whatap/
COPY Main.java Sleep.java /app/
RUN cd /app && javac Main.java Sleep.java && printf 'Main-Class: Main\n' > m.txt \
      && jar cfm app.jar m.txt Main.class && chown -R app:app /opt/whatap /app
COPY start.sh /start.sh
RUN chmod 755 /start.sh
CMD ["/start.sh"]
