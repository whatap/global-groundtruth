# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# Rocky 9, PHP 8.2 php-fpm + nginx, whatap-php 2.14-2 rpm, systemd as PID 1.
DESC="Rocky 9 + systemd, PHP 8.2 php-fpm/nginx, whatap-php 2.14-2 rpm"
COLLECTORS="apm/php/collect-apmphp.sh"
docker_target jjsong-ggt-apm-php-rocky jjsong-ggt-apm-php-rocky:1 \
    --tmpfs /run --tmpfs /tmp --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw
apm_argsets app
t_health() { t_sh 0 'pgrep -f php-fpm >/dev/null && pgrep -f whatap >/dev/null && echo "php-fpm and whatap-php running"'; }
CHECKS=( "apmphp|app-sh|whatap\.so" )
