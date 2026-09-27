# shellcheck shell=bash disable=SC2034  # the variables are read by run.sh
# php:8.3-fpm-alpine + nginx + WhaTap PHP Alpine tarball 2.14.2 (musl, static).
DESC="Alpine, PHP 8.3 php-fpm/nginx, WhaTap PHP 2.14.2 Alpine tarball"
COLLECTORS="apm/php/collect-apmphp.sh"
docker_target jjsong-ggt-apm-php-alpine jjsong-ggt-apm-php-alpine:1
apm_argsets app
t_health() { t_sh 0 'pgrep -f php-fpm >/dev/null && echo "php-fpm running"'; }
CHECKS=( "apmphp|app-sh|whatap\.so" )
