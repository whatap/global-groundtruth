# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Python 3.12 + /whatap-agent from apm-init-python (2.1.2), PYTHONPATH
# bootstrap as the operator injects it.
DESC="Python 3.12, agent from apm-init-python via PYTHONPATH bootstrap (operator shape)"
COLLECTORS="apm/python/collect-apmpython.sh"
docker_target jjsong-ggt-apm-python-op jjsong-ggt-apm-python-op:1
apm_argsets app
t_health() { t_sh app 'pgrep -f gunicorn >/dev/null && echo "gunicorn running"'; }
CHECKS=( "apmpython|app-sh|/whatap-agent" )
