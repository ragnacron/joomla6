FROM joomla:6.1-php8.4-apache

# PHPIZE_DEPS are already present in the php base image, so pecl builds directly.
RUN pecl install xdebug && docker-php-ext-enable xdebug

# zz- so it loads after docker-php-ext-xdebug.ini, not before.
COPY xdebug.ini /usr/local/etc/php/conf.d/zz-xdebug.ini
COPY proxy.conf /etc/apache2/conf-enabled/zz-proxy.conf
