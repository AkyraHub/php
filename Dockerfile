ARG PHP_VERSION=8.5.9
ARG ALPINE_VERSION=3.23

FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION}

ARG IMAGE_VERSION=dev

LABEL org.opencontainers.image.source="https://github.com/AkyraHub/php" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      maintainer="Hochi"

ENV TZ=Europe/Paris

RUN set -eux \
    && apk upgrade --no-cache \
    && apk add --no-cache \
         bash=5.3.3-r1 \
         icu-libs=76.1-r1 \
         icu-data-full=76.1-r1 \
         libpq=18.6-r0 \
         libzip=1.11.4-r1 \
         libpng=1.6.58-r1 \
         libjpeg-turbo=3.1.2-r0 \
         freetype=2.14.3-r0 \
         fcgi=2.4.6-r0 \
         tzdata=2026c-r0 \
    && cp /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo ${TZ} > /etc/timezone \
    && wget -qO /usr/local/bin/php-fpm-healthcheck \
         https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/v0.6.0/php-fpm-healthcheck \
    && chmod +x /usr/local/bin/php-fpm-healthcheck \
    && rm -rf /var/cache/apk/*

RUN set -eux \
    && apk add --no-cache --virtual .build-deps \
         $PHPIZE_DEPS \
         icu-dev=76.1-r1 \
         postgresql18-dev=18.6-r0 \
         libzip-dev=1.11.4-r1 \
         libpng-dev=1.6.58-r1 \
         libjpeg-turbo-dev=3.1.2-r0 \
         freetype-dev=2.14.3-r0 \
         linux-headers=6.16.12-r0 \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
         intl \
         pdo_pgsql \
         zip \
         gd \
         bcmath \
         pcntl \
         exif \
         sockets \
    && pecl install redis-6.3.0 \
    && docker-php-ext-enable redis \
    && apk del .build-deps \
    && rm -rf /tmp/* /var/cache/apk/*


RUN { \
        echo '[global]'; \
        echo 'error_log = /proc/self/fd/2'; \
        echo '[www]'; \
        echo 'pm.status_path = /status'; \
    } >> /usr/local/etc/php-fpm.d/zz-docker.conf

USER www-data

EXPOSE 9000

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD ["php-fpm-healthcheck"]
