ARG OPENRESTY_VERSION=1.27.1.2

FROM openresty/openresty:${OPENRESTY_VERSION}-alpine AS modsec-builder

ARG OPENRESTY_VERSION
ARG MODSECURITY_VERSION=v3.0.14
ARG MODSEC_NGINX_VERSION=v1.0.4
ARG NGX_BROTLI_VERSION=v1.0.0rc
ARG ZSTD_NGINX_VERSION=0.1.1
ARG OPENSSL_ECH_TAG=3.9.0-ech

RUN apk add --no-cache \
    git build-base autoconf automake libtool \
    pcre2-dev openssl-dev libxml2-dev curl-dev \
    yajl-dev geoip-dev lmdb-dev libmaxminddb-dev \
    linux-headers brotli-dev zstd-dev perl zlib-dev

# Clone ECH-capable OpenSSL and build the openssl CLI binary.
# nginx's --with-openssl will later run 'make clean' and reconfigure this
# directory, so the binary must be copied out before that happens.
RUN git clone --depth 1 -b ${OPENSSL_ECH_TAG} \
    https://github.com/defo-project/openssl /build/openssl-ech && \
    cd /build/openssl-ech && \
    perl Configure no-tests no-shared && \
    make -j2 && \
    cp apps/openssl /usr/local/bin/openssl-ech

RUN git clone --depth 1 -b ${MODSECURITY_VERSION} \
    https://github.com/owasp-modsecurity/ModSecurity /build/ModSecurity && \
    cd /build/ModSecurity && \
    git submodule init && git submodule update && \
    ./build.sh && ./configure --with-pcre2 && \
    make -j2 && make install

RUN git clone --depth 1 -b ${MODSEC_NGINX_VERSION} \
    https://github.com/owasp-modsecurity/ModSecurity-nginx \
    /build/ModSecurity-nginx

RUN git clone --depth 1 -b ${NGX_BROTLI_VERSION} \
    https://github.com/google/ngx_brotli /build/ngx_brotli

RUN git clone --depth 1 -b ${ZSTD_NGINX_VERSION} \
    https://github.com/tokers/zstd-nginx-module /build/zstd-nginx-module

RUN wget -O /tmp/openresty.tar.gz \
    https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz && \
    tar xzf /tmp/openresty.tar.gz -C /build

RUN cd /build/openresty-${OPENRESTY_VERSION} && \
    ./configure \
      --with-compat \
      --with-file-aio \
      --with-http_addition_module \
      --with-http_auth_request_module \
      --with-http_dav_module \
      --with-http_flv_module \
      --with-http_gunzip_module \
      --with-http_gzip_static_module \
      --with-http_mp4_module \
      --with-http_random_index_module \
      --with-http_realip_module \
      --with-http_secure_link_module \
      --with-http_slice_module \
      --with-http_ssl_module \
      --with-http_stub_status_module \
      --with-http_sub_module \
      --with-http_v2_module \
      --with-http_v3_module \
      --with-pcre-jit \
      --with-stream \
      --with-stream_ssl_module \
      --with-stream_ssl_preread_module \
      --with-threads \
      --with-openssl=/build/openssl-ech \
      --with-ld-opt="-Wl,--export-dynamic -u SSL_CTX_set1_echstore" \
      --add-dynamic-module=/build/ModSecurity-nginx \
      --add-dynamic-module=/build/ngx_brotli \
      --add-dynamic-module=/build/zstd-nginx-module && \
    make -j2 && \
    NGINX_VERSION=$(echo "${OPENRESTY_VERSION}" | cut -d. -f1-3) && \
    mkdir -p /build/custom-modules && \
    cp build/nginx-${NGINX_VERSION}/objs/ngx_http_*.so /build/custom-modules/ && \
    cp build/nginx-${NGINX_VERSION}/objs/nginx /build/nginx-ech

FROM openresty/openresty:${OPENRESTY_VERSION}-alpine

ARG CRS_VERSION=v4.24.0

RUN apk add --no-cache \
    libxml2 libcurl yajl geoip lmdb libmaxminddb pcre2 brotli zstd-libs

COPY --from=modsec-builder \
    /usr/local/modsecurity /usr/local/modsecurity
COPY --from=modsec-builder \
    /build/custom-modules/ /usr/local/openresty/nginx/modules/
COPY --from=modsec-builder \
    /usr/local/bin/openssl-ech /usr/local/bin/openssl-ech
COPY --from=modsec-builder \
    /build/nginx-ech /usr/local/openresty/nginx/sbin/nginx

RUN mkdir -p /etc/modsecurity && \
    wget -O /tmp/crs.tar.gz \
    https://github.com/coreruleset/coreruleset/archive/refs/tags/${CRS_VERSION}.tar.gz && \
    tar xzf /tmp/crs.tar.gz -C /tmp && \
    mv /tmp/coreruleset-$(echo "${CRS_VERSION}" | sed 's/^v//') /etc/modsecurity/crs && \
    cp /etc/modsecurity/crs/crs-setup.conf.example \
       /etc/modsecurity/crs/crs-setup.conf && \
    rm /tmp/crs.tar.gz

COPY --from=modsec-builder \
    /build/ModSecurity/modsecurity.conf-recommended \
    /etc/modsecurity/modsecurity.conf
COPY --from=modsec-builder \
    /build/ModSecurity/unicode.mapping \
    /etc/modsecurity/unicode.mapping

RUN sed -i \
    's/SecRuleEngine DetectionOnly/SecRuleEngine On/' \
    /etc/modsecurity/modsecurity.conf

COPY conf/modsecurity-includes.conf /etc/modsecurity/includes.conf

COPY scripts/gen-ech-keys.sh /usr/local/bin/gen-ech-keys
RUN chmod +x /usr/local/bin/gen-ech-keys

RUN mkdir -p /etc/nginx/ech
