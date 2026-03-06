ARG OPENRESTY_VERSION=1.27.1.2

FROM openresty/openresty:${OPENRESTY_VERSION}-alpine AS modsec-builder

ARG OPENRESTY_VERSION
ARG MODSECURITY_VERSION=v3.0.14
ARG MODSEC_NGINX_VERSION=v1.0.4
ARG NGX_BROTLI_VERSION=v1.0.0rc
ARG ZSTD_NGINX_VERSION=0.1.1

RUN apk add --no-cache \
    git build-base autoconf automake libtool \
    pcre2-dev openssl-dev libxml2-dev curl-dev \
    yajl-dev geoip-dev lmdb-dev libmaxminddb-dev \
    linux-headers brotli-dev zstd-dev

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
      --add-dynamic-module=/build/ModSecurity-nginx \
      --add-dynamic-module=/build/ngx_brotli \
      --add-dynamic-module=/build/zstd-nginx-module && \
    make -j2 && \
    NGINX_VERSION=$(echo "${OPENRESTY_VERSION}" | cut -d. -f1-3) && \
    mkdir -p /build/custom-modules && \
    cp build/nginx-${NGINX_VERSION}/objs/ngx_http_*.so /build/custom-modules/

FROM openresty/openresty:${OPENRESTY_VERSION}-alpine

ARG CRS_VERSION=v4.24.0

RUN apk add --no-cache \
    libxml2 libcurl yajl geoip lmdb libmaxminddb pcre2 brotli zstd-libs

COPY --from=modsec-builder \
    /usr/local/modsecurity /usr/local/modsecurity
COPY --from=modsec-builder \
    /build/custom-modules/ /usr/local/openresty/nginx/modules/

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
