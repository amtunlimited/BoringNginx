# Most of the below is based on the Nginx Team's Alpine Dockerfile
#   https://github.com/nginxinc/docker-nginx/blob/e3e35236b2c77e02266955c875b74bdbceb79c44/mainline/alpine/Dockerfile

# --- Nginx Build Container --- #
FROM alpine:3 as builder

# Nginx Version (See: https://nginx.org/en/CHANGES)
ENV NGINX_VERSION 1.19.4
ENV NGINX_GPG B0F4253373F8F6F510D42178520A9993A1C052F8

# Nginx User UID/GID
ARG NGINX_ID=6666

# Nginx build config
ARG CONFIG="\
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --user=nginx \
    --group=nginx \
    --with-http_ssl_module \
    --with-http_realip_module \
    --with-http_addition_module \
    --with-http_sub_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_mp4_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_random_index_module \
    --with-http_secure_link_module \
    --with-http_stub_status_module \
    --with-http_auth_request_module \
    --with-http_xslt_module=dynamic \
    --with-http_image_filter_module=dynamic \
    --with-threads \
    --with-stream \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-stream_realip_module \
    --with-http_slice_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-compat \
    --with-file-aio \
    --with-http_v2_module \
    --with-openssl=/usr/src/boringssl \
    --with-cc-opt=-I'/usr/src/boringssl/.openssl/include/' \
"

COPY boringssl /usr/src/boringssl

RUN set -xe \
    \
# Add BoringSSL build deps
    && apk add --no-cache --virtual .boringssl-deps \
        build-base \
        cmake \
        git \
        go \
        linux-headers \
        perl \
    \
# Download and prepare BoringSSL source
#    && git clone --depth 1 https://boringssl.googlesource.com/boringssl "/usr/src/boringssl" \
    && mkdir "/usr/src/boringssl/build/" \
    && cd "/usr/src/boringssl/build/" \
    && cmake -DCMAKE_BUILD_TYPE=Release ../ \
    && make -j$(getconf _NPROCESSORS_ONLN) \
    && mkdir -p "/usr/src/boringssl/.openssl/lib" \
    && cd "/usr/src/boringssl/.openssl" \
    && ln -s ../include \
    && cd "/usr/src/boringssl" \
    && cp "build/crypto/libcrypto.a" "build/ssl/libssl.a" ".openssl/lib" \
    \
# Download and prepare Nginx
    && addgroup -S -g $NGINX_ID nginx \
    && adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx -u $NGINX_ID nginx \
    && apk add --no-cache --virtual .build-deps \
        gcc \
        libc-dev \
        make \
        pcre-dev \
        zlib-dev \
        linux-headers \
        curl \
        gnupg \
        libxslt-dev \
        gd-dev \
        libmaxminddb-dev

COPY nginx /usr/src/nginx
# Build debug bits
RUN cd /usr/src/nginx \
    && ./auto/configure $CONFIG --with-debug \
    \
    # Prevent build-error 127 which seems to be caused by the ssl.h file missing:
    && mkdir -p /usr/src/boringssl/.openssl/include/openssl/ \
    && touch /usr/src/boringssl/.openssl/include/openssl/ssl.h \
    && make -j$(getconf _NPROCESSORS_ONLN) \
    && mv objs/nginx objs/nginx-debug \
    && mv objs/ngx_http_xslt_filter_module.so objs/ngx_http_xslt_filter_module-debug.so \
    && mv objs/ngx_http_image_filter_module.so objs/ngx_http_image_filter_module-debug.so

# Build main bits
RUN cd /usr/src/nginx \
    && ./auto/configure $CONFIG \
    \
    # Prevent build-error 127 which seems to be caused by the ssl.h file missing:
    && mkdir -p /usr/src/boringssl/.openssl/include/openssl/ \
    && touch /usr/src/boringssl/.openssl/include/openssl/ssl.h \
    && make -j$(getconf _NPROCESSORS_ONLN)

# Clean some unnecessary source so we're copying less into the next stage
RUN rm -rf /usr/src/boringssl/build

# Move the source into a single place
RUN mkdir /tmp/buildsource
RUN mv -fv /usr/src/nginx/ /tmp/buildsource/nginx/
RUN mv -fv /usr/src/boringssl/ /tmp/buildsource/boringssl/

