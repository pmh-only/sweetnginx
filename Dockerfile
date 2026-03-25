# syntax=docker/dockerfile:1.7

ARG OPENRESTY_VERSION=1.27.1.2
ARG MAKE_JOBS=0

FROM openresty/openresty:${OPENRESTY_VERSION}-alpine AS build-base

ENV CC="ccache gcc" \
    CXX="ccache g++" \
    CCACHE_DIR=/root/.cache/ccache \
    CCACHE_BASEDIR=/build \
    CCACHE_COMPILERCHECK=content \
    CCACHE_MAXSIZE=2G

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --update-cache \
    git build-base autoconf automake libtool ccache \
    pcre2-dev openssl-dev libxml2-dev curl-dev \
    yajl-dev geoip-dev lmdb-dev libmaxminddb-dev \
    linux-headers brotli-dev zstd-dev perl zlib-dev

FROM build-base AS openresty-src

ARG OPENRESTY_VERSION

RUN --mount=type=cache,target=/var/cache/distfiles,sharing=locked \
    mkdir -p /src/openresty && \
    wget -nv -O /var/cache/distfiles/openresty-${OPENRESTY_VERSION}.tar.gz \
    https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz && \
    tar xzf /var/cache/distfiles/openresty-${OPENRESTY_VERSION}.tar.gz \
      --strip-components=1 -C /src/openresty

FROM build-base AS openssl-src

ARG OPENSSL_ECH_TAG=3.9.0-ech

RUN --mount=type=cache,target=/var/cache/distfiles,sharing=locked \
    mkdir -p /src/openssl-ech && \
    archive="/var/cache/distfiles/openssl-${OPENSSL_ECH_TAG}.tar.gz" && \
    tmp_archive="${archive}.tmp" && \
    rm -f "$tmp_archive" && \
    if [ ! -s "$archive" ]; then \
      if wget -nv -O "$tmp_archive" \
          "https://github.com/defo-project/openssl/archive/refs/tags/${OPENSSL_ECH_TAG}.tar.gz"; then \
        mv "$tmp_archive" "$archive"; \
      else \
        rm -f "$tmp_archive" && \
        wget -nv -O "$tmp_archive" \
          "https://github.com/defo-project/openssl/archive/refs/heads/${OPENSSL_ECH_TAG}.tar.gz" && \
        mv "$tmp_archive" "$archive"; \
      fi; \
    fi && \
    tar xzf /var/cache/distfiles/openssl-${OPENSSL_ECH_TAG}.tar.gz \
      --strip-components=1 -C /src/openssl-ech

FROM build-base AS modsecurity-src

ARG MODSECURITY_VERSION=v3.0.14

RUN --mount=type=cache,target=/var/cache/git,sharing=locked \
    set -eu; \
    git_checkout() { \
      name="$1"; url="$2"; ref="$3"; dest="$4"; \
      mirror="/var/cache/git/${name}.git"; \
      if [ ! -d "$mirror" ]; then \
        git clone --mirror "$url" "$mirror"; \
      else \
        git -C "$mirror" remote set-url origin "$url"; \
      fi; \
      git -C "$mirror" fetch --force --prune --tags origin; \
      rm -rf "$dest"; \
      git clone --no-checkout "$mirror" "$dest"; \
      git -C "$dest" checkout --detach "$ref"; \
    }; \
    git_checkout owasp-modsecurity-ModSecurity \
      https://github.com/owasp-modsecurity/ModSecurity \
      ${MODSECURITY_VERSION} \
      /src/ModSecurity; \
    libinjection_ref="$(git -C /src/ModSecurity rev-parse HEAD:others/libinjection)"; \
    mbedtls_ref="$(git -C /src/ModSecurity rev-parse HEAD:others/mbedtls)"; \
    rm -rf /src/ModSecurity/others/libinjection /src/ModSecurity/others/mbedtls; \
    git_checkout libinjection-libinjection \
      https://github.com/libinjection/libinjection.git \
      "$libinjection_ref" \
      /src/ModSecurity/others/libinjection; \
    git_checkout Mbed-TLS-mbedtls \
      https://github.com/Mbed-TLS/mbedtls.git \
      "$mbedtls_ref" \
      /src/ModSecurity/others/mbedtls; \
    find /src/ModSecurity -name .git -type d -prune -exec rm -rf '{}' +; \
    find /src/ModSecurity -name .git -type f -delete

FROM build-base AS modsec-nginx-src

ARG MODSEC_NGINX_VERSION=v1.0.4

RUN --mount=type=cache,target=/var/cache/distfiles,sharing=locked \
    mkdir -p /src/ModSecurity-nginx && \
    wget -nv -O /var/cache/distfiles/modsecurity-nginx-${MODSEC_NGINX_VERSION}.tar.gz \
    https://github.com/owasp-modsecurity/ModSecurity-nginx/archive/refs/tags/${MODSEC_NGINX_VERSION}.tar.gz && \
    tar xzf /var/cache/distfiles/modsecurity-nginx-${MODSEC_NGINX_VERSION}.tar.gz \
      --strip-components=1 -C /src/ModSecurity-nginx

FROM build-base AS brotli-src

ARG NGX_BROTLI_VERSION=v1.0.0rc

