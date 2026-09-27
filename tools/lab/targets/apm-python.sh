# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Python 3.12 venv + PyPI whatap-python 2.2.0, whatap-start-agent gunicorn.
DESC="Python 3.12 venv, whatap-python 2.2.0, whatap-start-agent gunicorn, uid 1500"
COLLECTORS="apm/python/collect-apmpython.sh"
docker_target jjsong-ggt-apm-python jjsong-ggt-apm-python:1
apm_argsets app
t_health() { t_sh app 'pgrep -f gunicorn >/dev/null && echo "gunicorn running"'; }
CHECKS=( "apmpython|app-sh|whatap_python" )
