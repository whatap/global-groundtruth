# jjsong-ggt-apm-php-alpine:1 — php:8.3-fpm-alpine + nginx + the WhaTap PHP
# Alpine tarball (whatap_php_static) 2.14.2 from repo.whatap.io, install.sh
# fed the dummy license; PID 1 is sleep infinity (start.sh).
FROM php:8.3-fpm-alpine
ARG WHATAP_PHP_TGZ=https://repo.whatap.io/alpine/x86_64/whatap-php-2.14.2.tar.gz
RUN apk add -q --no-cache nginx procps iproute2 util-linux-misc bash
RUN curl -fsSL -o /tmp/whatap-php.tar.gz "$WHATAP_PHP_TGZ" && tar -xzf /tmp/whatap-php.tar.gz -C / && rm /tmp/whatap-php.tar.gz && printf "ggt-lab-dummy-license\n127.0.0.1\n" | /usr/whatap/php/install.sh; ls /usr/local/etc/php/conf.d; ls -la $(php -r 'echo ini_get("extension_dir");')/whatap.so
RUN mkdir -p /var/www/html && echo '<?php echo "hello\n";' > /var/www/html/index.php && adduser -D -u 1500 app
COPY nginx-php.conf /etc/nginx/http.d/php.conf
COPY start.sh /start.sh
RUN chmod 755 /start.sh
CMD ["/start.sh"]
