#!/bin/sh
php-fpm -D
/usr/whatap/php/whatap-php start
nginx
exec sleep infinity
