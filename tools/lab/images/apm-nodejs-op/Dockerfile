# jjsong-ggt-apm-nodejs-op:1 — the apm-nodejs image plus the operator's
# injection: /whatap-agent from the public apm-init-nodejs image,
# NODE_OPTIONS=-r whatap, and no whatap in the app's own node_modules.
# The original was built FROM jjsong-ggt-apm-nodejs:1; the same steps are
# repeated here so this directory builds on its own.
ARG AGENT_IMAGE=public.ecr.aws/whatap/apm-init-nodejs:latest
FROM ${AGENT_IMAGE} AS agent
FROM node:22-bookworm
RUN apt-get update -qq && apt-get install -y -qq procps iproute2 >/dev/null && rm -rf /var/lib/apt/lists/*
RUN mkdir /app && chown node /app
USER node
WORKDIR /app
RUN npm init -y >/dev/null && npm install --no-audit --no-fund whatap@2.0.6 express@4 >/dev/null
USER root
COPY --from=agent /opt/whatap-agent-dist/node_modules /whatap-agent/node_modules
COPY whatap.conf /whatap-agent/whatap.conf
COPY app.js /app/app.js
RUN cp /whatap-agent/node_modules/whatap/agent/linux/amd64/whatap_nodejs /whatap-agent/node_modules/whatap/agent/whatap_nodejs && chmod 777 /whatap-agent && rm -rf /app/node_modules/whatap
ENV WHATAP_HOME=/whatap-agent NODE_PATH=/whatap-agent/node_modules NODE_OPTIONS="-r whatap" WHATAP_NODEJS_AGENT_PATH=/whatap-agent/node_modules/whatap/agent/whatap_nodejs
USER node
CMD ["node","/app/app.js"]
