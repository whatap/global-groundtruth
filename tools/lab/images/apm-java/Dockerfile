# jjsong-ggt-apm-java:1 — Temurin 21 + WhaTap Java agent (from the public
# apm-init-java image; 2.2.77 at reconstruction, 2026-09-27,
# sha256:4d437076f87487c9aff1884974d69c17a9e9638100bfa8c5054b8818ea3dd0d7).
# Dummy license, server 127.0.0.1: the agent never reaches a collection server.
ARG AGENT_IMAGE=public.ecr.aws/whatap/apm-init-java:latest
FROM ${AGENT_IMAGE} AS agent
FROM eclipse-temurin:21-jdk
RUN apt-get update -qq && apt-get install -y -qq procps iproute2 >/dev/null && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1500 app && mkdir -p /opt/whatap /app
COPY --from=agent /whatap/whatap.agent.java.jar /opt/whatap/
COPY whatap.conf /opt/whatap/
COPY Main.java /app/
RUN cd /app && javac Main.java && printf 'Main-Class: Main\n' > m.txt && jar cfm app.jar m.txt Main.class && chown -R app /opt/whatap /app
USER app
WORKDIR /app
CMD ["java","-javaagent:/opt/whatap/whatap.agent.java.jar","-Xmx256m","-jar","/app/app.jar"]