RUN --mount=type=cache,target=/var/cache/distfiles,sharing=locked \
    mkdir -p /src/ngx_brotli && \
    wget -nv -O /var/cache/distfiles/ngx-brotli-${NGX_BROTLI_VERSION}.tar.gz \
    https://github.com/google/ngx_brotli/archive/refs/tags/${NGX_BROTLI_VERSION}.tar.gz && \
    tar xzf /var/cache/distfiles/ngx-brotli-${NGX_BROTLI_VERSION}.tar.gz \
      --strip-components=1 -C /src/ngx_brotli

FROM build-base AS zstd-src

ARG ZSTD_NGINX_VERSION=0.1.1

RUN --mount=type=cache,target=/var/cache/distfiles,sharing=locked \
    mkdir -p /src/zstd-nginx-module && \
    wget -nv -O /var/cache/distfiles/zstd-nginx-module-${ZSTD_NGINX_VERSION}.tar.gz \
    https://github.com/tokers/zstd-nginx-module/archive/refs/tags/${ZSTD_NGINX_VERSION}.tar.gz && \
    tar xzf /var/cache/distfiles/zstd-nginx-module-${ZSTD_NGINX_VERSION}.tar.gz \
      --strip-components=1 -C /src/zstd-nginx-module

FROM build-base AS crs-src

ARG CRS_VERSION=v4.24.0

RUN --mount=type=cache,target=/var/cache/distfiles,sharing=locked \
    mkdir -p /src/crs && \
    wget -nv -O /var/cache/distfiles/crs-${CRS_VERSION}.tar.gz \
    https://github.com/coreruleset/coreruleset/archive/refs/tags/${CRS_VERSION}.tar.gz && \
    tar xzf /var/cache/distfiles/crs-${CRS_VERSION}.tar.gz \
      --strip-components=1 -C /src/crs

FROM build-base AS openssl-builder

ARG MAKE_JOBS

COPY --from=openssl-src /src/openssl-ech /build/openssl-ech

RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    jobs="${MAKE_JOBS}" && \
    if [ "$jobs" = "0" ]; then jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"; fi && \
    cd /build/openssl-ech && \
    perl Configure no-tests no-shared && \
    make -j"$jobs" && \
    cp apps/openssl /usr/local/bin/openssl-ech

FROM build-base AS modsecurity-builder

ARG MAKE_JOBS

COPY --from=modsecurity-src /src/ModSecurity /build/ModSecurity

RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    jobs="${MAKE_JOBS}" && \
    if [ "$jobs" = "0" ]; then jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"; fi && \
    cd /build/ModSecurity && \
    ./build.sh && ./configure --with-pcre2 && \
    make -j"$jobs" && make install

FROM build-base AS nginx-builder

ARG OPENRESTY_VERSION
ARG MAKE_JOBS

COPY --from=openresty-src /src/openresty /build/openresty
COPY --from=openssl-src /src/openssl-ech /build/openssl-ech
COPY --from=modsec-nginx-src /src/ModSecurity-nginx /build/ModSecurity-nginx
COPY --from=brotli-src /src/ngx_brotli /build/ngx_brotli
COPY --from=zstd-src /src/zstd-nginx-module /build/zstd-nginx-module
COPY --from=modsecurity-builder /usr/local/modsecurity /usr/local/modsecurity
RUN --mount=type=cache,target=/root/.cache/ccache,sharing=locked \
    cd /build/openresty && \
    jobs="${MAKE_JOBS}" && \
    if [ "$jobs" = "0" ]; then jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"; fi && \
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
    make -j"$jobs" && \
    NGINX_VERSION=$(echo "${OPENRESTY_VERSION}" | cut -d. -f1-3) && \
    mkdir -p /build/custom-modules && \
    cp build/nginx-${NGINX_VERSION}/objs/ngx_http_*.so /build/custom-modules/ && \
    cp build/nginx-${NGINX_VERSION}/objs/nginx /build/nginx-ech

FROM openresty/openresty:${OPENRESTY_VERSION}-alpine

RUN --mount=type=cache,target=/var/cache/apk,sharing=locked \
    apk add --update-cache \
    libxml2 libcurl yajl geoip lmdb libmaxminddb pcre2 brotli zstd-libs

COPY --from=modsecurity-builder \
    /usr/local/modsecurity /usr/local/modsecurity
COPY --from=nginx-builder \
    /build/custom-modules/ /usr/local/openresty/nginx/modules/
COPY --from=openssl-builder \
    /usr/local/bin/openssl-ech /usr/local/bin/openssl-ech
COPY --from=nginx-builder \
    /build/nginx-ech /usr/local/openresty/nginx/sbin/nginx
COPY --from=crs-src \
    /src/crs /etc/modsecurity/crs
COPY --from=modsecurity-builder \
    /build/ModSecurity/modsecurity.conf-recommended \
    /etc/modsecurity/modsecurity.conf
COPY --from=modsecurity-builder \
    /build/ModSecurity/unicode.mapping \
    /etc/modsecurity/unicode.mapping

RUN cp /etc/modsecurity/crs/crs-setup.conf.example \
      /etc/modsecurity/crs/crs-setup.conf && \
    sed -i \
      's/SecRuleEngine DetectionOnly/SecRuleEngine On/' \
      /etc/modsecurity/modsecurity.conf && \
    mkdir -p /etc/nginx/ech

COPY conf/modsecurity-includes.conf /etc/modsecurity/includes.conf

COPY scripts/gen-ech-keys.sh /usr/local/bin/gen-ech-keys
RUN chmod +x /usr/local/bin/gen-ech-keys
