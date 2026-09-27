# jjsong-ggt-apm-php-rocky:1 — Rocky 9, PHP 8.2 php-fpm + nginx, whatap-php
# 2.14-2 rpm from the public WhaTap yum repo, install.sh fed the dummy
# license; systemd is PID 1 (run with --tmpfs /run --tmpfs /tmp
# --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw).
FROM rockylinux:9
ARG WHATAP_PHP_RPM=http://repo.whatap.io/centos/9/x86_64/whatap-php-2.14-2.x86_64.rpm
RUN dnf -y -q module enable php:8.2 && dnf -y -q install systemd php-fpm php-cli nginx procps-ng iproute util-linux which findutils >/dev/null && dnf clean all
RUN curl -fsSL -o /tmp/whatap-php.rpm "$WHATAP_PHP_RPM" && rpm -ivh /tmp/whatap-php.rpm && rm /tmp/whatap-php.rpm && printf "ggt-lab-dummy-license\n127.0.0.1\n" | /usr/whatap/php/install.sh
RUN mkdir -p /var/www/html && echo '<?php echo "hello\n";' > /var/www/html/index.php && useradd -m -u 1500 app
COPY nginx-php.conf /etc/nginx/conf.d/php.conf
RUN systemctl enable php-fpm nginx whatap-php
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
