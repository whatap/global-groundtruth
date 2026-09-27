# jjsong-ggt-apm-nodejs:1 — Node 22 + npm whatap@2.0.6 + express; the app
# itself does require('whatap'). Dummy license in whatap.conf.
FROM node:22-bookworm
RUN apt-get update -qq && apt-get install -y -qq procps iproute2 >/dev/null && rm -rf /var/lib/apt/lists/*
RUN mkdir /app && chown node /app
USER node
WORKDIR /app
RUN npm init -y >/dev/null && npm install --no-audit --no-fund whatap@2.0.6 express@4 >/dev/null
COPY --chown=node app.js whatap.conf /app/
CMD ["node","/app/app.js"]
