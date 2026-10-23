FROM php:8.4.26-apache

# Extensions WordPress needs
RUN apt-get update && apt-get install -y --no-install-recommends \
        libpng-dev libjpeg62-turbo-dev libfreetype6-dev libzip-dev \
        libonig-dev libxml2-dev mariadb-client unzip curl \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli pdo_mysql gd mbstring xml zip opcache exif \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN a2enmod rewrite

# WordPress core
RUN curl -fsSL -o /tmp/wp.tar.gz https://wordpress.org/latest.tar.gz \
    && tar -xzf /tmp/wp.tar.gz -C /var/www/html --strip-components=1 \
    && rm /tmp/wp.tar.gz \
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 755 /var/www/html

# wp-cli, used by the entrypoint to install and seed
RUN curl -fsSL -o /usr/local/bin/wp \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && chmod +x /usr/local/bin/wp

COPY php.ini      /usr/local/etc/php/conf.d/zz-p2s.ini
COPY apache.conf  /etc/apache2/conf-enabled/zz-p2s.conf
COPY wp-config.php /var/www/html/wp-config.php

# Two probe plugins: one starts a PHP session, one does not.
COPY plugins/ /var/www/html/wp-content/plugins/

COPY entrypoint.sh /usr/local/bin/p2s-entrypoint
RUN chmod +x /usr/local/bin/p2s-entrypoint

# Stock production ini, then our overrides in conf.d
RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

CMD ["/usr/local/bin/p2s-entrypoint"]