# Backup our NGINX_ID environment variable
RUN echo "$NGINX_ID" > /tmp/buildsource/nginx_id


# --- Runtime Container --- #
FROM alpine:3
LABEL maintainer "Alex Haydock <alex@alexhaydock.co.uk>"
LABEL name "BoringNginx"
LABEL version 1.19.4

COPY --from=builder /tmp/buildsource /usr/src

RUN set -xe \
    \
# Set the NGINX_ID environment variable again
    && export NGINX_ID="$(cat /usr/src/nginx_id)" \
    \
# Re-add the Nginx user
    && addgroup -S -g $NGINX_ID nginx \
    && adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx -u $NGINX_ID nginx \
	\
# Add some more deps to install Nginx
    && apk add --no-cache --virtual .installdeps binutils make wget \
    \
# Install Nginx
    && cd /usr/src/nginx \
    && make install \
    && rm -rf /etc/nginx/html/ \
    && mkdir /etc/nginx/conf.d/ \
    && mkdir -p /usr/share/nginx/html/ \
    && install -m644 docs/html/index.html /usr/share/nginx/html/ \
    && install -m644 docs/html/50x.html /usr/share/nginx/html/ \
    && install -m755 objs/nginx-debug /usr/sbin/nginx-debug \
    && install -m755 objs/ngx_http_xslt_filter_module-debug.so /usr/lib/nginx/modules/ngx_http_xslt_filter_module-debug.so \
    && install -m755 objs/ngx_http_image_filter_module-debug.so /usr/lib/nginx/modules/ngx_http_image_filter_module-debug.so \
    && ln -s ../../usr/lib/nginx/modules /etc/nginx/modules \
    && strip /usr/sbin/nginx* \
    && strip /usr/lib/nginx/modules/*.so \
    \
# Bring in gettext so we can get `envsubst`, then throw
# the rest away. To do this, we need to install `gettext`
# then move `envsubst` out of the way so `gettext` can
# be deleted completely, then move `envsubst` back.
    && apk add --no-cache --virtual .gettext gettext \
    && mv /usr/bin/envsubst /tmp/ \
    \
# Work out our runtime dependencies
    && runDeps="$( \
        scanelf --needed --nobanner --format '%n#p' /usr/sbin/nginx /usr/lib/nginx/modules/*.so /tmp/envsubst \
            | tr ',' '\n' \
            | sort -u \
            | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )" \
# Install the runtime dependencies as virtual metapackage called ".nginx-rundeps"
    && apk add --no-cache --virtual .nginx-rundeps $runDeps \
    \
# Bring in tzdata so users can set the timezone through environment variables
    && apk add --no-cache tzdata \
    \
# Add the default Nginx config files
# (these are pulled directly from the Nginx team's Docker repo without modification)
    # && wget https://hg.nginx.org/pkg-oss/raw-file/tip/alpine/nginx.conf -O /etc/nginx/nginx.conf \
    # && wget https://hg.nginx.org/pkg-oss/raw-file/tip/alpine/nginx.default.conf -O /etc/nginx/conf.d/default.conf \
    \
# Remove our virtual metapackages
    && apk del .installdeps .gettext \
    && mv /tmp/envsubst /usr/local/bin/ \
    \
# Delete source files to save space in final image
    && rm -rf /usr/src/* \
    \
# Make sure ownership is correct on everything Nginx will need to write to.
# This means we can run the container as the Nginx user if we want to.
    && chown -R $NGINX_ID:$NGINX_ID "/etc/nginx" \
    && chown -R $NGINX_ID:$NGINX_ID "/var/cache/nginx" \
    && chown -R $NGINX_ID:$NGINX_ID "/var/log/nginx" \
    && touch "/var/run/nginx.pid" \
    && chown $NGINX_ID:$NGINX_ID "/var/run/nginx.pid" \
    && touch "/var/run/nginx.lock" \
    && chown $NGINX_ID:$NGINX_ID "/var/run/nginx.lock" \
    \
# Print final built version (for debug purposes)
    && echo "" && nginx -V

# Runtime settings
STOPSIGNAL SIGTERM
CMD ["nginx", "-g", "daemon off;"]
