# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Node 22 + npm whatap@2.0.6, the app does require('whatap'); user node.
DESC="Node 22, npm whatap 2.0.6 required by the app, user node"
COLLECTORS="apm/nodejs/collect-apmnodejs.sh"
docker_target jjsong-ggt-apm-nodejs jjsong-ggt-apm-nodejs:1
apm_argsets node
t_health() { t_sh node 'pgrep -f "node /app/app.js" >/dev/null && echo "node app running"'; }
CHECKS=( "apmnodejs|app-sh|whatap" )
