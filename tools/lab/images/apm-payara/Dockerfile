# jjsong-ggt-apm-payara:1 — Payara Server 6 (GlassFish lineage) + WhaTap Java
# agent (from the public apm-init-java image; 2.2.77 at reconstruction,
# 2026-09-28, sha256:4d437076f87487c9aff1884974d69c17a9e9638100bfa8c5054b8818ea3dd0d7).
# Dummy license, server 127.0.0.1: the agent never reaches a collection server.
# The image ships a pre-built domain1 (no create-domain step at container
# start), so the -javaagent is baked straight into its domain.xml
# <java-config> as a <jvm-options> line — the same place asadmin
# create-jvm-options would write it, but without needing a start/stop cycle
# for a preboot-commands change to take effect on the live JVM (tried first;
# the process launched by the *same* boot that runs preboot commands does not
# pick up a jvm-options change made during that boot, only the next one).
# unzip is added (the base image has pgrep/procps already, but no unzip) so
# the collector can read the agent jar's v.properties. See tools/lab/README.md.
ARG AGENT_IMAGE=public.ecr.aws/whatap/apm-init-java:latest
FROM ${AGENT_IMAGE} AS agent
FROM payara/server-full:6.2025.10
USER root
RUN apt-get update -qq && apt-get install -y -qq unzip >/dev/null && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /opt/whatap
COPY --from=agent /whatap/whatap.agent.java.jar /opt/whatap/
COPY whatap.conf /opt/whatap/
RUN sed -i 's#\(<jvm-options>-server</jvm-options>\)#<jvm-options>-javaagent:/opt/whatap/whatap.agent.java.jar</jvm-options>\n        \1#' \
        /opt/payara/appserver/glassfish/domains/domain1/config/domain.xml \
    && grep -q 'javaagent:/opt/whatap/whatap.agent.java.jar' /opt/payara/appserver/glassfish/domains/domain1/config/domain.xml \
    && chown -R payara:payara /opt/whatap
USER payara
