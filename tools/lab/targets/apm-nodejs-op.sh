# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Node 22 with the operator's injection: /whatap-agent from apm-init-nodejs,
# NODE_OPTIONS=-r whatap, no whatap in the app's node_modules.
DESC="Node 22, agent from apm-init-nodejs via NODE_OPTIONS=-r whatap (operator shape)"
COLLECTORS="apm/nodejs/collect-apmnodejs.sh"
docker_target jjsong-ggt-apm-nodejs-op jjsong-ggt-apm-nodejs-op:1
apm_argsets node
t_health() { t_sh node 'pgrep -f "node /app/app.js" >/dev/null && echo "node app running"'; }
CHECKS=( "apmnodejs|app-sh|/whatap-agent" )
